--- Line: pipeline definition and execution entry point
--- Holds a pipe, registry, output, config. Methods on shared prototype.
local inherit = require("termichatter.inherit")
local Pipe = require("termichatter.pipe")
local segment = require("termichatter.segment")
local logutil = require("termichatter.log")
local done = require("termichatter.done")
local protocol = require("termichatter.protocol")
local util = require("termichatter.util")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

local Line = {}
local LINE_MT = {}

Line.level = logutil.level

Line.defaultSegment = {
	"timestamper",
	"ingester",
	"cloudevent",
	"module_filter",
	"completion",
}

local function shallow_copy(input)
	local out = {}
	for k, v in pairs(input or {}) do
		out[k] = v
	end
	return out
end

function LINE_MT.__index(self, key)
	local method = Line[key]
	if method ~= nil then
		return method
	end

	local parent = rawget(self, "parent")
	if parent then
		return parent[key]
	end

	return nil
end

--- Send a message through the pipeline.
---@param message? string|table Optional message string or attrs table
---@param attrs? table Optional attrs merged into payload
---@return table run The run that executed
function Line:log(message, attrs)
	local payload = logutil.normalize(self, message, attrs)
	return self:run({ input = payload })
end

--- Log at error level.
---@param message? string|table Optional message string or attrs table
---@param attrs? table Optional attrs merged into payload
---@return table run The run that executed
function Line:error(message, attrs)
	local payload = logutil.normalize(self, message, attrs, "error")
	return self:run({ input = payload })
end

--- Log at warn level.
---@param message? string|table Optional message string or attrs table
---@param attrs? table Optional attrs merged into payload
---@return table run The run that executed
function Line:warn(message, attrs)
	local payload = logutil.normalize(self, message, attrs, "warn")
	return self:run({ input = payload })
end

--- Log at info level.
---@param message? string|table Optional message string or attrs table
---@param attrs? table Optional attrs merged into payload
---@return table run The run that executed
function Line:info(message, attrs)
	local payload = logutil.normalize(self, message, attrs, "info")
	return self:run({ input = payload })
end

--- Log at debug level.
---@param message? string|table Optional message string or attrs table
---@param attrs? table Optional attrs merged into payload
---@return table run The run that executed
function Line:debug(message, attrs)
	local payload = logutil.normalize(self, message, attrs, "debug")
	return self:run({ input = payload })
end

--- Log at trace level.
---@param message? string|table Optional message string or attrs table
---@param attrs? table Optional attrs merged into payload
---@return table run The run that executed
function Line:trace(message, attrs)
	local payload = logutil.normalize(self, message, attrs, "trace")
	return self:run({ input = payload })
end

--- Compute the full source path for this line by walking parent chain.
---@return string|nil source
function Line:full_source()
	return logutil.full_source(self)
end

--- Create a Run from this line
---@param config? table Config to pass to Run
---@return table run The Run instance
function Line:run(config)
	local Run = require("termichatter.run")
	return Run(self, config)
end

--- Prepare segments for execution.
--- Calls ensure_prepared(context) on each segment that exposes it.
--- This is safe to call repeatedly; segment hooks should be idempotent.
---@return table line
function Line:prepare_segments()
	for pos = 1, #self.pipe do
		local seg = self.pipe[pos]
		if type(seg) == "string" then
			local resolved = self:resolve_segment(seg)
			if util.is_segment_factory(resolved) then
				seg = resolved.create()
				self.pipe[pos] = seg
			elseif resolved ~= nil then
				seg = resolved
			end
		end

		if type(seg) == "table" and type(seg.ensure_prepared) == "function" then
			seg:ensure_prepared({
				line = self,
				pos = pos,
				segment = seg,
				force = true,
			})
		end
	end

	return self
end

local function stop_prepared_segments(line)
	for pos = 1, #line.pipe do
		local seg = line.pipe[pos]
		if type(seg) == "string" then
			local resolved = line:resolve_segment(seg)
			if resolved ~= nil and not util.is_segment_factory(resolved) then
				seg = resolved
			end
		end

		if type(seg) == "table" and type(seg.ensure_stopped) == "function" then
			seg:ensure_stopped({
				line = line,
				pos = pos,
				segment = seg,
				force = true,
			})
		end
	end
end

local function has_completion_segment(line)
	for pos = 1, #line.pipe do
		local seg = line.pipe[pos]
		if type(seg) == "string" then
			local resolved = line:resolve_segment(seg)
			if resolved ~= nil and not util.is_segment_factory(resolved) then
				seg = resolved
			end
		end

		if type(seg) == "table" and seg.type == "completion" then
			return true
		end
	end

	return false
end

--- Close this line and return the completion deferred.
--- Sends a completion done protocol run through the pipeline.
---@return table done Deferred completion handle with await()
function Line:close()
	self:prepare_segments()

	if type(self.done) ~= "table" or type(self.done.resolve) ~= "function" then
		self.done = done.create_deferred()
	end

	if not self._close_hooked then
		self._close_hooked = true
		self.done:on_resolve(function()
			stop_prepared_segments(self)
		end)
	end

	local already_resolved = type(self.done.is_resolved) == "function" and self.done:is_resolved()
	if not self._close_sent and not already_resolved then
		self._close_sent = true
		local has_completion = has_completion_segment(self)
		if has_completion then
			self:run(protocol.completion.completion_run(protocol.completion.COMPLETION_DONE, self:full_source()))
		else
			local state = self.completion_state or protocol.completion.create_completion_state()
			self.completion_state = state
			state.done = math.max(state.done + 1, state.hello)
			state.settled = true
			state.signal = protocol.completion.COMPLETION_DONE
			state.name = self:full_source()
			self.done:resolve(state)
		end
	end

	return self.done
