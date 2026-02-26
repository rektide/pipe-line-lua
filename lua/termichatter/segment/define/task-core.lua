local task = require("coop.task")
local Future = require("coop.future").Future
local common = require("termichatter.segment.define.common")

local function build_segment(define, spec, mode)
	local segment = common.copy_spec(spec)
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

		if mode == "safe" and type(self._termichatter_task_pending) ~= "table" then
			self._termichatter_task_pending = {}
		end

		if common.is_task_active(self._termichatter_task_runner) then
			return self._termichatter_task_runner
		end

		if mode == "safe" then
			self._termichatter_task_waiting = false
			self._termichatter_task_wake = nil
		end

		self._termichatter_task_runner = task.create(function()
			while true do
				if mode == "safe" then
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
				else
					local ok, continuation = task.pyield()
					if not ok then
						return
					end

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
			common.append_awaitable(awaited, user_ensure_prepared(self, context))
		end

		common.append_awaitable(awaited, ensure_runner(self, context))
		return common.compact_awaitables(awaited)
	end

	segment.handler = function(run)
		local continuation, should_dispatch = common.prepare_continuation(segment, run, wrapped_handler)
		if not should_dispatch then
			return false
		end

		local runner = ensure_runner(segment, { line = run.line, run = run, segment = segment })
		if mode == "safe" then
			table.insert(segment._termichatter_task_pending, continuation)
			if segment._termichatter_task_waiting
				and type(segment._termichatter_task_wake) == "table"
				and segment._termichatter_task_wake.done ~= true then
				segment._termichatter_task_wake:complete(true)
			end
		else
			runner:resume(continuation)
		end

		return common.stop_result_or_false(segment)
	end

	segment.ensure_stopped = function(self, context)
		local awaited = {}
		if type(user_ensure_stopped) == "function" then
			common.append_awaitable(awaited, user_ensure_stopped(self, context))
		end

		if common.is_task_active(self._termichatter_task_runner) then
			self._termichatter_task_runner:cancel()
			common.append_awaitable(awaited, self._termichatter_task_runner)
		end

		return common.compact_awaitables(awaited)
	end

	return segment
end

return function(define, mode)
	mode = mode or "unsafe"
	return function(spec)
		return build_segment(define, spec, mode)
	end
end
