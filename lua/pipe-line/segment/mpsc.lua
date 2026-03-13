local MpscQueue = require("coop.mpsc-queue").MpscQueue
local define = require("pipe-line.segment.define")
local mpsc_define = require("pipe-line.segment.define.mpsc")(define)

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
	return mpsc_define({
		type = "mpsc_handoff",
		queue = config.queue or MpscQueue.new(),
		strategy = config.strategy or "self",
		handoff_field = M.HANDOFF_FIELD,
		continuation_owner = "mpsc_handoff",
		wants = {},
		emits = {},
	})
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
