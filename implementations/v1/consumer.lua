--- Consumer module - async message consumption from queues
--- Uses coop.nvim for async processing
local M = {}

local coop = require("coop")
local protocol = require("termichatter.protocol")
local R = require("termichatter.registry")

--------------------------------------------------
-- Pipeline consumer support
--------------------------------------------------

--- Create a consumer function for a pipeline queue
--- Pops messages and continues them through the pipeline
---@param queue table the mpsc queue
---@param step number the pipeline step this queue is at
---@param pipeline table the pipeline context
---@return function consumer
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
				pipeline:log(msg)
			end
		end
	end
end

--- Start consumers for all async queues in a pipeline
---@param pipeline table
---@return table[] tasks
M.startPipelineConsumers = function(pipeline)
	pipeline._consumerTasks = pipeline._consumerTasks or {}
	for i, queue in ipairs(pipeline.queues) do
		if queue then
			local consumer = M.makePipelineConsumer(queue, i, pipeline)
			local task = coop.spawn(consumer)
			table.insert(pipeline._consumerTasks, task)
		end
	end
	return pipeline._consumerTasks
end

--- Stop all consumer tasks for a pipeline
---@param pipeline table
M.stopPipelineConsumers = function(pipeline)
	if pipeline._consumerTasks then
		for _, task in ipairs(pipeline._consumerTasks) do
			task:cancel()
		end
		pipeline._consumerTasks = {}
	end
end

--- Create an async consumer that processes messages from a queue
--- Runs handlers in order and forwards to next queue or outputter
---@param config table { inputQueue: MpscQueue, handlers: function[], outputQueue?: MpscQueue }
---@return table consumer
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

		--- Process a single message through all handlers
		---@param msg table the message
		---@return table|nil msg the processed message or nil if filtered
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

		--- Start consuming from the input queue
		---@async
		start = function(self)
			running = true
			while running do
				local msg = self.inputQueue:pop()
				if not msg then
					break
				end

				-- Check for shutdown signal - forward and exit
				if protocol.isShutdown(msg) then
					if self.outputQueue then
						self.outputQueue:push(msg)
					end
					break
				end

				-- Forward completion signals without processing
				if protocol.isCompletion(msg) then
					if self.outputQueue then
						self.outputQueue:push(msg)
					end
				else
					-- Process regular message
					local result = self:process(msg)

					-- Forward to output queue if present
					if result and self.outputQueue then
						self.outputQueue:push(result)
					end
				end
			end
			running = false
		end,

		--- Spawn consumer as async task
		---@return Coop.Task task
		spawn = function(self)
			task = coop.spawn(function()
				self:start()
			end)
			return task
		end,

		--- Stop the consumer
		stop = function(self)
			running = false
			if task then
				task:cancel()
				task = nil
			end
		end,

		--- Check if running
		---@return boolean
		isRunning = function(self)
			return running
		end,

		--- Add a handler to the chain
		---@param handler function
		addHandler = function(self, handler)
			table.insert(self.handlers, handler)
		end,
	}
end

--- Create a pipeline of consumers connected by queues
--- Each stage processes messages and forwards to the next
---@param stages table[] array of { handlers: function[] } configs
---@param inputQueue MpscQueue the initial input queue
---@param outputQueue MpscQueue the final output queue
---@return table pipeline with start/stop methods
M.createPipeline = function(stages, inputQueue, outputQueue)
	local MpscQueue = require("coop.mpsc-queue").MpscQueue
	local consumers = {}
	local queues = { inputQueue }

	-- Create intermediate queues and consumers
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

		--- Start all consumers
		start = function(self)
			local tasks = {}
			for _, consumer in ipairs(self.consumers) do
				table.insert(tasks, consumer:spawn())
			end
			return tasks
		end,

		--- Stop all consumers
		stop = function(self)
			for _, consumer in ipairs(self.consumers) do
				consumer:stop()
			end
		end,

		--- Push a message to the pipeline
		---@param msg table
		push = function(self, msg)
			self.queues[1]:push(msg)
		end,

		--- Signal completion to the pipeline
		finish = function(self)
			self.queues[1]:push(vim.deepcopy(protocol.shutdown))
		end,
	}
end

--- Create a driver-backed consumer that runs on a schedule
--- Uses interval or rescheduler driver pattern
---@param config table { consumer: table, driver: table }
---@return table drivenConsumer
M.withDriver = function(config)
	local consumer = config.consumer
	local driver = config.driver

	return {
		consumer = consumer,
		driver = driver,

		--- Start consuming with driver
		start = function(self)
			self.consumer:spawn()
			if self.driver then
				self.driver.start()
			end
		end,

		--- Stop consuming
		stop = function(self)
			if self.driver then
				self.driver.stop()
			end
			self.consumer:stop()
		end,
	}
end

--------------------------------------------------
-- Register built-in consumers with registry
--------------------------------------------------

R.consumers.makePipelineConsumer = M.makePipelineConsumer
R.consumers.startPipelineConsumers = M.startPipelineConsumers
R.consumers.stopPipelineConsumers = M.stopPipelineConsumers
R.consumers.create = M.create
R.consumers.createPipeline = M.createPipeline
R.consumers.withDriver = M.withDriver

return M
