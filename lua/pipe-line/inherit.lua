--- Inheritance utility for pipe-line
--- Provides helper for metatable-based inheritance chain
local M = {}

--- Create an object that inherits from a parent via metatable
---@param parent table The parent object to inherit from
---@param child? table Optional child table to extend (defaults to {})
---@return table child The child object with __index pointing to parent
function M.derive(parent, child)
	child = child or {}
	local mt = getmetatable(child) or {}
	mt.__index = parent
	return setmetatable(child, mt)
end

--- Create inheritance from multiple parent (left-to-right priority)
---@param parent table[] Array of parent object
---@param child? table Optional child table to extend
---@return table child The child object with multi-parent lookup
function M.derive_multi(parent, child)
	child = child or {}
	child._parent = parent
	local mt = getmetatable(child) or {}
	mt.__index = function(_, k)
		for _, p in ipairs(parent) do
			local v = p[k]
			if v ~= nil then
				return v
			end
		end
		return nil
	end
	return setmetatable(child, mt)
end

--- Walk the inheritance chain looking for a field
---@param obj table Starting object
---@param field string Field name to find
---@return any value The field value or nil
function M.walk_field(obj, field)
	local current = obj
	while current do
		local v = rawget(current, field)
		if v ~= nil then
			return v
		end
		local mt = getmetatable(current)
		if mt and mt.__index then
			if type(mt.__index) == "table" then
				current = mt.__index
			else
				return current[field]
			end
		else
			return nil
		end
	end
	return nil
end

--- Walk inheritance chain with a predicate function
---@param obj table Starting object
---@param predicate fun(obj: table): any Returns non-nil to stop
---@return any result First non-nil predicate result
function M.walk_predicate(obj, predicate)
	local current = obj
	local visited = {}
	while current and not visited[current] do
		visited[current] = true
		local result = predicate(current)
		if result ~= nil then
			return result
		end
		local mt = getmetatable(current)
		if mt and type(mt.__index) == "table" then
			current = mt.__index
		else
			break
		end
	end
	return nil
end

--- Get the parent chain as an array
---@param obj table Starting object
---@return table[] parent Array of parent object
function M.get_parent(obj)
	local result = {}
	local current = obj
	local visited = {}
	while current and not visited[current] do
		visited[current] = true
		table.insert(result, current)
		local mt = getmetatable(current)
		if mt and type(mt.__index) == "table" then
			current = mt.__index
		else
			break
		end
	end
	return result
end

return M
