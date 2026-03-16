--- Run: a lightweight cursor/context that walk a line's pipe
--- Methods live on the prototype, not copied per-instance
--- Supports clone/fork/own for fan-out and independence
local async = require("pipe-line.async")
local errors = require("pipe-line.errors")
local util = require("pipe-line.util")

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
		local seg
		if self.line and type(self.line.resolve_pipe_segment) == "function" then
			seg = self.line:resolve_pipe_segment(self.pos, true)
		else
			seg = self.pipe[self.pos]
		end

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
			elseif resolved ~= nil then
				seg = resolved
			end
		end

		if type(seg) == "table" and type(seg.ensure_prepared) == "function" then
			seg:ensure_prepared({
				line = self.line,
				run = self,
				pos = self.pos,
				segment = seg,
			})
		end

		local control = nil
		if self.line and type(self.line.resolve_segment_control) == "function" then
			control = self.line:resolve_segment_control(self.pos, seg)
		end
		if type(control) == "table" and type(control.ensure_prepared) == "function" then
			control:ensure_prepared({
				line = self.line,
				run = self,
				pos = self.pos,
				segment = seg,
				control = control,
				force = false,
			})
		end

		local admitted_marker = rawget(self, "_pipe_line_admitted")
		local already_admitted = type(admitted_marker) == "table"
			and admitted_marker.control == control
			and admitted_marker.pos == self.pos

		if type(control) == "table" and not already_admitted and type(control.admit_or_queue) == "function" then
			local admitted = control:admit_or_queue(self)
			if admitted ~= true then
				self.segment = nil
				return nil
			end
		end

		local handle_started = nil
		if type(control) == "table" and type(control.timing_start) == "function" then
			handle_started = control:timing_start("handle")
		end

		local handler = self:resolve(seg)
		if handler then
			self.segment = seg
			local ok, result = pcall(handler, self)
			if not ok then
				if type(control) == "table" then
					if type(control.timing_end) == "function" then
						control:timing_end("handle", handle_started)
					end
					if type(control.release_run) == "function" then
						control:release_run(self, {
							status = "error",
							error = {
								code = "segment_handler_error",
								message = tostring(result),
							},
						})
					end
				end
				self.segment = nil
				error(result, 0)
			end
			if result == false then
				if type(control) == "table" then
					if type(control.timing_end) == "function" then
						control:timing_end("handle", handle_started)
					end
					if type(control.release_run) == "function" then
						control:release_run(self, {
							status = "error",
							error = {
								code = "segment_filtered",
								message = "segment returned false",
							},
						})
					end
				end
				self.segment = nil
				return nil
			end

			local op = async.normalize(result)
			if op ~= nil then
				if type(control) == "table" and type(control.timing_end) == "function" then
					control:timing_end("handle", handle_started)
				end
				self.segment = nil
				self:_begin_async(seg, op, control)
				return nil
			end

			if result ~= nil then
				self.input = result
			end
			if type(control) == "table" then
				if type(control.timing_end) == "function" then
					control:timing_end("handle", handle_started)
				end
				if type(control.release_run) == "function" then
					control:release_run(self, {
						status = "ok",
						value = self.input,
					})
				end
			end
			self.segment = nil
		else
			if type(control) == "table" then
				if type(control.timing_end) == "function" then
					control:timing_end("handle", handle_started)
				end
				if type(control.release_run) == "function" then
					control:release_run(self, {
						status = "ok",
						value = self.input,
					})
				end
			end
		end

		self.pos = self.pos + 1
		self:sync()
	end

	-- past end: push to output
	local output = rawget(self, "output") or (self.line and self.line.output)
	if output and self.input ~= nil then
		output:push(self.input)
	end

	return self.input
end

---@param key string
---@param fallback? any
---@return any
function Run:cfg(key, fallback)
	local seg = rawget(self, "segment")
	if seg == nil then
		local async_state = rawget(self, "_async")
		if type(async_state) == "table" then
			seg = async_state.segment
		end
	end

	if type(seg) == "table" then
		local seg_val = seg[key]
		if seg_val ~= nil then
			return seg_val
		end
	end

	if self.line ~= nil then
		local line_val = rawget(self.line, key)
		if line_val ~= nil then
			return line_val
		end
	end

	return fallback
end

---@param cb function
function Run:on_settle(cb)
	if type(cb) ~= "function" then
		error("on_settle requires a callback", 0)
	end

	local async_state = rawget(self, "_async")
	if type(async_state) ~= "table" then
		error("on_settle called without async state", 0)
	end

	table.insert(async_state.settle_cbs, cb)
