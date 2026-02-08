--- Pipeline: the core module for structured message flow
--- Self-contained with processors, log methods, and pipeline creation
local M = {}

local MpscQueue = require("coop.mpsc-queue").MpscQueue
local coop = require("coop")

-- Seed random once for UUID generation
math.randomseed(vim.uv.hrtime())

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
-- Built-in processors (pipeline stage handlers)
--------------------------------------------------

--- Add high-resolution timestamp
---@param msg table
---@return table
M.timestamper = function(msg)
	msg.time = msg.time or vim.uv.hrtime()
	return msg
end

--- No-op ingester (override to customize)
---@param msg table
---@return table
M.ingester = function(msg)
	return msg
end

--- Generate UUID v4
---@return string
M.uuid = function()
	local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
	return string.gsub(template, "[xy]", function(c)
		local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
		return string.format("%x", v)
	end)
end

--- Add CloudEvents fields (id, source, specversion)
---@param msg table
---@param self table
---@return table
M.cloudevents = function(msg, self)
	msg.id = msg.id or M.uuid()
	msg.source = msg.source or self.source
	msg.specversion = msg.specversion or "1.0"
	return msg
end

--- Filter by source/module pattern
---@param msg table
---@param self table
---@return table|nil
M.module_filter = function(msg, self)
	local filter = self.filter
	if not filter then
		return msg
	end
	local source = msg.source or msg.module or ""
	if type(filter) == "string" then
		return string.match(source, filter) and msg or nil
	elseif type(filter) == "function" then
		return filter(msg, self) and msg or nil
	end
	return msg
end

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
---@param self? table the pipeline context (defaults to M)
M.log = function(msg, self)
	self = self or M
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
			handler = self[handler]
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
-- Pipeline creation
--------------------------------------------------

--- Create a log method for a priority level
local function makeLogMethod(priority, level, self)
	return function(msg)
		if type(msg) == "string" then
			msg = { message = msg }
		else
			msg = vim.deepcopy(msg)
		end
		msg.priority = priority
		msg.priorityLevel = level
		msg.source = msg.source or self.source
		msg.module = msg.module or self.module
		M.log(msg, self)
		return msg
	end
end

--- Attach priority log methods (debug, info, warn, error, trace)
---@param module table
M.attachLogMethods = function(module)
	for name, level in pairs(M.priorities) do
		if name ~= "log" then
			module[name] = makeLogMethod(name, level, module)
		end
	end
end

--- Create a new pipeline with its own queues
--- Inherits handlers from parent, creates independent queues
---@param self? table parent to inherit from
---@param config? table configuration overrides
---@return table pipeline
M.makePipeline = function(self, config)
	-- Handle both M.makePipeline(config) and M:makePipeline(config)
	if self == M or type(self) ~= "table" or (not self.pipeline and not getmetatable(self)) then
		config = self
		self = M
	end
	config = config or {}

	local pipeline = setmetatable({}, { __index = self })

	pipeline.pipeline = vim.deepcopy(self.pipeline or M.pipeline)
	pipeline.queues = {}
	local parentQueues = self.queues or {}
	for i = 1, #pipeline.pipeline do
		pipeline.queues[i] = parentQueues[i] and MpscQueue.new() or nil
	end
	pipeline.outputQueue = MpscQueue.new()

	for k, v in pairs(config) do
		pipeline[k] = v
	end

	M.attachLogMethods(pipeline)
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
