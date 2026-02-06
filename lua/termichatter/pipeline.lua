--- Core pipeline logic for message processing
local M = {}

local MpscQueue = require("coop.mpsc-queue").MpscQueue

--- The default pipeline stages
M.pipeline = {
	"timestamper",
	"ingester",
	"cloudevents",
	"module_filter",
}

--- Corresponding queues for pipeline stages (nil = synchronous)
M.queues = {}

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

--- Create a new module/universe with its own pipeline
--- Inherits from self via __index, creates new pipeline/queues
---@param config? table configuration overrides
---@return table module the new module
M.makePipeline = function(self, config)
	config = config or {}

	local module = setmetatable({}, { __index = self })

	module.pipeline = vim.deepcopy(self.pipeline or M.pipeline)
	module.queues = {}
	module.outputQueue = MpscQueue.new()

	for k, v in pairs(config) do
		module[k] = v
	end

	return module
end

return M