end

--- Create a thin child line inheriting from this one.
--- Child keeps its own local source and reads all other fields through parent.
---@param source_or_config? string|table Child source segment or config table
---@param config? table Additional child config
---@return table line New child line
function Line:child(source_or_config, config)
	local child_config = {}

	if type(source_or_config) == "table" then
		child_config = shallow_copy(source_or_config)
	else
		child_config = shallow_copy(config)
		if source_or_config ~= nil then
			child_config.source = source_or_config
		end
	end

	child_config.parent = self
	return Line(child_config)
end

--- Create an independent forked line.
--- Fork owns its own pipe/output/fact while inheriting other fields through parent.
---@param source_or_config? string|table Fork source segment or config table
---@param config? table Additional fork config
---@return table line New independent line
function Line:fork(source_or_config, config)
	local forked = self:child(source_or_config, config)

	if rawget(forked, "pipe") == nil then
		forked.pipe = self:clone_pipe()
	end
	if rawget(forked, "output") == nil then
		forked.output = MpscQueue.new()
	end
	if rawget(forked, "fact") == nil then
		forked.fact = shallow_copy(self.fact)
	end

	return forked
end

--- Clone the pipe array for independent modification.
---@param segment_list? string[] Optional new segment list
---@return table pipe New pipe object
function Line:clone_pipe(segment_list)
	if segment_list then
		return Pipe(segment_list)
	end
	return self.pipe:clone()
end

--- Resolve a segment name from the registry chain.
---@param name string|function|table Segment identifier
---@return function|table|nil segment Resolved segment
function Line:resolve_segment(name)
	if type(name) == "function" or type(name) == "table" then
		return name
	end
	if type(name) ~= "string" then
		return nil
	end

	local scoped = inherit.walk_field(self, name)
	if scoped ~= nil then
		return scoped
	end

	local registry = inherit.walk_field(self, "registry")
	if registry and registry.resolve then
		return registry:resolve(name)
	end

	return nil
end

--- Splice segment entries into the pipeline.
---@param pos number Position to splice at
---@param delete_count number Number of entries to delete
---@param ... any Segment entries to insert
---@return table pipe The updated pipe
function Line:spliceSegment(pos, delete_count, ...)
	self.pipe:splice(pos, delete_count, ...)
	return self.pipe
end

--- Add a segment to the pipeline.
--- Common forms:
---   addSegment("name", handler, pos?) -- define on line and insert by name
---   addSegment(segmentRef, pos?)       -- insert string/function/table segment ref
---@param segment any Segment reference or segment name
---@param handler_or_pos? any Handler table/function or insertion position
---@param pos? number Position to insert (default: end)
---@return any inserted The inserted segment reference
function Line:addSegment(segment, handler_or_pos, pos)
	local inserted = segment
	local insert_pos

	if type(segment) == "string"
		and (type(handler_or_pos) == "function" or type(handler_or_pos) == "table")
		and pos == nil then
		rawset(self, segment, handler_or_pos)
		insert_pos = #self.pipe + 1
	elseif type(segment) == "string"
		and (type(handler_or_pos) == "function" or type(handler_or_pos) == "table")
		and type(pos) == "number" then
		rawset(self, segment, handler_or_pos)
		insert_pos = pos
	else
		insert_pos = handler_or_pos
	end

	insert_pos = insert_pos or (#self.pipe + 1)
	self:spliceSegment(insert_pos, 0, inserted)
	return inserted
end

--- Add an explicit async queue boundary segment.
---@param pos? number Position to insert boundary (default: end)
---@param config? table { queue?: table, strategy?: 'self'|'clone'|'fork' }
---@return table handoff The inserted mpsc_handoff segment
function Line:addHandoff(pos, config)
	local handoff = segment.mpsc_handoff(config)
	pos = pos or (#self.pipe + 1)
	self.pipe:splice(pos, 0, handoff)
	return handoff
end

--- Construct a new Line.
---@param config? table Configuration
---@return table line New Line instance
local function new_line(config)
	config = config or {}
	local parent = config.parent

	local instance = {
		type = "line",
	}

	if parent then
		instance.parent = parent
	end

	if config.pipe ~= nil then
		if type(config.pipe) == "table" and config.pipe.splice then
			instance.pipe = config.pipe
		else
			instance.pipe = Pipe(config.pipe)
		end
	elseif not parent then
		instance.pipe = Pipe(Line.defaultSegment)
	end

	if config.output ~= nil then
		instance.output = config.output
	elseif not parent then
		instance.output = MpscQueue.new()
	end

	if config.fact ~= nil then
		instance.fact = config.fact
	elseif not parent then
		instance.fact = {}
	end

	if config.sourcer ~= nil then
		instance.sourcer = config.sourcer
	elseif not parent then
		instance.sourcer = logutil.full_source
	end

	if config.done ~= nil then
		instance.done = config.done
	else
		instance.done = done.create_deferred()
	end

	for k, v in pairs(config) do
		if k ~= "parent" and k ~= "pipe" and k ~= "output" and k ~= "fact" and k ~= "sourcer" and k ~= "done" then
			instance[k] = v
		end
	end

	setmetatable(instance, LINE_MT)
	return instance
end

setmetatable(Line, {
	__call = function(_, config)
		return new_line(config)
	end,
})

return Line
