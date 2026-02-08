--- Core pipeline logic for message processing
local M = {}

local MpscQueue = require("coop.mpsc-queue").MpscQueue
local coop = require("coop")

--- The default pipeline stages
M.pipeline = {
	"timestamper",
	"ingester",
	"cloudevents",
	"module_filter",
}

--- Corresponding queues for pipeline stages (nil = synchronous)
M.queues = {}

--- Priority levels for logging
M.priorities = {
	error = 1,
	warn = 2,
	info = 3,
	log = 4,
	debug = 5,
	trace = 6,
}

--- Log a message through the pipeline
--- Looks for pipeStep to start from, or sets to 1 and starts
--- Runs sync stages immediately, hands off to queues for async stages
---@param msg table the message to log
---@param self? table the module context (defaults to M)
M.log = function(msg, self)
	self = self or M
	msg.pipeStep = msg.pipeStep or 1

	local step = msg.pipeStep
	local pipeline = self.pipeline or M.pipeline

	while step <= #pipeline do
		local handler = pipeline[step]
		local queue = self.queues and self.queues[step]

		-- Resolve queue if it's a string or function
		if type(queue) == "string" then
			queue = self[queue]
		elseif type(queue) == "function" then
			queue = queue(msg)
		end

		-- If there's a queue at this step, push and return (async handoff)
		-- The consumer for this queue will continue processing
		if queue then
			msg.pipeStep = step
			queue:push(msg)
			return
		end

		-- Resolve handler if it's a string
		if type(handler) == "string" then
			handler = self[handler]
		end

		-- Run handler if present
		if handler and type(handler) == "function" then
			msg = handler(msg, self)
			if not msg then
				return -- Handler filtered the message
			end
		end

		step = step + 1
		msg.pipeStep = step
	end

	-- Message completed pipeline - push to output queue if present
	local outputQueue = self.outputQueue
	if outputQueue then
		outputQueue:push(msg)
	end
end

--- Add a processor to the pipeline at specified position
---@param self table the module
---@param name string the handler name
---@param handler function the handler function
---@param position? number position to insert (default: end)
---@param withQueue? boolean whether to create a queue at this position
---@return table self for chaining
M.addProcessor = function(self, name, handler, position, withQueue)
	position = position or (#self.pipeline + 1)
	self[name] = handler
	table.insert(self.pipeline, position, name)

	if withQueue then
		local queue = MpscQueue.new()
		table.insert(self.queues, position, queue)
	else
		table.insert(self.queues, position, nil)
	end

	return self
end

--- Create a consumer for a specific queue/step in the pipeline
--- The consumer pops messages and continues them through the pipeline
---@param queue table the mpsc queue to consume from
---@param step number the pipeline step this queue is at
---@param self table the pipeline module context
---@return function consumer async consumer function
M.makeQueueConsumer = function(queue, step, self)
	local protocol = require("termichatter.protocol")
	return function()
		while true do
			local msg = queue:pop()
			if not msg then
				break
			end
			if protocol.isShutdown(msg) then
				if self.outputQueue then
					self.outputQueue:push(msg)
				end
				break
			end
			if protocol.isCompletion(msg) then
				if self.outputQueue then
					self.outputQueue:push(msg)
				end
			else
				msg.pipeStep = step + 1
				M.log(msg, self)
			end
		end
	end
end

--- Start consumers for all async queues in the pipeline
---@param self table the pipeline module
---@return table[] tasks array of coop tasks
M.startConsumers = function(self)
	self._consumerTasks = self._consumerTasks or {}
	for i, queue in ipairs(self.queues) do
		if queue then
			local consumer = M.makeQueueConsumer(queue, i, self)
			local task = coop.spawn(consumer)
			table.insert(self._consumerTasks, task)
		end
	end
	return self._consumerTasks
end

--- Stop all running consumer tasks
---@param self table the pipeline module
M.stopConsumers = function(self)
	if self._consumerTasks then
		for _, task in ipairs(self._consumerTasks) do
			task:cancel()
		end
		self._consumerTasks = {}
	end
end

--- Create a new module/universe with its own pipeline
--- Inherits from self via __index, creates NEW queues (not shared)
--- Automatically starts consumers for async stages
---@param config? table configuration overrides
---@return table module the new module
M.makePipeline = function(self, config)
	config = config or {}

	local module = setmetatable({}, { __index = self })

	module.pipeline = vim.deepcopy(self.pipeline or M.pipeline)
	module.queues = {}
	local parentQueues = self.queues or {}
	for i = 1, #module.pipeline do
		if parentQueues[i] then
			module.queues[i] = MpscQueue.new()
		else
			module.queues[i] = nil
		end
	end
	module.outputQueue = MpscQueue.new()

	for k, v in pairs(config) do
		module[k] = v
	end

	M.startConsumers(module)

	return module
end

--- Create a log method for a specific priority level
---@param priority string the priority name
---@param level number the priority level
---@param self table the pipeline module
---@return function logMethod
local function makeLogMethod(priority, level, self)
	return function(msg)
		if type(msg) == "string" then
			msg = { message = msg }
		else
			msg = vim.deepcopy(msg)
		end
		msg.priority = priority
		msg.priorityLevel = level
		if self.source then
			msg.source = msg.source or self.source
		end
		if self.module then
			msg.module = msg.module or self.module
		end
		M.log(msg, self)
		return msg
	end
end

--- Attach log methods (debug, info, warn, error, trace) to a module
--- Note: does not attach 'log' to avoid shadowing the pipeline log function
---@param module table the module to attach methods to
M.attachLogMethods = function(module)
	for name, level in pairs(M.priorities) do
		if name ~= "log" then
			module[name] = makeLogMethod(name, level, module)
		end
	end
end

return M
