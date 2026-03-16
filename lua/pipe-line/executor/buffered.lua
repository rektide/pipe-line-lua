local async = require("pipe-line.async")
local coop = require("coop")
local Future = require("coop.future").Future
local MpscQueue = require("coop.mpsc-queue").MpscQueue

local M = {}

local function is_task_active(task)
	if type(task) ~= "table" or type(task.status) ~= "function" then
		return false
	end
	return task:status() ~= "dead"
end

local function stop_type_from_context(context)
	local seg = context and context.segment
	local line = context and context.line
	return (type(seg) == "table" and seg.executor_stop_type)
		or (type(line) == "table" and line.executor_stop_type)
		or "stop_drain"
end

local function is_stopped(stopped)
	return type(stopped) == "table" and stopped.done == true
end

local function settle_executor_error(run, code, message)
	run:settle({
		status = "error",
		error = {
			code = code,
			message = message,
		},
	})
end

---@param config? table
---@return table aspect
function M.new(config)
	config = config or {}

	local aspect = {
		type = "executor.buffered",
		role = "executor",
		queue = config.queue or MpscQueue.new(),
		worker = nil,
		control = nil,
		accepting = true,
		stop_mode = nil,
		stop_sentinel = {},
		stop_sentinel_pushed = false,
		component_stopped = false,
		stopped = Future.new(),
	}

	local function mark_component_stopped(self)
		if not self.component_stopped and type(self.control) == "table" then
			self.component_stopped = true
			self.control:mark_component_stopped(self)
		end
	end

	local function process_run(self, run)
		local control = (run._async and run._async.control) or self.control
		if type(control) == "table" and control:is_stop_immediate() then
			settle_executor_error(run, "executor_stop_immediate", "executor stopped immediately")
			return
		end

		local a = run._async
		local context = {
			line = run.line,
			run = run,
			segment = a and a.segment,
			input = a and a.continuation and a.continuation.input or run.input,
		}
		local outcome = async.execute(a.op, context)
		run:settle(outcome)
	end

	local function ensure_worker(self)
		if is_task_active(self.worker) then
			return self.worker
		end

		self.worker = coop.spawn(function()
			while true do
				local queued_run = self.queue:pop()
				if queued_run == self.stop_sentinel then
					break
				end
				process_run(self, queued_run)
			end

			self.worker = nil
			if not is_stopped(self.stopped) then
				self.stopped:complete({
					stopped = true,
					type = self.type,
				})
			end
			mark_component_stopped(self)
		end)

		return self.worker
	end

	local function request_stop_worker(self)
		if not is_task_active(self.worker) then
			if not is_stopped(self.stopped) then
				self.stopped:complete({
					stopped = true,
					type = self.type,
				})
			end
			mark_component_stopped(self)
			return
		end

		if not self.stop_sentinel_pushed then
			self.stop_sentinel_pushed = true
			self.queue:push(self.stop_sentinel)
		end
	end

	aspect.handle = function(self, run)
		local control = (run._async and run._async.control) or self.control
		if type(control) == "table" then
			self.control = control
			if control:is_stop_immediate() then
				settle_executor_error(run, "executor_stop_immediate", "executor stopped immediately")
				return nil
			end
		end

		if not self.accepting then
			settle_executor_error(run, "executor_not_accepting", "executor is not accepting new runs")
			return nil
		end

		ensure_worker(self)
		self.queue:push(run)
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
		self.stop_mode = nil
		self.stop_sentinel_pushed = false
		self.component_stopped = false
		return ensure_worker(self)
	end

	aspect.ensure_stopped = function(self, context)
		local control = (context and context.control) or self.control
		local mode = stop_type_from_context(context)
		if type(control) == "table" then
			self.control = control
			control:request_stop(mode)
			mode = control.stop_type or mode
		end

		self.stop_mode = mode

		if mode == "stop_immediate" then
			self.accepting = false
			request_stop_worker(self)
			return (type(control) == "table" and control.stopped) or self.stopped
		end

		if type(control) == "table" then
			control:on_drained(function()
				self.accepting = false
				request_stop_worker(self)
			end)
		else
			self.accepting = false
			request_stop_worker(self)
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
