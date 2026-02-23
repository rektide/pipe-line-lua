--- Run: a self-running cursor that walk/visit a pipeline
--- Cursor-like entity that walks the line
local inherit = require("termichatter.inherit")

local M = {}

M.type = "run"

--- Get pipe at current position
---@param self table Run instance
---@return table|function|nil pipe Current pipe or nil if past end
local function get_current(self)
	if self.pos > #self.pipe then
		return nil
	end
	return self.pipe[self.pos]
end

--- Resolve the current pipe's name for debug
---@param self table Run instance
---@return string|nil name Pipe name or nil
local function get_pos_name(self)
	local current = get_current(self)
	if type(current) == "string" then
		return current
	end
	if type(current) == "table" and current.name then
		return current.name
	end
	return nil
end

--- Splice the run's pipe array, adjusting pos
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
		end
	end

	for _ = 1, deleteCount do
		table.remove(self.pipe, startIndex)
	end

	for i, pipe in ipairs(new) do
		local insertAt = startIndex + i - 1
		table.insert(self.pipe, insertAt, pipe)
	end

	if self.pos >= startIndex then
		if self.pos < startIndex + deleteCount then
			self.pos = startIndex
		else
			self.pos = self.pos - deleteCount + #new
		end
	end

	self.rev = (self.rev or 0) + 1
	return deleted
end

--- Advance to next position
---@return boolean continue True if more pipe remain
function M:next()
	self.pos = self.pos + 1
	self.current = get_current(self)
	self.posName = get_pos_name(self)
	return self.pos <= #self.pipe
end

--- Set position (by index or by searching for name)
---@param target number|string Position index or pipe name
---@return boolean found True if position was set
function M:goto(target)
	if type(target) == "number" then
		self.pos = target
		self.current = get_current(self)
		self.posName = get_pos_name(self)
		return self.pos >= 1 and self.pos <= #self.pipe
	end

	for i, p in ipairs(self.pipe) do
		local name = type(p) == "string" and p or (type(p) == "table" and p.name)
		if name == target then
			self.pos = i
			self.current = get_current(self)
			self.posName = get_pos_name(self)
			return true
		end
	end

	return false
end

--- Resolve a pipe identifier to a callable
---@param pipe string|function|table Pipe identifier
---@return function|nil handler Resolved handler function
function M:resolve(pipe)
	if type(pipe) == "function" then
		return pipe
	end

	if type(pipe) == "table" then
		if type(pipe.handler) == "function" then
			return pipe.handler
		end
		if type(pipe.handler) == "string" then
			return self:resolve(pipe.handler)
		end
		if getmetatable(pipe) and type(getmetatable(pipe).__call) == "function" then
			return pipe
		end
		return nil
	end

	if type(pipe) == "string" then
		local resolved = self.line:resolve_pipe(pipe)
		if resolved then
			return self:resolve(resolved)
		end
	end

	return nil
end

--- Check if pipe at position is async (mpsc mode)
---@param pos? number Position to check (defaults to current)
---@return boolean async True if pipe is async
function M:is_async(pos)
	pos = pos or self.pos
	local pipe = self.pipe[pos]

	if self.mpsc and self.mpsc[pos] then
		return true
	end

	if type(pipe) == "table" then
		if pipe.mode == "mpsc" or pipe.async == true then
			return true
		end
	end

	return false
end

--- Get the mpsc queue for a position
---@param pos? number Position (defaults to current)
---@return table|nil queue MpscQueue or nil if sync
function M:get_queue(pos)
	pos = pos or self.pos
	if self.mpsc and self.mpsc[pos] then
		return self.mpsc[pos]
	end
	if self.line and self.line.mpsc and self.line.mpsc[pos] then
		return self.line.mpsc[pos]
	end
	return nil
end

--- Execute the current pipe
---@return any result Handler result or nil
function M:exec()
	local pipe = self.current
	if not pipe then
		return nil
	end

	local handler = self:resolve(pipe)
	if not handler then
		return nil
	end

	local result
	if type(handler) == "table" and getmetatable(handler) and getmetatable(handler).__call then
		result = handler(self)
	else
		result = handler(self)
	end

	return result
end

--- Push data to next stage (sync or async)
---@param data any Data to push
function M:push(data)
	local nextPos = self.pos + 1

	if nextPos > #self.pipe then
		local output = self.output or self.outputQueue
		if not output and self.line then
			output = self.line.output or self.line.outputQueue
		end
		if output then
			output:push(data)
		end
		return
	end

	local queue = self:get_queue(nextPos)
	if queue then
		queue:push(data)
	else
		local saved_pos = self.pos
		self.pos = nextPos
		self.current = get_current(self)
		self.posName = get_pos_name(self)
		self.input = data
		self:exec()
		self.pos = saved_pos
		self.current = get_current(self)
		self.posName = get_pos_name(self)
	end
end

--- Take ownership of a field, creating a private copy on this run
---@param field string Field name to own ("pipe", "fact", etc.)
function M:own(field)
	if field == "pipe" then
		local current = self.pipe
		if current and current.clone then
			rawset(self, "pipe", current:clone())
		else
			local PipeMod = require("termichatter.pipe")
			rawset(self, "pipe", PipeMod.new(current or {}))
		end
	elseif field == "fact" then
		local current = self.fact or {}
		local snapshot = {}
		for k, v in pairs(current) do
			snapshot[k] = v
		end
		rawset(self, "fact", snapshot)
	else
		local current = self[field]
		if current ~= nil then
			rawset(self, field, current)
		end
	end
end

--- Run the pipeline from current position
---@return any result Final result
function M:execute()
	while self.pos <= #self.pipe do
		self.current = get_current(self)
		self.posName = get_pos_name(self)

		local queue = self:get_queue()
		if queue then
			queue:push(self.input)
			return
		end

		local handler = self:resolve(self.current)
		if handler then
			local pos_before = self.pos
			local result = self:exec()
			if result == false then
				return nil
			end
			if result ~= nil then
				self.input = result
			end
			-- if handler changed pos (e.g. resolver splice), don't auto-advance
			if self.pos ~= pos_before then
				-- pos was modified by handler, re-loop from new pos
			else
				self:next()
			end
		else
			self:next()
		end
	end

	local output = self.output or self.outputQueue
	if not output and self.line then
		output = self.line.output or self.line.outputQueue
	end
	if output then
		output:push(self.input)
	end

	return self.input
end

--- Create a new Run for a line
---@param line table The line to run
---@param config? table Config (noStart, input, etc)
---@return table run The Run instance
function M.new(line, config)
	config = config or {}

	local PipeMod = require("termichatter.pipe")
	local src_pipe = line.pipe or {}
	local pipe
	if src_pipe.clone then
		pipe = src_pipe:clone()
	else
		pipe = PipeMod.new(src_pipe)
	end

	local run = inherit.derive(line, {
		type = "run",
		line = line,
		pipe = pipe,
		pos = 1,
		mpsc = line.mpsc,
		output = line.output or line.outputQueue,
		input = config.input,
	})

	for k, v in pairs(config) do
		if k ~= "noStart" and k ~= "input" then
			run[k] = v
		end
	end

	run.current = get_current(run)
	run.posName = get_pos_name(run)

	for k, v in pairs(M) do
		if type(v) == "function" and k ~= "new" then
			run[k] = v
		end
	end

	if not config.noStart then
		run:execute()
	end

	return run
end

return M
