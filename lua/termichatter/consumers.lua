--- Consumer lifecycle and async pipeline management
--- Handles queue consumers, continuation processing, and completion protocol
local M = {}

--- Check if a message is a completion signal
---@param msg table
---@return boolean
M.isCompletion = function(msg)
	return msg.type == "termichatter.completion.done" or msg.type == "termichatter.completion.hello"
end

--- Continue processing a message from its current pipeStep
--- Called by queue consumers to resume pipeline execution
---@param msg table the message (with pipeStep set)
---@param self table the module context
---@return table|nil msg the message or nil if filtered
M.continue = function(msg, self)
	local step = msg.pipeStep
	local pipeline = self.pipeline or {}
	local handler = pipeline[step]

	-- Resolve handler if it's a string
	if type(handler) == "string" then
		handler = self[handler]
	end

	-- Run handler if present
	if handler and type(handler) == "function" then
		msg = handler(msg, self)
		if not msg then
			return nil
		end
	end

	-- Advance to next step and continue through pipeline
	msg.pipeStep = step + 1
	self.log(msg, self)
	return msg
end

--- Create a consumer task for a queue at a specific pipeline step
--- The consumer pops messages and continues them through the pipeline
---@param queue table the mpsc queue to consume from
---@param stepIndex number the step index this queue is at
---@param self table the module context
---@return function consumer async function to run
M.makeQueueConsumer = function(queue, stepIndex, self)
	return function()
		while true do
			local msg = queue:pop()

			-- Check for completion signal
			if M.isCompletion(msg) then
				local nextQueue = nil

				-- Find next queue in pipeline after this step
				for i = stepIndex + 1, #self.pipeline do
					if self.queues and self.queues[i] then
						nextQueue = self.queues[i]
						if type(nextQueue) == "string" then
							nextQueue = self[nextQueue]
						end
						break
					end
				end

				if nextQueue then
					msg.pipeStep = stepIndex + 1
					nextQueue:push(msg)
				elseif self.outputQueue then
					self.outputQueue:push(msg)
				end

				if msg.type == "termichatter.completion.done" then
					break
				end
			else
				M.continue(msg, self)
			end
		end
	end
end

--- Start all queue consumers for this module's pipeline
--- Spawns a coop task for each queue in the pipeline
---@param self table the module
---@return table tasks array of spawned tasks
M.startConsumers = function(self)
	local coop = require("coop")
	local tasks = {}
	local queues = self.queues or {}

	for i = 1, #(self.pipeline or {}) do
		local queue = queues[i]
		if queue then
			local q = queue
			if type(q) == "string" then
				q = self[q]
			end

			if q and type(q) ~= "function" then
				local consumer = M.makeQueueConsumer(q, i, self)
				local task = coop.spawn(consumer)
				table.insert(tasks, task)

				self._consumerTasks = self._consumerTasks or {}
				self._consumerTasks[i] = task
			end
		end
	end

	return tasks
end

--- Stop all queue consumers for this module
---@param self table the module
M.stopConsumers = function(self)
	if self._consumerTasks then
		for _, task in pairs(self._consumerTasks) do
			if task:status() ~= "dead" then
				task:cancel()
			end
		end
		self._consumerTasks = nil
	end
end

--- Signal completion to the pipeline
--- Sends done message to first queue or output queue
---@param self table the module
M.finish = function(self)
	local termichatter = require("termichatter")
	local firstQueue = nil

	for i = 1, #(self.pipeline or {}) do
		if self.queues and self.queues[i] then
			firstQueue = self.queues[i]
			if type(firstQueue) == "string" then
				firstQueue = self[firstQueue]
			elseif type(firstQueue) == "function" then
				firstQueue = firstQueue({})
			end
			break
		end
	end

	local doneMsg = vim.deepcopy(termichatter.completion.done)
	doneMsg.pipeStep = 1

	if firstQueue then
		firstQueue:push(doneMsg)
	elseif self.outputQueue then
		self.outputQueue:push(doneMsg)
	end
end

return M
