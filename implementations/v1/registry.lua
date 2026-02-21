--- Registry for pipeline components
local R = {}

R.processors = {}
R.consumers = {}
R.outputters = {}

--- Resolve a component name from the registry
--- First checks top-level, then scans through sub-registry tables
---@param name string
---@param context string "processor"|"consumer"|"outputter" (unused but kept for compatibility)
---@return function|table|nil
R.resolve = function(name, context)
	-- First check top-level match
	if R[name] then
		return R[name]
	end

	-- Then scan through each top-level item
	for key, subRegistry in pairs(R) do
		if type(subRegistry) == "table" and subRegistry[name] then
			return subRegistry[name]
		end
	end

	return nil
end

return R
