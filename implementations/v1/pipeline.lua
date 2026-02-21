--- Pipeline: the core module for structured message flow
--- Self-contained with log methods and pipeline creation
local M = {}

local MpscQueue = require("coop.mpsc-queue").MpscQueue

--------------------------------------------------
-- Priority levels
--------------------------------------------------

M.priorities = {
	error = 1,
	warn = 2,
	info = 3,
	log = 4,
	debug = 5,
	trace = 6,
}

--------------------------------------------------
-- Default pipeline configuration
--------------------------------------------------

M.pipeline = { "timestamper", "ingester", "cloudevents", "module_filter" }
M.queues = {}

--------------------------------------------------
-- Core log function
--------------------------------------------------

--- Send a message through the pipeline
--- Runs sync stages immediately, pushes to queues for async stages
---@param msg table the message
function M:log(msg)
	msg.pipeStep = msg.pipeStep or 1

	local step = msg.pipeStep
	local pipeline = self.pipeline or M.pipeline

	while step <= #pipeline do
		local handler = pipeline[step]
		local queue = self.queues and self.queues[step]

		-- Resolve queue reference
		if type(queue) == "string" then
			queue = self[queue]
		elseif type(queue) == "function" then
			queue = queue(msg)
		end

		-- Async handoff if queue exists
		if queue then
			msg.pipeStep = step
			queue:push(msg)
			return
		end

		-- Resolve and run handler
		if type(handler) == "string" then
			handler = self.registry and self.registry.processors[handler] or self[handler]
		end
		if handler and type(handler) == "function" then
			msg = handler(msg, self)
			if not msg then
				return
			end
		end

		step = step + 1
		msg.pipeStep = step
	end

	-- Push to output queue
	if self.outputQueue then
		self.outputQueue:push(msg)
	end
end

--------------------------------------------------
-- Pipeline modification
--------------------------------------------------

--- Add a processor to the pipeline
---@param self table
---@param name string handler name
---@param handler function
---@param position? number (default: end)
---@param withQueue? boolean create queue at this position
---@return table self for chaining
M.addProcessor = function(self, name, handler, position, withQueue)
	position = position or (#self.pipeline + 1)
	self[name] = handler
	table.insert(self.pipeline, position, name)
	table.insert(self.queues, position, withQueue and MpscQueue.new() or nil)
	return self
end

--------------------------------------------------
-- Consumer support (delegates to consumer module)
--------------------------------------------------

--- Start consumers for async queues in the pipeline
---@param self table
---@return table[] tasks
M.startConsumers = function(self)
	local consumer = require("termichatter.consumer")
	return consumer.startPipelineConsumers(self)
end

--- Stop running consumers
---@param self table
M.stopConsumers = function(self)
	local consumer = require("termichatter.consumer")
	consumer.stopPipelineConsumers(self)
end

--------------------------------------------------
-- Priority log methods (use colon syntax: pipeline:info("msg"))
--------------------------------------------------

local function logWithPriority(self, msg, priority, level)
	if type(msg) == "string" then
		msg = { message = msg }
	else
		msg = vim.deepcopy(msg)
	end
	msg.priority = priority
	msg.priorityLevel = level
	msg.source = msg.source or self.source
	msg.module = msg.module or self.module
	self:log(msg)
	return msg
end

function M:error(msg)
	return logWithPriority(self, msg, "error", 1)
end

function M:warn(msg)
	return logWithPriority(self, msg, "warn", 2)
end

function M:info(msg)
	return logWithPriority(self, msg, "info", 3)
end

function M:debug(msg)
	return logWithPriority(self, msg, "debug", 5)
end

function M:trace(msg)
	return logWithPriority(self, msg, "trace", 6)
end

--------------------------------------------------
-- Pipeline creation
--------------------------------------------------

--- Create a new pipeline with its own queues
--- Inherits handlers from parent, creates independent queues
---@param ... table configuration overrides
---@return table pipeline
function M:new(...)

	local pipeline = setmetatable({}, { __index = self })

	pipeline.pipeline = vim.deepcopy(self.pipeline or M.pipeline)
	pipeline.queues = {}
	local parentQueues = self.queues or {}
	for i = 1, #pipeline.pipeline do
		local parentQueue = parentQueues[i]
		if type(parentQueue) == "table" then
			pipeline.queues[i] = MpscQueue.new()
		else
			pipeline.queues[i] = parentQueue
		end
	end
	pipeline.outputQueue = MpscQueue.new()

	for i = 1, select("#", ...) do
		local config = select(i, ...)
		if config ~= nil then
			for k, v in pairs(config) do
				pipeline[k] = v
			end
		end
	end

	M.startConsumers(pipeline)

	return pipeline
end

--------------------------------------------------
-- Protocol (completion/shutdown signals)
--------------------------------------------------

M.protocol = require("termichatter.protocol")
M.completion = M.protocol
M.isCompletion = M.protocol.isCompletion
M.isShutdown = M.protocol.isShutdown

return M
