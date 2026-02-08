--- Registry for pipeline components
local M = {}

M.processors = {}
M.consumers = {}
M.outputters = {}

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

return M
