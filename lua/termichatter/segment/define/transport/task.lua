local task = require("coop.task")
local Future = require("coop.future").Future
local common = require("termichatter.segment.define.common")

local M = {}

local function ensure_state(segment)
	if type(segment._termichatter_task_state) ~= "table" then
		segment._termichatter_task_state = {}
	end
	return segment._termichatter_task_state
end

local function ensure_processor(state, segment, context, runtime)
	if type(state.processor) == "function" then
		return state.processor
	end

	local handler_generator = runtime.handler_generator
	if type(handler_generator) == "function" then
		state.processor = handler_generator(segment, context, runtime.wrapped_handler) or runtime.wrapped_handler
	else
		state.processor = runtime.wrapped_handler
	end

	return state.processor
end

local function process_continuation(state, continuation)
	local result = state.processor(continuation)
	if result ~= false then
		continuation:next(result)
	end
end

local function ensure_safe_queue_state(state)
	if type(state.pending) ~= "table" then
		state.pending = {}
	end
	if type(state.waiting) ~= "boolean" then
		state.waiting = false
	end
end

local function create_safe_runner(state)
	state.waiting = false
	state.wake = nil

	return task.create(function()
		while true do
			if #state.pending == 0 then
				state.waiting = true
				state.wake = Future.new()
				local ok = state.wake:pawait()
				state.waiting = false
				if not ok then
					return
				end
			end

			while #state.pending > 0 do
				local continuation = table.remove(state.pending, 1)
				process_continuation(state, continuation)
			end
		end
	end)
end

local function create_unsafe_runner(state)
	return task.create(function()
		while true do
			local ok, continuation = task.pyield()
			if not ok then
				return
			end

			process_continuation(state, continuation)
		end
	end)
end

local function ensure_runner(state, mode)
	if common.is_task_active(state.runner) then
		return state.runner
	end

	if mode == "safe" then
		state.runner = create_safe_runner(state)
	else
		state.runner = create_unsafe_runner(state)
	end

	state.runner:resume()
	return state.runner
end

local function dispatch_safe(state, continuation)
	table.insert(state.pending, continuation)
	if state.waiting and type(state.wake) == "table" and state.wake.done ~= true then
		state.wake:complete(true)
	end
end

function M.new(mode)
	mode = mode or "unsafe"

	return {
		ensure_prepared = function(segment, context, runtime)
			local state = ensure_state(segment)
			ensure_processor(state, segment, context, runtime)
			if mode == "safe" then
				ensure_safe_queue_state(state)
			end
			return ensure_runner(state, mode)
		end,

		handler = function(segment, run, runtime)
			local continuation, should_dispatch = common.prepare_continuation(segment, run, runtime.wrapped_handler)
			if not should_dispatch then
				return false
			end

			local state = ensure_state(segment)
			ensure_processor(state, segment, { line = run.line, run = run, segment = segment }, runtime)
			if mode == "safe" then
				ensure_safe_queue_state(state)
			end

			local runner = ensure_runner(state, mode)
			if mode == "safe" then
				dispatch_safe(state, continuation)
			else
				runner:resume(continuation)
			end

			return common.stop_result_or_false(segment)
		end,

		ensure_stopped = function(segment)
			local state = ensure_state(segment)
			if common.is_task_active(state.runner) then
				state.runner:cancel()
				return state.runner
			end
			return nil
		end,
	}
end

return M
