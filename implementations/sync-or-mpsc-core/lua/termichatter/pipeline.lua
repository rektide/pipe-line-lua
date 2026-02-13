local M = {}

local MpscQueue = require("coop.mpsc-queue").MpscQueue

M.pipeline = {}

local function clone_stage(stage)
	local copy = {
		handler = stage.handler,
		queue = stage.queue,
		mode = stage.mode,
	}

	if copy.queue == true or (copy.queue == nil and (copy.mode == "mpsc" or stage.async == true)) then
		copy._queue = MpscQueue.new()
		copy.queue = nil
	elseif type(copy.queue) == "table" and type(copy.queue.push) == "function" then
		copy._queue = copy.queue
		copy.queue = nil
	end

	return copy
end

local function resolve_stage_queue(pipeline, stage, msg)
	if stage._queue then
		return stage._queue
	end

	local queue = stage.queue
	if type(queue) == "string" then
		queue = pipeline[queue]
	elseif type(queue) == "function" then
		queue = queue(msg, pipeline, stage)
	end

	if queue and type(queue.push) == "function" then
		return queue
	end

	return nil
end

local function resolve_handler(pipeline, stage)
	local handler = stage.handler
	if type(handler) == "string" then
		handler = pipeline[handler]
	end
	if type(handler) ~= "function" then
		return nil
	end
	return handler
end

function M:_run_from(msg, start_step)
	local step = start_step or 1
	while step <= #(self.pipeline or {}) do
		local stage = self.pipeline[step]
		if not stage then
			step = step + 1
		else
			local queue = resolve_stage_queue(self, stage, msg)
			if queue then
				msg.pipeStep = step
				queue:push(msg)
				return
			end

			local handler = resolve_handler(self, stage)
			if handler then
				msg = handler(msg, self, stage)
				if not msg then
					return
				end
			end

			step = step + 1
		end
	end

	if self.outputQueue then
		self.outputQueue:push(msg)
		return
	end

	return msg
end

function M:log(msg)
	return self:_run_from(msg, msg.pipeStep or 1)
end

function M:startConsumers()
	local consumer = require("termichatter.consumer")
	return consumer.start_pipeline_consumers(self)
end

function M:stopConsumers()
	local consumer = require("termichatter.consumer")
	consumer.stop_pipeline_consumers(self)
end

function M:addStage(stage, position)
	local at = position or (#self.pipeline + 1)
	table.insert(self.pipeline, at, clone_stage(stage))
	return self
end

function M:new(config)
	local next_pipeline = setmetatable({}, { __index = self })
	next_pipeline.pipeline = {}

	for _, stage in ipairs(self.pipeline or M.pipeline) do
		table.insert(next_pipeline.pipeline, clone_stage(stage))
	end

	next_pipeline.outputQueue = MpscQueue.new()

	if config then
		for key, value in pairs(config) do
			if key == "pipeline" and type(value) == "table" then
				next_pipeline.pipeline = {}
				for _, stage in ipairs(value) do
					table.insert(next_pipeline.pipeline, clone_stage(stage))
				end
			else
				next_pipeline[key] = value
			end
		end
	end

	next_pipeline:startConsumers()

	return next_pipeline
end

return M
