--- Consumer module - async message consumption from queues
--- Single-stage-table implementation support
local M = {}

local coop = require("coop")
local protocol = require("termichatter.protocol")
local R = require("termichatter.registry")

M.makePipelineConsumer = function(queue, step, pipeline)
	return function()
		while true do
			local msg = queue:pop()
			if not msg then
				break
			end
			if protocol.isShutdown(msg) then
				if pipeline.outputQueue then
					pipeline.outputQueue:push(msg)
				end
				break
			end
			if protocol.isCompletion(msg) then
				if pipeline.outputQueue then
					pipeline.outputQueue:push(msg)
				end
			else
				msg.pipeStep = step + 1
				local pipelineMod = require("termichatter.pipeline")
				pipelineMod.log(msg, pipeline)
			end
		end
	end
end

local function queue_for_stage(stage, pipeline, index)
	if type(stage) == "table" and (stage.handler ~= nil or stage.queue ~= nil) then
		return stage.queue
	end
	if pipeline.queues then
		return pipeline.queues[index]
	end
	return nil
end

M.startPipelineConsumers = function(pipeline)
	pipeline._consumerTasks = pipeline._consumerTasks or {}
	local stages = pipeline.pipeline or {}
	for i, stage in ipairs(stages) do
		local queue = queue_for_stage(stage, pipeline, i)
		if queue then
			local consumer = M.makePipelineConsumer(queue, i, pipeline)
			local task = coop.spawn(consumer)
			table.insert(pipeline._consumerTasks, task)
		end
	end
	return pipeline._consumerTasks
end

M.stopPipelineConsumers = function(pipeline)
	if pipeline._consumerTasks then
		for _, task in ipairs(pipeline._consumerTasks) do
			task:cancel()
		end
		pipeline._consumerTasks = {}
	end
end

M.create = function(config)
	config = config or {}
	local inputQueue = config.inputQueue
	local handlers = config.handlers or {}
	local outputQueue = config.outputQueue

	local running = false
	local task = nil

	return {
		inputQueue = inputQueue,
		outputQueue = outputQueue,
		handlers = handlers,

		process = function(self, msg)
			local result = msg
			for _, handler in ipairs(self.handlers) do
				if not result then
					break
				end
				result = handler(result)
			end
			return result
		end,

		start = function(self)
			running = true
			while running do
				local msg = self.inputQueue:pop()
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
					local result = self:process(msg)
					if result and self.outputQueue then
						self.outputQueue:push(result)
					end
				end
			end
			running = false
		end,

		spawn = function(self)
			task = coop.spawn(function()
				self:start()
			end)
			return task
		end,

		stop = function(self)
			running = false
			if task then
				task:cancel()
				task = nil
			end
		end,

		isRunning = function()
			return running
		end,

		addHandler = function(self, handler)
			table.insert(self.handlers, handler)
		end,
	}
end

M.createPipeline = function(stages, inputQueue, outputQueue)
	local MpscQueue = require("coop.mpsc-queue").MpscQueue
	local consumers = {}
	local queues = { inputQueue }

	for i, stageConfig in ipairs(stages) do
		local nextQueue
		if i == #stages then
			nextQueue = outputQueue
		else
			nextQueue = MpscQueue.new()
			table.insert(queues, nextQueue)
		end

		local consumer = M.create({
			inputQueue = queues[i],
			handlers = stageConfig.handlers or {},
			outputQueue = nextQueue,
		})
		table.insert(consumers, consumer)
	end

	return {
		consumers = consumers,
		queues = queues,

		start = function(self)
			local tasks = {}
			for _, consumer in ipairs(self.consumers) do
				table.insert(tasks, consumer:spawn())
			end
			return tasks
		end,

		stop = function(self)
			for _, consumer in ipairs(self.consumers) do
				consumer:stop()
			end
		end,

		push = function(self, msg)
			self.queues[1]:push(msg)
		end,

		finish = function(self)
			self.queues[1]:push(vim.deepcopy(protocol.shutdown))
		end,
	}
end

M.withDriver = function(config)
	local consumer = config.consumer
	local driver = config.driver

	return {
		consumer = consumer,
		driver = driver,

		start = function(self)
			self.consumer:spawn()
			if self.driver then
				self.driver.start()
			end
		end,

		stop = function(self)
			if self.driver then
				self.driver.stop()
			end
			self.consumer:stop()
		end,
	}
end

R.consumers.makePipelineConsumer = M.makePipelineConsumer
R.consumers.startPipelineConsumers = M.startPipelineConsumers
R.consumers.stopPipelineConsumers = M.stopPipelineConsumers
R.consumers.create = M.create
R.consumers.createPipeline = M.createPipeline
R.consumers.withDriver = M.withDriver

return M
