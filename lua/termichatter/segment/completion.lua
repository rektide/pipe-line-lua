--- Completion protocol helpers and completion segment.
local M = {}
local done = require("termichatter.done")

M.PROTOCOL_FIELD = "termichatter_protocol"
M.COMPLETION_FIELD = "mpsc_completion"
M.COMPLETION_NAME_FIELD = "mpsc_completion_name"

M.COMPLETION_HELLO = "hello"
M.COMPLETION_DONE = "done"
M.COMPLETION_SHUTDOWN = "shutdown"

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
function M.is_completion_protocol(run)
	return M.get_completion_signal(run) ~= nil
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

---@return table state
function M.create_completion_state()
	return {
		hello = 0,
		done = 0,
		settled = false,
		resolved = false,
		signal = nil,
		name = nil,
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

	state.signal = signal
	state.name = run[M.COMPLETION_NAME_FIELD]
	state.settled = state.done >= state.hello

	return state
end

---@param define fun(spec: table): table
---@return table segment
function M.build_segment(define)
	return define({
		type = "completion",
		process_protocol = true,
		wants = {},
		emits = {},
		ensure_prepared = function(self, context)
			local line = context and context.line
			if not line then
				return
			end

			if type(line.done) ~= "table" or type(line.done.resolve) ~= "function" then
				line.done = done.create_deferred()
			end

			if type(line._completion_state) ~= "table" then
				line._completion_state = M.create_completion_state()
			end
		end,
		handler = function(run)
			if not M.is_completion_protocol(run) then
				return run.input
			end

			local line = run.line
			if not line then
				return run.input
			end

			local state = line._completion_state
			if not state then
				state = M.create_completion_state()
				line._completion_state = state
			end

			local status = M.query_completion(state, run)
			if not status then
				return run.input
			end

			if not state.resolved and status.settled and type(line.done) == "table" then
				state.resolved = true
				line.done:resolve(state)
			end

			return nil
		end,
	})
end

return M
