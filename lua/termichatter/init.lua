--- termichatter: Asynchronous structured-data-flow atop coop.nvim
--- Attaches registry to pipeline
local M = {}

local pipeline = require("termichatter.pipeline")
local registry = require("termichatter.registry")

-- Import modules so they register themselves
local processors = require("termichatter.processors")
local consumer = require("termichatter.consumer")
local outputters = require("termichatter.outputters")
local drivers = require("termichatter.drivers")

-- Start with pipeline as base (log methods inherited via __index)
setmetatable(M, { __index = pipeline })

-- Attach registry
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
