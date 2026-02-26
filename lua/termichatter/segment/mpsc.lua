local MpscQueue = require("coop.mpsc-queue").MpscQueue
local util = require("termichatter.util")

local M = {}

M.HANDOFF_FIELD = "__termichatter_handoff_run"

function M.mpsc_handoff_factory()
	return {
		type = "segment_factory",
		create = function()
			return M.mpsc_handoff()
		end,
	}
end

--- mpsc_handoff segment factory: enqueue continuation run and stop current run
---@param config? table { queue?: table, strategy?: 'self'|'clone'|'fork' }
---@return table segment
function M.mpsc_handoff(config)
	config = config or {}
	local queue = config.queue or MpscQueue.new()
	local handoff = {
		type = "mpsc_handoff",
		queue = queue,
		strategy = config.strategy or "self",
		wants = {},
		emits = {},
		ensure_prepared = function(self, context)
			local line = context and context.line
			if not line then
				return
			end
			if context.force ~= true and line.autoStartConsumers == false then
				return
			end
			require("termichatter.consumer").ensure_queue_consumer(line, self.queue)
		end,
		ensure_stopped = function(self, context)
			local line = context and context.line
			if not line then
				return
			end
			require("termichatter.consumer").stop_queue_consumer(line, self.queue)
		end,
	}

	handoff.handler = function(run)
		local continuation = util.continuation_for_strategy(run, handoff.strategy, run.input, "mpsc_handoff")
		queue:push({ [M.HANDOFF_FIELD] = continuation })
		return false
	end

	return handoff
end

---@param seg any
---@return boolean
function M.is_mpsc_handoff(seg)
	return type(seg) == "table"
		and seg.type == "mpsc_handoff"
		and seg.queue ~= nil
		and type(seg.queue.push) == "function"
		and type(seg.queue.pop) == "function"
end

return M
