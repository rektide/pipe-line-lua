--- Line: a series of segment that define a pipeline
--- Hold a pipe (the sequence), a registry, output, and mpsc config
local inherit = require("termichatter.inherit")
local Pipe = require("termichatter.pipe")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

local M = {}

M.type = "line"
M.mpsc = {}
M.fact = {}

--- Clone the line with fresh mpsc and output
---@param config? table Optional config to merge
---@return table line New line instance
function M:clone(config)
	config = config or {}

	local pipe_entries = {}
	if config.pipe then
		-- config.pipe can be a pipe object or a plain array
		local src = config.pipe
		for i, p in ipairs(src) do
			pipe_entries[i] = p
		end
	else
		for i, p in ipairs(self.pipe or {}) do
			pipe_entries[i] = p
		end
	end

	local child = inherit.derive(self, {
		type = "line",
		pipe = Pipe.new(pipe_entries),
		mpsc = {},
		fact = {},
		output = MpscQueue.new(),
	})

	for k, v in pairs(config) do
		if k ~= "pipe" then
			child[k] = v
		end
	end

	return child
end

--- Resolve a segment name from the registry chain
---@param name string|function|table Segment identifier
---@return function|table|nil segment Resolved segment
function M:resolve_segment(name)
	if type(name) == "function" or type(name) == "table" then
		return name
	end
	if type(name) ~= "string" then
		return nil
	end

	if rawget(self, name) then
		return rawget(self, name)
	end

	local registry = inherit.walk_field(self, "registry")
	if registry and registry.resolve then
		return registry:resolve(name)
	end

	local mt = getmetatable(self)
	if mt and mt.__index and type(mt.__index) == "table" then
		if mt.__index.resolve_segment then
			return mt.__index:resolve_segment(name)
		end
	end

	return nil
end

--- Create mpsc queue for a segment at given position
---@param pos number Position in pipe array
---@return table queue The MpscQueue instance
function M:ensure_mpsc(pos)
	if not self.mpsc[pos] then
		self.mpsc[pos] = MpscQueue.new()
	end
	return self.mpsc[pos]
end

--- Send an element through the pipeline, creating a run
---@param config? table Config to pass to run (input, noStart, etc)
---@return table run The Run instance
function M:run(config)
	local Run = require("termichatter.run")
	return Run.new(self, config)
end

return M
