--- Registry: repository of known pipe type
--- A line inherits from a registry for pipe resolution
local inherit = require("termichatter.inherit")

local M = {}

M.type = "registry"
M.pipe = {}

--- Resolve a pipe by name from this registry
---@param name string Pipe name to resolve
---@return function|table|nil pipe The resolved pipe or nil
function M:resolve(name)
	if type(name) ~= "string" then
		return name
	end

	local found = rawget(self.pipe, name)
	if found then
		return found
	end

	found = rawget(self, name)
	if found then
		return found
	end

	local mt = getmetatable(self)
	if mt and mt.__index then
		local parent = mt.__index
		if type(parent) == "table" and parent.resolve then
			return parent:resolve(name)
		end
	end

	return nil
end

--- Register a pipe in this registry
---@param name string Pipe name
---@param handler function|table The pipe handler
function M:register(name, handler)
	self.pipe[name] = handler
end

--- Create a child registry inheriting from this one
---@param config? table Optional config to merge
---@return table registry New registry inheriting from self
function M:derive(config)
	local child = inherit.derive(self, {
		type = "registry",
		pipe = {},
	})
	if config then
		for k, v in pairs(config) do
			child[k] = v
		end
	end
	return child
end

return M
