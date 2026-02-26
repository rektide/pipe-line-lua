--- Protocol helpers for control runs and queue payload signals.
local completion = require("termichatter.segment.completion")

local M = {}

M.completion = completion

-- Legacy output payloads for queue/outputter shutdown signaling.
M.hello = { type = "termichatter.completion.hello" }
M.done = { type = "termichatter.completion.done" }
M.shutdown = { type = "termichatter.shutdown" }

---@param msg table
---@return boolean
function M.is_completion_payload(msg)
	return msg
		and msg.type
		and (
			msg.type == "termichatter.completion.done"
			or msg.type == "termichatter.completion.hello"
			or msg.type == "termichatter.shutdown"
		)
end

---@param msg table
---@return boolean
function M.is_shutdown_payload(msg)
	return msg and msg.type == "termichatter.shutdown"
end

return M
