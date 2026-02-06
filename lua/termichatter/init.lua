--- termichatter: Asynchronous structured-data-flow atop coop.nvim
--- Main module that aggregates all sub-modules
local M = {}

M.protocol = require("termichatter.protocol")
M.processors = require("termichatter.processors")
M.logger = require("termichatter.logger")
M.drivers = require("termichatter.drivers")
local pipelineMod = require("termichatter.pipeline")

-- Re-export common fields for backwards compatibility
M.completion = M.protocol
M.isCompletion = M.protocol.isCompletion
M.isShutdown = M.protocol.isShutdown
M.createCompletionTracker = M.protocol.createCompletionTracker
M.timestamper = M.processors.timestamper
M.ingester = M.processors.ingester
M.cloudevents = M.processors.cloudevents
M.module_filter = M.processors.module_filter
M.uuid = M.processors.uuid
M.priorities = M.logger.priorities
M.baseLogger = M.logger.baseLogger
M.log = pipelineMod.log
M.addProcessor = pipelineMod.addProcessor
M.makePipeline = function(self, config)
	-- Support both termichatter.makePipeline(config) and termichatter:makePipeline(config)
	if self == M or type(self) ~= "table" or (not self.pipeline and not getmetatable(self)) then
		config = self
		self = M
	end
	return pipelineMod.makePipeline(self, config)
end

-- Set default pipeline and queues on M for convenience
M.pipeline = pipelineMod.pipeline
M.queues = pipelineMod.queues

return M


