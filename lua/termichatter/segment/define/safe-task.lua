local task = require("coop.task")
local Future = require("coop.future").Future
local util = require("termichatter.util")

local function is_task_active(runner)
	if type(runner) ~= "table" or type(runner.status) ~= "function" then
		return false
	end
	return runner:status() ~= "dead"
end

local function append_awaitable(list, awaited)
	if awaited == nil then
		return
	end

	if type(awaited) == "table" and type(awaited.await) == "function" then
		table.insert(list, awaited)
		return
	end

	if type(awaited) == "table" then
		for _, item in ipairs(awaited) do
			append_awaitable(list, item)
		end
	end
end

local function compact_awaitables(list)
	if #list == 0 then
		return nil
	end
	if #list == 1 then
		return list[1]
	end
	return list
end

return function(define)
	return function(spec)
		spec = spec or {}
		local segment = {}
		for k, v in pairs(spec) do
			segment[k] = v
		end

		segment.strategy = segment.strategy or "self"
		local user_ensure_prepared = segment.ensure_prepared
		local user_ensure_stopped = segment.ensure_stopped
		local wrapped_handler = define.wrap_handler(segment, segment.handler)
		local handler_generator = segment.handler_generator

		local function ensure_runner(self, context)
			if type(self._termichatter_task_processor) ~= "function" then
				if type(handler_generator) == "function" then
					self._termichatter_task_processor = handler_generator(self, context, wrapped_handler) or wrapped_handler
				else
					self._termichatter_task_processor = wrapped_handler
				end
			end

			if type(self._termichatter_task_pending) ~= "table" then
				self._termichatter_task_pending = {}
			end

			if is_task_active(self._termichatter_task_runner) then
				return self._termichatter_task_runner
			end

			self._termichatter_task_waiting = false
			self._termichatter_task_wake = nil

			self._termichatter_task_runner = task.create(function()
				while true do
					if #self._termichatter_task_pending == 0 then
						self._termichatter_task_waiting = true
						self._termichatter_task_wake = Future.new()
						local ok = self._termichatter_task_wake:pawait()
						self._termichatter_task_waiting = false
						if not ok then
							return
						end
					end

					while #self._termichatter_task_pending > 0 do
						local continuation = table.remove(self._termichatter_task_pending, 1)
						local result = self._termichatter_task_processor(continuation)
						if result ~= false then
							continuation:next(result)
						end
					end
				end
			end)

			self._termichatter_task_runner:resume()
			return self._termichatter_task_runner
		end

		segment.ensure_prepared = function(self, context)
			local awaited = {}
			if type(user_ensure_prepared) == "function" then
				append_awaitable(awaited, user_ensure_prepared(self, context))
			end

			append_awaitable(awaited, ensure_runner(self, context))
			return compact_awaitables(awaited)
		end

		segment.handler = function(run)
			local result = wrapped_handler(run)
			if result == false then
				return false
			end
			if result ~= nil then
				run.input = result
			end

			local continuation = util.continuation_for_strategy(
				run,
				segment.strategy,
				run.input,
				segment.continuation_owner or segment.type
			)

			table.insert(segment._termichatter_task_pending, continuation)
			if segment._termichatter_task_waiting
				and type(segment._termichatter_task_wake) == "table"
				and segment._termichatter_task_wake.done ~= true then
				segment._termichatter_task_wake:complete(true)
			end

			if segment.stop_result ~= nil then
				return segment.stop_result
			end
			return false
		end

		segment.ensure_stopped = function(self, context)
			local awaited = {}
			if type(user_ensure_stopped) == "function" then
				append_awaitable(awaited, user_ensure_stopped(self, context))
			end

			if is_task_active(self._termichatter_task_runner) then
				self._termichatter_task_runner:cancel()
				append_awaitable(awaited, self._termichatter_task_runner)
			end

			return compact_awaitables(awaited)
		end

		return segment
	end
end
