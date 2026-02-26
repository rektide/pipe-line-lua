local MpscQueue = require("coop.mpsc-queue").MpscQueue
local common = require("termichatter.segment.define.common")

return function(define)
	return function(spec)
		local segment = common.copy_spec(spec)

		segment.queue = segment.queue or MpscQueue.new()
		segment.strategy = segment.strategy or "self"
		segment.handoff_field = segment.handoff_field or "__termichatter_mpsc_continuation"

		local user_ensure_prepared = segment.ensure_prepared
		local user_ensure_stopped = segment.ensure_stopped
		local wrapped_handler = define.wrap_handler(segment, segment.handler)

		segment.ensure_prepared = function(self, context)
			local awaited = {}
			if type(user_ensure_prepared) == "function" then
				common.append_awaitable(awaited, user_ensure_prepared(self, context))
			end

			local line = context and context.line
			if line and (context.force == true or line.autoStartConsumers ~= false) then
				local task = require("termichatter.consumer").ensure_queue_consumer(line, self.queue)
				common.append_awaitable(awaited, task)
			end

			return common.compact_awaitables(awaited)
		end

		segment.ensure_stopped = function(self, context)
			local awaited = {}
			if type(user_ensure_stopped) == "function" then
				common.append_awaitable(awaited, user_ensure_stopped(self, context))
			end

			local line = context and context.line
			if line then
				local task = require("termichatter.consumer").stop_queue_consumer(line, self.queue)
				common.append_awaitable(awaited, task)
			end

			return common.compact_awaitables(awaited)
		end

		segment.handler = function(run)
			local continuation, should_enqueue = common.prepare_continuation(segment, run, wrapped_handler)
			if not should_enqueue then
				return false
			end

			local payload
			if type(segment.encode_message) == "function" then
				payload = segment.encode_message(continuation, run, segment)
			else
				payload = { [segment.handoff_field] = continuation }
			end

			segment.queue:push(payload)
			return common.stop_result_or_false(segment)
		end

		return segment
	end
end
