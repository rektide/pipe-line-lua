local async = require("pipe-line.async")
local Future = require("coop.future").Future
local task = require("coop.task")

local M = {}

local function is_task_active(task_ref)
	if type(task_ref) ~= "table" or type(task_ref.status) ~= "function" then
		return false
	end
	return task_ref:status() ~= "dead"
end

local function is_stopped(stopped)
	return type(stopped) == "table" and stopped.done == true
end

local function stop_type_from_context(context)
	local seg = context and context.segment
	local line = context and context.line
	return (type(seg) == "table" and seg.executor_stop_type)
		or (type(line) == "table" and line.executor_stop_type)
		or "stop_drain"
end

local function stop_outcome(code, message)
	return {
		status = "error",
		error = {
			code = code,
			message = message,
		},
	}
end

local function safe_settle(run, outcome)
	if type(run) ~= "table" or type(run.settle) ~= "function" then
		return
	end
	pcall(function()
		run:settle(outcome)
	end)
end

---@param config? table
---@return table
function M.new(config)
	config = config or {}

	local aspect = {
		type = "executor.direct",
		role = "executor",
		runner = nil,
		accepting = true,
		stop_requested = false,
		stop_mode = nil,
		waiting = false,
		running = false,
		current_run = nil,
		stopped = Future.new(),
	}

	local stop_signal = {}

	local function execute_run(self, run)
		if self.stop_mode == "stop_immediate" then
			safe_settle(run, stop_outcome("executor_stop_immediate", "executor stopped immediately"))
			return
		end

		self.running = true
		self.current_run = run

		local a = run._async
		local context = {
			line = run.line,
			run = run,
			segment = a and a.segment,
			input = a and a.continuation and a.continuation.input or run.input,
		}
		local outcome = async.execute(a.op, context)

		if self.stop_mode == "stop_immediate" then
			outcome = stop_outcome("executor_stop_immediate", "executor stopped immediately")
		end

		safe_settle(run, outcome)
		self.current_run = nil
		self.running = false
	end

	local function complete_stopped(self)
		if not is_stopped(self.stopped) then
			self.stopped:complete({
				stopped = true,
				type = self.type,
			})
		end
	end

	local function ensure_runner(self)
		if is_task_active(self.runner) then
			return self.runner
		end

		self.runner = task.create(function()
			while true do
				if self.stop_requested then
					break
				end

				self.waiting = true
				local ok, run = task.pyield()
				self.waiting = false

				if not ok then
					break
				end

				if run == stop_signal then
					break
				end

				execute_run(self, run)
			end

			if self.current_run ~= nil and self.stop_mode == "stop_immediate" then
				safe_settle(self.current_run, stop_outcome("executor_stop_immediate", "executor stopped immediately"))
				self.current_run = nil
			end

			self.running = false
			self.waiting = false
			self.runner = nil
			complete_stopped(self)
		end)

		self.runner:resume()
		return self.runner
	end

	aspect.handle = function(self, run)
		if not self.accepting then
			run:settle(stop_outcome("executor_not_accepting", "executor is not accepting new runs"))
			return nil
		end

		ensure_runner(self)

		if not self.waiting or self.running then
			run:settle(stop_outcome("executor_direct_busy", "direct executor is busy"))
			return nil
		end

		local ok, err = pcall(function()
			self.runner:resume(run)
		end)
		if not ok then
			run:settle(stop_outcome("executor_direct_resume", tostring(err)))
		end

		return nil
	end

	aspect.ensure_prepared = function(self, _context)
		if is_stopped(self.stopped) then
			self.stopped = Future.new()
		end
		self.accepting = true
		self.stop_requested = false
		self.stop_mode = nil
		return ensure_runner(self)
	end

	aspect.ensure_stopped = function(self, context)
		if is_stopped(self.stopped) then
			return self.stopped
		end

		self.accepting = false
		self.stop_requested = true
		self.stop_mode = stop_type_from_context(context)

		if not is_task_active(self.runner) then
			complete_stopped(self)
			return self.stopped
		end

		if self.stop_mode == "stop_immediate" then
			pcall(function()
				self.runner:cancel()
			end)
		end

		if self.waiting and is_task_active(self.runner) then
			pcall(function()
				self.runner:resume(stop_signal)
			end)
		end

		return self.stopped
	end

	return aspect
end

setmetatable(M, {
	__call = function(_, config)
		return M.new(config)
	end,
})

return M
