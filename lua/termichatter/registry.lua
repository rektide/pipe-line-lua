--- Registry: repository of known segment type
--- A line inherits from a registry for segment resolution
local inherit = require("termichatter.inherit")

local M = {}

M.type = "registry"
M.segment = {}
M.emits_index = {}

--- Resolve a segment by name from this registry
---@param name string|function|table Segment identifier
---@return function|table|nil segment The resolved segment or nil
function M:resolve(name)
	if type(name) ~= "string" then
		return name
	end

	local found = rawget(self.segment, name)
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

--- Register a segment in this registry
--- Incrementally updates the emits index if the segment has emits metadata
---@param name string Segment name
---@param handler function|table The segment handler
function M:register(name, handler)
	self.segment[name] = handler

	-- incrementally update emits_index
	if type(handler) == "table" and handler.emits then
		local entry = {
			name = name,
			wants = handler.wants or {},
			emits = handler.emits,
			handler = handler,
		}
		for _, e in ipairs(handler.emits) do
			if not self.emits_index[e] then
				self.emits_index[e] = {}
			end
			table.insert(self.emits_index[e], entry)
		end
	end
end

--- Create a child registry inheriting from this one
---@param config? table Optional config to merge
---@return table registry New registry inheriting from self
function M:derive(config)
	local child = inherit.derive(self, {
		type = "registry",
		segment = {},
		emits_index = {},
	})
	if config then
		for k, v in pairs(config) do
			child[k] = v
		end
	end
	return child
end

setmetatable(M, {
	__call = function(_, config)
		return M:derive(config)
	end,
})

return M
