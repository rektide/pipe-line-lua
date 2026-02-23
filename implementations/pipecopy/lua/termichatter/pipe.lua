--- Standard pipe library for pipecopy
--- Common processor pipe

local M = {}

--- Create a new Pipe array object with splice/clone support
---@param entries? table Array of segment name
---@return table pipe Pipe array object
function M.new(entries)
	local p = {}
	for i, e in ipairs(entries or {}) do
		p[i] = e
	end
	p.rev = 0
	p.splice_journal = {}

	function p:splice(startIndex, deleteCount, ...)
		local new = { ... }
		local deleted = {}
		for i = 1, deleteCount do
			local idx = startIndex + i - 1
			if self[idx] then
				table.insert(deleted, self[idx])
			end
		end
		for _ = 1, deleteCount do
			table.remove(self, startIndex)
		end
		for i, pipe in ipairs(new) do
			table.insert(self, startIndex + i - 1, pipe)
		end
		self.rev = self.rev + 1
		table.insert(self.splice_journal, {
			rev = self.rev,
			start = startIndex,
			deleted = deleteCount,
			inserted = #new,
		})
		return deleted
	end

	function p:clone()
		local c = M.new(self)
		c.rev = self.rev
		return c
	end

	return p
end

--- Timestamper pipe: add hrtime timestamp
---@param run table The run context
---@return any input Modified input or original
function M.timestamper(run)
	local input = run.input
	if type(input) == "table" then
		input.time = vim.uv.hrtime()
	end
	return input
end

--- CloudEvent enricher pipe: add id, source, type, specversion
---@param run table The run context
---@return any input Modified input or original
function M.cloudevent(run)
	local input = run.input
	if type(input) ~= "table" then
		return input
	end

	if not input.id then
		local random = math.random
		input.id = string.format(
			"%08x-%04x-%04x-%04x-%012x",
			random(0, 0xffffffff),
			random(0, 0xffff),
			random(0x4000, 0x4fff),
			random(0x8000, 0xbfff),
			random(0, 0xffffffffffff)
		)
	end

	input.specversion = input.specversion or "1.0"
	input.source = input.source or run.source or run.line and run.line.source
	input.type = input.type or "termichatter.log"

	return input
end

--- Module filter pipe: filter by source pattern
---@param run table The run context
---@return any input Input if passes filter, nil otherwise
function M.module_filter(run)
	local input = run.input
	local filter = run.filter or (run.line and run.line.filter)

	if not filter then
		return input
	end

	local source = type(input) == "table" and input.source or nil
	if not source then
		return input
	end

	if type(filter) == "function" then
		if filter(source, input, run) then
			return input
		end
		return nil
	end

	if type(filter) == "string" then
		if string.match(source, filter) then
			return input
		end
		return nil
	end

	return input
end

--- Priority filter pipe: filter by log level
---@param run table The run context
---@return any input Input if passes filter, nil otherwise
function M.priority_filter(run)
	local input = run.input
	local minLevel = run.minLevel or (run.line and run.line.minLevel) or 0

	if type(input) ~= "table" then
		return input
	end

	local level = input.priorityLevel or 0
	if level >= minLevel then
		return input
	end

	return nil
end

--- Ingester pipe: apply custom decoration
---@param run table The run context
---@return any input Modified input
function M.ingester(run)
	local input = run.input
	local ingester = run.ingest or (run.line and run.line.ingest)

	if type(ingester) == "function" then
		return ingester(input, run)
	end

	return input
end

return M
