--- termichatter single-stage-table implementation
--- Uses a unified stage table for handler and queue metadata
local M = {}

local pipeline = require("termichatter.pipeline")
local registry = require("termichatter.registry")
local processors = require("termichatter.processors")
local consumer = require("termichatter.consumer")
local outputters = require("termichatter.outputters")
local drivers = require("termichatter.drivers")

setmetatable(M, { __index = pipeline })
M.registry = registry
M.drivers = drivers
M.processors = processors
M.consumer = consumer
M.outputters = outputters

for name, handler in pairs(processors) do
	if type(handler) == "function" and M[name] == nil then
		M[name] = handler
	end
end

M.makePipeline = function(self, config)
	if self == M or type(self) ~= "table" or (not self.pipeline and not getmetatable(self)) then
		config = self
		self = M
	end
	return pipeline.makePipeline(self, config)
end

return M
