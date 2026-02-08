--- Registry for pipeline components
local M = {}

M.processors = {}
M.consumers = {}
M.outputters = {}

--- Get a processor by name
---@param name string
---@return function|table|nil
M.getProcessor = function(name)
	return M.processors[name]
end

--- Get a consumer by name
---@param name string
---@return function|table|nil
M.getConsumer = function(name)
	return M.consumers[name]
end

--- Get an outputter by name
---@param name string
---@return function|table|nil
M.getOutputter = function(name)
	return M.outputters[name]
end

--- Resolve a component name from the registry
---@param name string
---@param context string "processor"|"consumer"|"outputter"
---@return function|table|nil
M.resolve = function(name, context)
	if context == "processor" then
		return M.processors[name]
	elseif context == "consumer" then
		return M.consumers[name]
	elseif context == "outputter" then
		return M.outputters[name]
	end
end

--- Get all registered processors
---@return table
M.getProcessors = function()
	return M.processors
end

--- Get all registered consumers
---@return table
M.getConsumers = function()
	return M.consumers
end

--- Get all registered outputters
---@return table
M.getOutputters = function()
	return M.outputters
end

return M
