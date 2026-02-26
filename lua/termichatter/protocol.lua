--- Protocol helpers for control runs and queue payload signals.
local completion = require("termichatter.segment.completion")

local M = {}

M.completion = completion

-- Legacy output payloads for queue/outputter shutdown signaling.
M.hello = { type = "termichatter.completion.hello" }
M.done = { type = "termichatter.completion.done" }
M.shutdown = { type = "termichatter.shutdown" }

---@return table deferred
function M.create_deferred()
	local resolved = false
	local value = nil
	local callbacks = {}

	return {
		resolve = function(self, next_value)
			if resolved then
				return false
			end
			resolved = true
			value = next_value
			for _, cb in ipairs(callbacks) do
				cb(next_value)
			end
			callbacks = {}
			return true
		end,

		await = function(self, timeout, interval)
			if resolved then
				return value
			end
			local ok = vim.wait(timeout or 1000, function()
				return resolved
			end, interval or 10)
			if ok then
				return value
			end
			return nil
		end,

		on_resolve = function(self, callback)
			if resolved then
				callback(value)
				return
			end
			table.insert(callbacks, callback)
		end,

		is_resolved = function(self)
			return resolved
		end,
	}
end

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
