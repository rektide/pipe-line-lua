--- Registry for pipeline components
local M = {}

local registry = {
	processors = {},
	consumers = {},
	outputters = {},
}

--- Register a processor
---@param name string
---@param processor function|table
M.registerProcessor = function(name, processor)
	registry.processors[name] = processor
end

--- Register a consumer
---@param name string
---@param consumer function|table
M.registerConsumer = function(name, consumer)
	registry.consumers[name] = consumer
end

--- Register an outputter
---@param name string
---@param outputter function|table
M.registerOutputter = function(name, outputter)
	registry.outputters[name] = outputter
end

--- Get a processor by name
---@param name string
---@return function|table|nil
M.getProcessor = function(name)
	return registry.processors[name]
end

--- Get a consumer by name
---@param name string
---@return function|table|nil
M.getConsumer = function(name)
	return registry.consumers[name]
end

--- Get an outputter by name
---@param name string
---@return function|table|nil
M.getOutputter = function(name)
	return registry.outputters[name]
end

--- Resolve a component name from the registry
---@param name string
---@param context string "processor"|"consumer"|"outputter"
---@return function|table|nil
M.resolve = function(name, context)
	if context == "processor" then
		return registry.processors[name]
	elseif context == "consumer" then
		return registry.consumers[name]
	elseif context == "outputter" then
		return registry.outputters[name]
	end
end

--- Get all registered processors
---@return table
M.getProcessors = function()
	return registry.processors
end

--- Get all registered consumers
---@return table
M.getConsumers = function()
	return registry.consumers
end

--- Get all registered outputters
---@return table
M.getOutputters = function()
	return registry.outputters
end

--- Initialize registry with built-in components
---@return table registry
M.init = function()
	local processors = require("termichatter.processors")
	local consumers = require("termichatter.consumer")
	local outputters = require("termichatter.outputters")

	for name, proc in pairs(processors) do
		if type(proc) == "function" or type(proc) == "table" then
			registry.processors[name] = proc
		end
	end

	for name, cons in pairs(consumers) do
		if type(cons) == "function" or type(cons) == "table" then
			registry.consumers[name] = cons
		end
	end

	for name, out in pairs(outputters) do
		if type(out) == "function" or type(out) == "table" then
			registry.outputters[name] = out
		end
	end

	return M
end

return M
