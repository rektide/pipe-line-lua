local MpscQueue = require("coop.mpsc-queue").MpscQueue
local util = require("termichatter.util")

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

		segment.queue = segment.queue or MpscQueue.new()
		segment.strategy = segment.strategy or "self"
		segment.handoff_field = segment.handoff_field or "__termichatter_mpsc_continuation"

		local user_ensure_prepared = segment.ensure_prepared
		local user_ensure_stopped = segment.ensure_stopped
		local wrapped_handler = define.wrap_handler(segment, segment.handler)

		segment.ensure_prepared = function(self, context)
			local awaited = {}
			if type(user_ensure_prepared) == "function" then
				append_awaitable(awaited, user_ensure_prepared(self, context))
			end

			local line = context and context.line
			if line and (context.force == true or line.autoStartConsumers ~= false) then
				local task = require("termichatter.consumer").ensure_queue_consumer(line, self.queue)
				append_awaitable(awaited, task)
			end

			return compact_awaitables(awaited)
		end

		segment.ensure_stopped = function(self, context)
			local awaited = {}
			if type(user_ensure_stopped) == "function" then
				append_awaitable(awaited, user_ensure_stopped(self, context))
			end

			local line = context and context.line
			if line then
				local task = require("termichatter.consumer").stop_queue_consumer(line, self.queue)
				append_awaitable(awaited, task)
			end

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

			local continuation
			if type(segment.continuation_for_run) == "function" then
				continuation = segment.continuation_for_run(run, segment)
			else
				continuation = util.continuation_for_strategy(
					run,
					segment.strategy,
					run.input,
					segment.continuation_owner or segment.type
				)
			end

			local payload
			if type(segment.encode_message) == "function" then
				payload = segment.encode_message(continuation, run, segment)
			else
				payload = { [segment.handoff_field] = continuation }
			end

			segment.queue:push(payload)
			if segment.stop_result ~= nil then
				return segment.stop_result
			end
			return false
		end

		return segment
	end
end
