--- Run: a lightweight cursor/context that walk a line's pipe
--- Methods live on the prototype, not copied per-instance
--- Supports clone/fork/own for fan-out and independence
local inherit = require("termichatter.inherit")
local Pipe = require("termichatter.pipe")
local util = require("termichatter.util")

local Run = {}
Run.type = "run"

--- Resolve a segment identifier to a callable
---@param seg string|function|table Segment identifier
---@return function|nil handler Resolved handler function
function Run:resolve(seg)
	if type(seg) == "function" then
		return seg
	end

	if type(seg) == "table" then
		if type(seg.handler) == "function" then
			return seg.handler
		end
		if type(seg.handler) == "string" then
			return self:resolve(seg.handler)
		end
		local mt = getmetatable(seg)
		if mt and type(mt.__call) == "function" then
			return seg
		end
		return nil
	end

	if type(seg) == "string" then
		local registry = self.registry or (self.line and self.line.registry)
		if registry and registry.resolve then
			local resolved = registry:resolve(seg)
			if resolved then
				return self:resolve(resolved)
			end
		end
		-- check line directly
		if self.line then
			local v = rawget(self.line, seg)
			if v then
				return self:resolve(v)
			end
		end
	end

	return nil
end

--- Sync position with the pipe's splice journal
--- No-op if we own our pipe or if rev matches
function Run:sync()
	local active_pipe = self.pipe
	if not active_pipe then
		return
	end

	local my_rev = self._rev or 0
	if my_rev == active_pipe.rev then
		return
	end

	for _, entry in ipairs(active_pipe.splice_journal) do
		if entry.rev > my_rev then
			if self.pos >= entry.start + entry.deleted then
				self.pos = self.pos - entry.deleted + entry.inserted
			elseif self.pos >= entry.start then
				self.pos = entry.start
			end
		end
	end

	rawset(self, "_rev", active_pipe.rev)
end

--- Execute the pipeline from current position
---@return any result Final result
function Run:execute()
	self:sync()
	while self.pos <= #self.pipe do
		local seg = self.pipe[self.pos]
		if type(seg) == "string" then
			local resolved
			if self.line and type(self.line.resolve_segment) == "function" then
				resolved = self.line:resolve_segment(seg)
			else
				resolved = self:resolve(seg)
			end
			if util.is_segment_factory(resolved) then
				seg = resolved.create()
				self.pipe[self.pos] = seg
			end
		end
		local handler = self:resolve(seg)
		if handler then
			local result = handler(self)
			if result == false then
				return nil
			end
			if result ~= nil then
				self.input = result
			end
		end

		self.pos = self.pos + 1
		self:sync()
	end

	-- past end: push to output
	local output = rawget(self, "output") or (self.line and self.line.output)
	if output then
		output:push(self.input)
	end

	return self.input
end

--- Advance to next segment and continue execution
---@param element? any Optional new input (for fan-out push)
function Run:next(element)
	if element ~= nil then
		self.input = element
	end
	self.pos = self.pos + 1
	if self.pos <= #self.pipe then
		self:execute()
	else
		local output = rawget(self, "output") or (self.line and self.line.output)
		if output then
			output:push(self.input)
		end
	end
end

--- Emit a new element by cloning this run and advancing it.
--- Convenience for fan-out with optional strategy.
---@param element any Element to emit downstream
---@param strategy? 'self'|'clone'|'fork' Continuation strategy (default: clone)
---@return table run The emitted child run
function Run:emit(element, strategy)
	local child = util.continuation_for_strategy(self, strategy or "clone", element, "emit")
	child:next()
	return child
end

--- Set a fact on this run, lazily creating the local fact table
--- Reads still fall through to line.fact via metatable
---@param name string Fact name
---@param value? any Fact value (defaults to true)
function Run:set_fact(name, value)
	if value == nil then
		value = true
	end
	local own = rawget(self, "fact")
	if not own then
		local line_fact = self.line and self.line.fact or {}
		own = setmetatable({}, { __index = line_fact })
		rawset(self, "fact", own)
	end
	own[name] = value
end

--- Take ownership of a field, breaking read-through to line
---@param field string Field name to own ("pipe", "fact", "output", ...)
function Run:own(field)
	if field == "pipe" then
		local current = rawget(self, "pipe")
		if current and current ~= self.line.pipe then
			return -- already independently owned
		end
		local source = current or self.line.pipe
		rawset(self, "pipe", source:clone())
	elseif field == "fact" then
		local snapshot = {}
		-- collect all visible fact: line.fact is the base
		local line_fact = self.line and self.line.fact or {}
		for k, v in pairs(line_fact) do
			snapshot[k] = v
		end
		-- overlay with fact visible to this run (via metatable chain)
		-- self.fact traverses __index, picking up parent run fact + line fact
		local visible = self.fact
		if visible and visible ~= line_fact then
			for k, v in pairs(visible) do
				snapshot[k] = v
			end
		end
		rawset(self, "fact", snapshot) -- no more __index
	else
		local current = rawget(self, field)
		if current ~= nil then
			return -- already owned
		end
		local value = self[field] -- reads through metatable
		if value ~= nil then
			rawset(self, field, value)
		end
	end
end

--- Clone this run for fan-out. Maximally lightweight.
--- Shares pipe, fact, line, registry, output with parent.
---@param new_input any The new element for the clone
---@return table run New run context
function Run:clone(new_input)
	local parent_run = self
	local child = {
		type = "run",
		line = self.line,
		input = new_input,
		pos = self.pos,
	}
	setmetatable(child, {
		__index = function(_, k)
			-- Run methods first
			local method = Run[k]
			if method ~= nil then
				return method
			end
			-- parent run's owned field (fact, pipe, etc)
			local from_parent = rawget(parent_run, k)
			if from_parent ~= nil then
				return from_parent
			end
			-- fall through to line
			return parent_run.line[k]
		end,
	})
	return child
end

--- Fork: clone + own everything. Fully independent run.
---@param new_input? any The element for the fork (defaults to self.input)
---@return table run Independent run context
function Run:fork(new_input)
	local forked = self:clone(new_input or self.input)
	forked:own("pipe")
	forked:own("fact")
	return forked
end

--- Create a new Run for a line
---@param line table The line to run
---@param config? table Config (noStart, input, etc)
---@return table run The Run instance
function Run.new(line, config)
	config = config or {}

	local run = {
		type = "run",
		line = line,
		pipe = line.pipe,
		pos = 1,
		input = config.input,
		_rev = line.pipe.rev,
	}

	for k, v in pairs(config) do
		if k ~= "noStart" and k ~= "input" then
			run[k] = v
		end
	end

	setmetatable(run, { __index = function(_, k)
		local method = Run[k]
		if method ~= nil then
			return method
		end
		return line[k]
	end })

	if not config.noStart then
		run:execute()
	end

	return run
end

setmetatable(Run, {
	__call = function(_, line, config)
		return Run.new(line, config)
	end,
})

return Run
