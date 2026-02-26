--- Protocol helpers for control runs and output control payload.
local M = {}

M.PROTOCOL_FIELD = "termichatter_protocol"
M.COMPLETION_FIELD = "mpsc_completion"
M.COMPLETION_NAME_FIELD = "mpsc_completion_name"

M.COMPLETION_HELLO = "hello"
M.COMPLETION_DONE = "done"
M.COMPLETION_SHUTDOWN = "shutdown"

-- Legacy output payloads (kept for outputter/consumer queue control)
M.hello = { type = "termichatter.completion.hello" }
M.done = { type = "termichatter.completion.done" }
M.shutdown = { type = "termichatter.shutdown" }

---@param signal string
---@return boolean
function M.is_completion_signal(signal)
	return signal == M.COMPLETION_HELLO
		or signal == M.COMPLETION_DONE
		or signal == M.COMPLETION_SHUTDOWN
end

---@param run table
---@return boolean
function M.is_protocol(run)
	return type(run) == "table" and run[M.PROTOCOL_FIELD] == true
end

---@param run table
---@return boolean
function M.is_completion(run)
	if not M.is_protocol(run) then
		return false
	end
	return M.is_completion_signal(run[M.COMPLETION_FIELD])
end

---@param run table
---@return boolean
function M.is_shutdown(run)
	if not M.is_protocol(run) then
		return false
	end
	return run[M.COMPLETION_FIELD] == M.COMPLETION_SHUTDOWN
end

---@param signal 'hello'|'done'|'shutdown'
---@param name? string
---@return table run_config
function M.completion_run(signal, name)
	if not M.is_completion_signal(signal) then
		error("invalid mpsc completion signal: " .. tostring(signal), 0)
	end

	local run_config = {
		[M.PROTOCOL_FIELD] = true,
		[M.COMPLETION_FIELD] = signal,
	}
	if name ~= nil then
		run_config[M.COMPLETION_NAME_FIELD] = name
	end
	return run_config
end

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

-- Legacy queue helpers
---@param msg table
---@return boolean
function M.isCompletion(msg)
	return M.is_completion_payload(msg)
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
function M.isShutdown(msg)
	return M.is_shutdown_payload(msg)
end

---@param msg table
---@return boolean
function M.is_shutdown_payload(msg)
	return msg and msg.type == "termichatter.shutdown"
end

return M
