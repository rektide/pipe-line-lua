--- termichatter single-stage-mode implementation
--- Uses unified stage table with explicit mode metadata
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

return M
