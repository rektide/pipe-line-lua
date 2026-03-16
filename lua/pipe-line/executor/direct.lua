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
		control = nil,
		accepting = true,
		stop_requested = false,
		stop_mode = nil,
		waiting = false,
		running = false,
		current_run = nil,
		component_stopped = false,
		stopped = Future.new(),
	}

	local stop_signal = {}

	local function mark_component_stopped(self)
		if not self.component_stopped and type(self.control) == "table" then
			self.component_stopped = true
			self.control:mark_component_stopped(self)
		end
	end

	local function execute_run(self, run)
		local control = (run._async and run._async.control) or self.control
		if type(control) == "table" and control:is_stop_immediate() then
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

		if type(control) == "table" and control:is_stop_immediate() then
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
		mark_component_stopped(self)
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
		local control = (run._async and run._async.control) or self.control
		if type(control) == "table" then
			self.control = control
			if control:is_stop_immediate() then
				run:settle(stop_outcome("executor_stop_immediate", "executor stopped immediately"))
				return nil
			end
		end

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

	aspect.ensure_prepared = function(self, context)
		if is_stopped(self.stopped) then
			self.stopped = Future.new()
		end

		local control = context and context.control
		if type(control) == "table" then
			self.control = control
			control:register_component(self)
		end

		self.accepting = true
		self.stop_requested = false
		self.stop_mode = nil
		self.component_stopped = false
		return ensure_runner(self)
	end

	aspect.ensure_stopped = function(self, context)
		local control = (context and context.control) or self.control
		local mode = "stop_drain"
		if type(control) == "table" then
			self.control = control
			control:request_stop(context)
			if control:is_stop_immediate() then
				mode = "stop_immediate"
			end
		end

		self.stop_mode = mode
		self.stop_requested = true

		if mode == "stop_immediate" then
			self.accepting = false
			if is_task_active(self.runner) then
				pcall(function()
					self.runner:cancel()
				end)
				if self.waiting and is_task_active(self.runner) then
					pcall(function()
						self.runner:resume(stop_signal)
					end)
				end
			else
				complete_stopped(self)
			end
			return (type(control) == "table" and control.stopped) or self.stopped
		end

		if type(control) == "table" then
			control:on_drained(function()
				self.accepting = false
				self.stop_requested = true
				if is_task_active(self.runner) and self.waiting then
					pcall(function()
						self.runner:resume(stop_signal)
					end)
				elseif not is_task_active(self.runner) then
					complete_stopped(self)
				end
			end)
		else
			self.accepting = false
			if is_task_active(self.runner) and self.waiting then
				pcall(function()
					self.runner:resume(stop_signal)
				end)
			elseif not is_task_active(self.runner) then
				complete_stopped(self)
			end
		end

		return (type(control) == "table" and control.stopped) or self.stopped
	end

	return aspect
end

setmetatable(M, {
	__call = function(_, config)
		return M.new(config)
	end,
})

return M
