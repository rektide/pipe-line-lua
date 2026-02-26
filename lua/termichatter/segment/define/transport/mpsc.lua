local MpscQueue = require("coop.mpsc-queue").MpscQueue

local M = {}

function M.new(config)
	config = config or {}
	local default_handoff_field = config.handoff_field or "__termichatter_mpsc_continuation"

	return {
		configure_segment = function(segment)
			segment.queue = segment.queue or MpscQueue.new()
			segment.strategy = segment.strategy or "self"
			segment.handoff_field = segment.handoff_field or default_handoff_field
		end,

		ensure_prepared = function(segment, context)
			local line = context and context.line
			if line and (context.force == true or line.autoStartConsumers ~= false) then
				return require("termichatter.consumer").ensure_queue_consumer(line, segment.queue)
			end
			return nil
		end,

		ensure_stopped = function(segment, context)
			local line = context and context.line
			if line then
				return require("termichatter.consumer").stop_queue_consumer(line, segment.queue)
			end
			return nil
		end,

		dispatch = function(segment, run, continuation)
			local payload
			if type(segment.encode_message) == "function" then
				payload = segment.encode_message(continuation, run, segment)
			else
				payload = { [segment.handoff_field] = continuation }
			end

			segment.queue:push(payload)
		end,
	}
end

return M
