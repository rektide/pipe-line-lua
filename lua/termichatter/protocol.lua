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
function M.is_completion_protocol(run)
	return M.get_completion_signal(run) ~= nil
end

---@param run table
---@return string|nil signal
function M.get_completion_signal(run)
	if not M.is_protocol(run) then
		return nil
	end
	local signal = run[M.COMPLETION_FIELD]
	if M.is_completion_signal(signal) then
		return signal
	end
	return nil
end

---@param run table
---@return boolean
function M.is_completion_hello(run)
	return M.get_completion_signal(run) == M.COMPLETION_HELLO
end

---@param run table
---@return boolean
function M.is_completion_done(run)
	return M.get_completion_signal(run) == M.COMPLETION_DONE
end

---@param run table
---@return boolean
function M.is_completion_shutdown(run)
	return M.get_completion_signal(run) == M.COMPLETION_SHUTDOWN
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

---@return table state
function M.create_completion_state()
	return {
		hello = 0,
		done = 0,
		settled = false,
		resolved = false,
	}
end

---@param state table
---@param run table
---@return table|nil status
function M.query_completion(state, run)
	local signal = M.get_completion_signal(run)
	if signal == nil then
		return nil
	end

	if signal == M.COMPLETION_HELLO then
		state.hello = state.hello + 1
	elseif signal == M.COMPLETION_DONE or signal == M.COMPLETION_SHUTDOWN then
		state.done = state.done + 1
	end

	state.settled = state.done >= state.hello

	return {
		signal = signal,
		hello = state.hello,
		done = state.done,
		settled = state.settled,
		resolved = state.resolved,
		name = run[M.COMPLETION_NAME_FIELD],
	}
end

-- Legacy queue helpers
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
