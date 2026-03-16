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

---@param config? table
---@return table aspect
function M.new(config)
	config = config or {}

	local aspect = {
		type = "executor.buffered",
		role = "executor",
		queue = config.queue or MpscQueue.new(),
		worker = nil,
		accepting = true,
		stop_mode = nil,
		stop_sentinel = {},
		stop_sentinel_pushed = false,
		stopped = Future.new(),
	}

	local function process_run(self, run)
		if self.stop_mode == "stop_immediate" then
			run:settle({
				status = "error",
				error = {
					code = "executor_stop_immediate",
					message = "executor stopped immediately",
				},
			})
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
		end)

		return self.worker
	end

	aspect.handle = function(self, run)
		if not self.accepting then
			run:settle({
				status = "error",
				error = {
					code = "executor_not_accepting",
					message = "executor is not accepting new runs",
				},
			})
			return nil
		end

		ensure_worker(self)
		self.queue:push(run)
		return nil
	end

	aspect.ensure_prepared = function(self, _context)
		if is_stopped(self.stopped) then
			self.stopped = Future.new()
		end
		self.accepting = true
		self.stop_mode = nil
		self.stop_sentinel_pushed = false
		return ensure_worker(self)
	end

	aspect.ensure_stopped = function(self, context)
		if is_stopped(self.stopped) then
			return self.stopped
		end

		self.accepting = false
		self.stop_mode = stop_type_from_context(context)

		if not is_task_active(self.worker) then
			if not is_stopped(self.stopped) then
				self.stopped:complete({
					stopped = true,
					type = self.type,
				})
			end
			return self.stopped
		end

		if not self.stop_sentinel_pushed then
			self.stop_sentinel_pushed = true
			self.queue:push(self.stop_sentinel)
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
