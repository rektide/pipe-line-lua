--- Pipeline implementation with unified stage table
--- Each stage entry stores both handler and queue metadata
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
	{ handler = "timestamper" },
	{ handler = "ingester" },
	{ handler = "cloudevents" },
	{ handler = "module_filter" },
}

local function normalize_stage(item, queue)
	if type(item) == "table" and (item.handler ~= nil or item.queue ~= nil) then
		local stage = vim.deepcopy(item)
		if queue ~= nil then
			stage.queue = queue
		end
		return stage
	end

	return {
		handler = item,
		queue = queue,
	}
end

local function stage_queue(stage, context, msg)
	local queue = stage.queue
	if type(queue) == "string" then
		return context[queue]
	end
	if type(queue) == "function" then
		return queue(msg)
	end
	return queue
end

local function stage_pipeline(context)
	local current = context.pipeline or M.pipeline
	local compat_queues = context.queues
	local stages = {}
	for i = 1, #current do
		stages[i] = normalize_stage(current[i], compat_queues and compat_queues[i] or nil)
	end
	return stages
end

M.log = function(msg, self)
	self = self or M
	msg.pipeStep = msg.pipeStep or 1

	local step = msg.pipeStep
	local stages = stage_pipeline(self)

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
	local stages = stage_pipeline(self)
	position = position or (#stages + 1)
	self[name] = handler
	table.insert(stages, position, {
		handler = name,
		queue = withQueue and MpscQueue.new() or nil,
	})
	self.pipeline = stages
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
	M.log(msg, self)
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

M.makePipeline = function(self, config)
	if self == M or type(self) ~= "table" or (not self.pipeline and not getmetatable(self)) then
		config = self
		self = M
	end
	config = config or {}

	local pipeline = setmetatable({}, { __index = self })
	pipeline.pipeline = {}

	for _, stage in ipairs(stage_pipeline(self)) do
		table.insert(pipeline.pipeline, {
			handler = stage.handler,
			queue = stage.queue and MpscQueue.new() or nil,
		})
	end

	pipeline.outputQueue = MpscQueue.new()

	for k, v in pairs(config) do
		pipeline[k] = v
	end

	M.startConsumers(pipeline)

	return pipeline
end

M.protocol = require("termichatter.protocol")
M.completion = M.protocol
M.isCompletion = M.protocol.isCompletion
M.isShutdown = M.protocol.isShutdown

return M
