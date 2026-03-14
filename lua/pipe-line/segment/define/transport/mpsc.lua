local MpscQueue = require("coop.mpsc-queue").MpscQueue
local common = require("pipe-line.segment.define.common")

local M = {}

function M.new(config)
	config = config or {}
	local default_handoff_field = config.handoff_field or "__pipe_line_mpsc_continuation"
	local function ensure_defaults(segment)
		if segment.queue == nil then
			segment.queue = MpscQueue.new()
		end
		if segment.handoff_field == nil then
			segment.handoff_field = default_handoff_field
		end
	end

	return {
		type = "mpsc",

		ensure_prepared = function(segment, context)
			ensure_defaults(segment)
			local line = context and context.line
			if line and (context.force == true or line.auto_start_consumers ~= false) then
				return require("pipe-line.consumer").ensure_queue_consumer(line, segment.queue)
			end
			return nil
		end,

		ensure_stopped = function(segment, context)
			ensure_defaults(segment)
			local line = context and context.line
			if line then
				return require("pipe-line.consumer").stop_queue_consumer(line, segment.queue)
			end
			return nil
		end,

		handler = function(segment, run, runtime)
			local continuation, should_enqueue = common.prepare_continuation(segment, run, runtime.wrapped_handler)
			if not should_enqueue then
				return false
			end

			ensure_defaults(segment)
			local payload
			if type(segment.encode_message) == "function" then
				payload = segment.encode_message(continuation, run, segment)
			else
				payload = { [segment.handoff_field] = continuation }
			end

			segment.queue:push(payload)
			return common.stop_result_or_false(segment)
		end,
	}
end

return M
