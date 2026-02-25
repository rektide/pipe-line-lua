--- Registry: repository of known segment type
--- A line inherits from a registry for segment resolution
local inherit = require("termichatter.inherit")

local M = {}

M.type = "registry"
M.segment = {}
M.emits_index = {}
M.rev = 0
M._emits_by_name = {}

local function parent_registry(self)
	local mt = getmetatable(self)
	if not mt or type(mt.__index) ~= "table" then
		return nil
	end
	if mt.__index.type == "registry" then
		return mt.__index
	end
	return nil
end

local function remove_entry_by_name(bucket, name)
	for i = #bucket, 1, -1 do
		if bucket[i].name == name then
			table.remove(bucket, i)
		end
	end
end

local function copy_entries(entries)
	local out = {}
	for i = 1, #entries do
		out[i] = entries[i]
	end
	return out
end

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
	self.rev = (self.rev or 0) + 1
	self._emits_index_cache = nil
	self._emits_index_cache_rev = nil
	self._emits_index_cache_parent = nil

	self._emits_by_name = self._emits_by_name or {}
	local previous_emits = self._emits_by_name[name]
	if previous_emits then
		for _, fact_name in ipairs(previous_emits) do
			local bucket = self.emits_index[fact_name]
			if bucket then
				remove_entry_by_name(bucket, name)
				if #bucket == 0 then
					self.emits_index[fact_name] = nil
				end
			end
		end
	end
	self._emits_by_name[name] = nil

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
		self._emits_by_name[name] = copy_entries(handler.emits)
	end
end

--- Get effective emits index across this registry and its parents.
--- Result is cached and invalidated when local registry rev changes
--- or parent effective index table changes.
---@return table emits_index
function M:get_emits_index()
	local parent = parent_registry(self)
	local parent_index = nil
	if parent then
		if type(parent.get_emits_index) == "function" then
			parent_index = parent:get_emits_index()
		else
			parent_index = parent.emits_index
		end
	end

	local current_rev = self.rev or 0
	if self._emits_index_cache
		and self._emits_index_cache_rev == current_rev
		and self._emits_index_cache_parent == parent_index
	then
		return self._emits_index_cache
	end

	local merged = {}
	if parent_index then
		for fact_name, entries in pairs(parent_index) do
			merged[fact_name] = copy_entries(entries)
		end
	end

	for fact_name, entries in pairs(self.emits_index or {}) do
		if not merged[fact_name] then
			merged[fact_name] = {}
		end
		for _, entry in ipairs(entries) do
			table.insert(merged[fact_name], entry)
		end
	end

	self._emits_index_cache = merged
	self._emits_index_cache_rev = current_rev
	self._emits_index_cache_parent = parent_index

	return merged
end

--- Create a child registry inheriting from this one
---@param config? table Optional config to merge
---@return table registry New registry inheriting from self
function M:derive(config)
	local child = inherit.derive(self, {
		type = "registry",
		segment = {},
		emits_index = {},
		rev = 0,
		_emits_by_name = {},
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
