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

---@param state table
---@return table state
function M.ensure_completion_state(state)
	if type(state.hello) ~= "number" then
		state.hello = 0
	end
	if type(state.done) ~= "number" then
		state.done = 0
	end
	if type(state.settled) ~= "boolean" then
		state.settled = false
	end
	if type(state.stopped) ~= "table" or type(state.stopped.resolve) ~= "function" then
		state.stopped = done.create_deferred()
	end
	if state.signal == nil then
		state.signal = nil
	end
	if state.name == nil then
		state.name = nil
	end

	return state
end

---@param state table
---@param run table
---@return boolean applied
function M.apply(state, run)
	state = M.ensure_completion_state(state)

	local signal = M.get_completion_signal(run)
	if signal == nil then
		return false
	end

	if signal == M.COMPLETION_HELLO then
		state.hello = state.hello + 1
	elseif signal == M.COMPLETION_DONE or signal == M.COMPLETION_SHUTDOWN then
		state.done = state.done + 1
	end

	state.signal = signal
	state.name = run[M.COMPLETION_NAME_FIELD]
	state.settled = state.done >= state.hello

	return true
end

---@param define fun(spec: table): table
---@return table segment
function M.build_segment(define)
	return define({
		type = "completion",
		process_protocol = true,
		wants = {},
		emits = {},
		init = function(self, context)
			M.ensure_completion_state(self)
			return self.stopped
		end,
		ensure_prepared = function(self, context)
			M.ensure_completion_state(self)
			if not self._hello_emitted then
				self._hello_emitted = true
				local line = context and context.line
				if line then
					line:run(M.completion_run(M.COMPLETION_HELLO, line:full_source()))
				end
			end
			return nil
		end,
		ensure_stopped = function(self, context)
			M.ensure_completion_state(self)
			if self._done_emitted then
				return self.stopped
			end
			local line = context and context.line
			if not line then
				return self.stopped
			end
			if line.auto_completion_done_on_close == false then
				return self.stopped
			end
			self._done_emitted = true
			line:run(M.completion_run(M.COMPLETION_DONE, line:full_source()))
			return self.stopped
		end,
			handler = function(run)
			if not M.is_completion_protocol(run) then
				return run.input
			end

			if type(run.segment) ~= "table" then
				return run.input
			end

			local state = M.ensure_completion_state(run.segment)
			local applied = M.apply(state, run)
			if not applied then
				return run.input
			end

			if state.settled then
				if type(state.stopped) == "table" and not state.stopped:is_resolved() then
					state.stopped:resolve(state)
				end
				if run.line and type(run.line.done) == "table" and not run.line.done:is_resolved() then
					run.line.done:resolve(state)
				end
			end

			return nil
		end,
	})
end

return M