end

---@return any
function Run:dispatch()
	local async_state = rawget(self, "_async")
	if type(async_state) ~= "table" then
		error("dispatch called without async state", 0)
	end

	async_state.aspect_index = async_state.aspect_index + 1
	local aspect = async_state.aspects[async_state.aspect_index]
	if type(aspect) ~= "table" or type(aspect.handle) ~= "function" then
		return self:settle({
			status = "error",
			error = {
				code = "async_no_aspect",
				message = "async dispatch reached end of aspect chain",
			},
		})
	end

	local dispatch_started = nil
	if type(async_state.control) == "table" and type(async_state.control.timing_start) == "function" then
		dispatch_started = async_state.control:timing_start("dispatch")
	end

	local ok, result = pcall(function()
		return aspect:handle(self)
	end)
	if type(async_state.control) == "table" and type(async_state.control.timing_end) == "function" then
		async_state.control:timing_end("dispatch", dispatch_started)
	end
	if not ok then
		return self:settle({
			status = "error",
			error = {
				code = "async_aspect_error",
				message = tostring(result),
				aspect = aspect.type,
			},
		})
	end

	return result
end

---@param outcome table
---@return table|nil continuation
function Run:settle(outcome)
	local async_state = rawget(self, "_async")
	if type(async_state) ~= "table" then
		return nil
	end

	if async_state.settled then
		return async_state.continuation
	end
	async_state.settled = true

	if type(outcome) ~= "table" then
		outcome = { status = "ok", value = outcome }
	end

	local continuation = async_state.continuation
	if outcome.status == "ok" then
		if outcome.value ~= nil then
			continuation.input = outcome.value
		end
	else
		local err = outcome.error
		if type(err) ~= "table" then
			err = {
				code = "async_settle_error",
				message = tostring(err),
			}
		end

		err.stage = err.stage or "async"
		if type(async_state.segment) == "table" then
			err.segment_type = async_state.segment.type
			err.segment_id = async_state.segment.id
		end

		continuation.input = errors.add(continuation.input, err)
	end

	for _, cb in ipairs(async_state.settle_cbs) do
		local ok, cb_err = pcall(cb, outcome, self, async_state)
		if not ok then
			continuation.input = errors.add(continuation.input, {
				stage = "async_settle_callback",
				code = "async_settle_callback_error",
				message = tostring(cb_err),
			})
		end
	end

	if type(async_state.control) == "table" and type(async_state.control.timing_end) == "function" then
		async_state.control:timing_end("settle", async_state.settle_started)
	end
	if type(async_state.control) == "table" and type(async_state.control.release_run) == "function" then
		async_state.control:release_run(self, outcome)
	end

	rawset(self, "_async", nil)
	continuation:next()
	return continuation
end

---@param seg any
---@param op table
---@param control? table
function Run:_begin_async(seg, op, control)
	local continuation = self:clone(self.input)
	continuation.pos = self.pos

	local aspects = {}
	if type(self.line) == "table" and type(self.line.resolve_segment_aspects) == "function" then
		if control == nil and type(self.line.resolve_segment_control) == "function" then
			control = self.line:resolve_segment_control(self.pos, seg)
		end
		aspects = self.line:resolve_segment_aspects(self.pos, seg)
		for _, aspect in ipairs(aspects or {}) do
			if type(aspect) == "table" and type(aspect.ensure_prepared) == "function" then
				aspect:ensure_prepared({
					line = self.line,
					pos = self.pos,
					segment = seg,
					aspect = aspect,
					control = control,
					force = false,
				})
			end
		end
	elseif type(seg) == "table" and type(seg._aspects) == "table" then
		aspects = seg._aspects
		control = seg._async_control
	end

	rawset(self, "_async", {
		segment = seg,
		control = control,
		op = op,
		continuation = continuation,
		aspects = aspects,
		aspect_index = 0,
		settled = false,
		settle_started = type(control) == "table" and type(control.timing_start) == "function"
			and control:timing_start("settle")
			or nil,
		settle_cbs = {},
	})

	if type(control) == "table" and type(control.bind_async_run) == "function" then
		control:bind_async_run(self)
	end

	self:dispatch()
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
		if output and self.input ~= nil then
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
---@param config? table Config (auto_start, input, etc)
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
		if k ~= "auto_start" and k ~= "input" and k ~= "noStart" and k ~= "no_start" then
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

	if config.auto_start ~= false then
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
