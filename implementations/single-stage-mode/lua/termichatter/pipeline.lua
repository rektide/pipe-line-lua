--- Pipeline implementation with unified stage table
--- Each stage entry stores handler + execution mode metadata
local M = {}

local MpscQueue = require("coop.mpsc-queue").MpscQueue

M.priorities = {
	error = 1,
	warn = 2,
	info = 3,
	log = 4,
	debug = 5,
	trace = 6,
}

M.pipeline = {
	{ handler = "timestamper", mode = "sync" },
	{ handler = "ingester", mode = "sync" },
	{ handler = "cloudevents", mode = "sync" },
	{ handler = "module_filter", mode = "sync" },
}

local function clone_stage(stage)
	local copy = {
		handler = stage.handler,
		mode = stage.mode or "sync",
		queue = stage.queue,
	}

	if type(copy.queue) == "table" then
		copy._queue = copy.queue
		copy.queue = nil
	elseif copy.mode == "mpsc" and copy.queue == nil then
		copy._queue = MpscQueue.new()
	end

	return copy
end

local function stage_queue(stage, context, msg)
	if stage._queue then
		return stage._queue
	end

	local queue = stage.queue
	if type(queue) == "string" then
		return context[queue]
	end
	if type(queue) == "function" then
		return queue(msg, context, stage)
	end
	return queue
end

function M:log(msg)
	msg.pipeStep = msg.pipeStep or 1

	local step = msg.pipeStep
	local stages = self.pipeline or M.pipeline

	while step <= #stages do
		local stage = stages[step]
		local queue = stage_queue(stage, self, msg)

		if queue then
			msg.pipeStep = step
			queue:push(msg)
			return
		end

		local handler = stage.handler
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

	if self.outputQueue then
		self.outputQueue:push(msg)
	end
end

M.addProcessor = function(self, name, handler, position, withQueue)
	position = position or (#self.pipeline + 1)
	self[name] = handler
	table.insert(self.pipeline, position, {
		handler = name,
		mode = withQueue and "mpsc" or "sync",
		_queue = withQueue and MpscQueue.new() or nil,
	})
	return self
end

M.startConsumers = function(self)
	local consumer = require("termichatter.consumer")
	return consumer.startPipelineConsumers(self)
end

M.stopConsumers = function(self)
	local consumer = require("termichatter.consumer")
	consumer.stopPipelineConsumers(self)
end

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

function M:new(...)
	local pipeline = setmetatable({}, { __index = self })

	local stage_source = self.pipeline or M.pipeline

	for i = 1, select("#", ...) do
		local config = select(i, ...)
		if config ~= nil and type(config.pipeline) == "table" then
			stage_source = config.pipeline
		end
	end

	pipeline.pipeline = {}
	for _, stage in ipairs(stage_source) do
		table.insert(pipeline.pipeline, clone_stage(stage))
	end

	pipeline.outputQueue = MpscQueue.new()

	for i = 1, select("#", ...) do
		local config = select(i, ...)
		if config ~= nil then
			for k, v in pairs(config) do
				if k ~= "pipeline" then
					pipeline[k] = v
				end
			end
		end
	end

	M.startConsumers(pipeline)

	return pipeline
end

M.protocol = require("termichatter.protocol")
M.completion = M.protocol
M.isCompletion = M.protocol.isCompletion
M.isShutdown = M.protocol.isShutdown

return M
