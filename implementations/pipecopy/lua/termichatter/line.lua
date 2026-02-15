--- Line: a series of pipe that run a `run`
--- The pipeline, a line of pipe
local inherit = require("termichatter.inherit")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

local M = {}

M.type = "line"
M.pipe = {}
M.mpsc = {}
M.rev = 0

--- Splice pipe in the line (like JS Array.splice)
--- Increments rev on modification
---@param startIndex number 1-based start position
---@param deleteCount number Number of element to delete
---@vararg table pipe element to insert
---@return table[] deleted Array of deleted element
function M:splice(startIndex, deleteCount, ...)
	local new = { ... }
	local deleted = {}

	for i = 1, deleteCount do
		local idx = startIndex + i - 1
		if self.pipe[idx] then
			table.insert(deleted, self.pipe[idx])
			if self.mpsc[idx] then
				self.mpsc[idx] = nil
			end
		end
	end

	for _ = 1, deleteCount do
		table.remove(self.pipe, startIndex)
	end

	local shift = 0
	for i, pipe in ipairs(new) do
		local insertAt = startIndex + i - 1
		table.insert(self.pipe, insertAt, pipe)
		shift = shift + 1
	end

	local newMpsc = {}
	for idx, q in pairs(self.mpsc) do
		if idx < startIndex then
			newMpsc[idx] = q
		elseif idx >= startIndex + deleteCount then
			newMpsc[idx - deleteCount + #new] = q
		end
	end
	self.mpsc = newMpsc

	self.rev = self.rev + 1
	return deleted
end

--- Create mpsc queue for a pipe at given position
---@param pos number Position in pipe array
---@return table queue The MpscQueue instance
function M:ensure_mpsc(pos)
	if not self.mpsc[pos] then
		self.mpsc[pos] = MpscQueue.new()
	end
	return self.mpsc[pos]
end

--- Resolve a pipe name from the registry chain
---@param name string|function|table Pipe identifier
---@return function|table|nil pipe Resolved pipe
function M:resolve_pipe(name)
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
		return mt.__index:resolve_pipe(name)
	end

	return nil
end

--- Clone the line with fresh mpsc and output
---@param config? table Optional config to merge
---@return table line New line instance
function M:clone(config)
	local child = inherit.derive(self, {
		type = "line",
		pipe = {},
		mpsc = {},
		rev = 0,
		output = MpscQueue.new(),
	})

	for i, p in ipairs(self.pipe) do
		child.pipe[i] = p
	end

	if config then
		for k, v in pairs(config) do
			if k == "pipe" and type(v) == "table" then
				child.pipe = {}
				for i, p in ipairs(v) do
					child.pipe[i] = p
				end
			else
				child[k] = v
			end
		end
	end

	return child
end

--- Create a run from this line
---@param config? table Config to pass to run
---@return table run The Run instance
function M:run(config)
	local Run = require("termichatter.run")
	return Run.new(self, config)
end

return M
