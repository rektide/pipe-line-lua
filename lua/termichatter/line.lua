--- Line: pipeline definition and execution entry point
--- Holds a pipe, registry, output, config. Methods on shared prototype.
local inherit = require("termichatter.inherit")
local Pipe = require("termichatter.pipe")
local coop = require("coop")
local cooputil = require("termichatter.coop")
local segment = require("termichatter.segment")
local logutil = require("termichatter.log")
local done = require("termichatter.done")
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

local function next_segment_id(line)
	line._segment_id_counter = (line._segment_id_counter or 0) + 1
	return string.format("seg-%08x-%04x", math.floor(vim.uv.hrtime() % 0xffffffff), line._segment_id_counter)
end

local function ensure_segment_identity(line, seg, fallback_type)
	if type(seg) ~= "table" then
		return seg
	end

	if rawget(seg, "type") == nil and fallback_type ~= nil then
		seg.type = fallback_type
	elseif rawget(seg, "type") == nil then
		seg.type = "segment"
	end
	if line.auto_id ~= false and rawget(seg, "id") == nil then
		seg.id = next_segment_id(line)
	end

	return seg
end

local function instantiate_segment(line, prototype, fallback_type)
	if type(prototype) ~= "table" then
		return prototype
	end

	local instance
	if line.auto_fork ~= false and type(prototype.fork) == "function" then
		instance = prototype:fork({ line = line, type = fallback_type })
	end

	if (type(instance) ~= "table" or instance == prototype) and line.auto_instance ~= false then
		instance = setmetatable({}, { __index = prototype })
	end

	if type(instance) ~= "table" then
		return prototype
	end

	instance._termichatter_line = line
	instance._termichatter_is_instance = true

	return ensure_segment_identity(line, instance, fallback_type)
end

local function resolve_pipe_segment(line, pos, materialize_factory)
	local seg = line.pipe[pos]
	if type(seg) ~= "string" then
		if type(seg) == "table" and rawget(seg, "_termichatter_line") ~= line then
			seg = instantiate_segment(line, seg, seg.type)
			line.pipe[pos] = seg
		end
		return ensure_segment_identity(line, seg)
	end

	local segment_name = seg
	local resolved = line:resolve_segment(seg)
	if util.is_segment_factory(resolved) then
		if materialize_factory then
			seg = resolved.create()
			seg = ensure_segment_identity(line, seg, segment_name)
			line.pipe[pos] = seg
			return seg
		end
		return resolved
	end

	if resolved ~= nil then
		if type(resolved) == "table" then
			if line.auto_fork == false and line.auto_instance == false then
				return resolved
			end
			line._segment_instances = line._segment_instances or {}
			line._segment_instance_sources = line._segment_instance_sources or {}
			seg = line._segment_instances[pos]
			if seg == nil or line._segment_instance_sources[pos] ~= resolved then
				seg = instantiate_segment(line, resolved, segment_name)
				line._segment_instances[pos] = seg
				line._segment_instance_sources[pos] = resolved
			end
			return seg
		end
		return resolved
	end

	return seg
end

local function call_segment_init(line, pos)
	line._segment_init_done = line._segment_init_done or {}
	if line._segment_init_done[pos] then
		return
	end

	local seg = resolve_pipe_segment(line, pos, true)
	if type(seg) ~= "table" or type(seg.init) ~= "function" then
		return
	end

	local awaited = seg:init({
		line = line,
		pos = pos,
		segment = seg,
	})
	if awaited ~= nil and rawget(seg, "stopped") == nil then
		seg.stopped = awaited
	end
	line._segment_init_done[pos] = true
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

--- Select segments from this line by type or predicate.
---@param selector? string|function Segment type name or predicate
---@param opts? table { materialize?: boolean }
---@return table[] segments Selected segment instances
function Line:select_segments(selector, opts)
	opts = opts or {}
	local materialize = opts.materialize ~= false
	local selected = {}

	for pos = 1, #self.pipe do
		local seg = resolve_pipe_segment(self, pos, materialize)
		if type(seg) == "table" then
			local include = false
			if selector == nil then
				include = true
			elseif type(selector) == "string" then
				include = seg.type == selector
			elseif type(selector) == "function" then
				include = selector(seg, { line = self, pos = pos }) == true
			end

			if include then
				table.insert(selected, seg)
			end
		end
	end

	return selected
end

--- Ensure segments are prepared for execution.
--- Calls ensure_prepared(context) on each segment that exposes it.
--- This is safe to call repeatedly; segment hooks should be idempotent.
---@return table[] tasks Awaitables collected from segment hooks
function Line:ensure_prepared()
	local tasks = {}
	for pos = 1, #self.pipe do
		local seg = resolve_pipe_segment(self, pos, true)

		if type(seg) == "table" and type(seg.ensure_prepared) == "function" then
			local awaited = seg:ensure_prepared({
				line = self,
				pos = pos,
				segment = seg,
				force = true,
			})
			cooputil.collect_awaitables(awaited, tasks)
		end
	end

	cooputil.await_all(tasks)
	return tasks
end

--- TODO: remove this temporary alias after callsites migrate.
---@return table[] tasks Awaitables collected from segment hooks
function Line:prepare_segments()
	return self:ensure_prepared()
end

local function stop_prepared_segments(line)
	local tasks = {}
	for pos = 1, #line.pipe do
		local seg = resolve_pipe_segment(line, pos, false)
		if type(seg) == "table" then
			cooputil.collect_awaitables(seg.stopped, tasks)
		end

		if type(seg) == "table" and type(seg.ensure_stopped) == "function" then
			local awaited = seg:ensure_stopped({
				line = line,
				pos = pos,
				segment = seg,
				force = true,
			})
			cooputil.collect_awaitables(awaited, tasks)
		end
	end

	return tasks
end

--- Return a deferred that settles when matching segment.stopped awaitables
--- (including new ones discovered in later selector passes) resolve.
---@param selector? string|function Segment type or predicate
---@return table stopped_live Deferred with await()
function Line:stopped_live(selector)
	local stopped_live = done.create_deferred()
	local seen = {}
	local pending = 0
	local pump_scheduled = false

	local function line_is_stopped()
		return type(self.stopped) == "table"
			and type(self.stopped.is_resolved) == "function"
			and self.stopped:is_resolved()
	end

	local function maybe_resolve()
		if stopped_live:is_resolved() then
			return
		end
		if line_is_stopped() and pending == 0 then
			stopped_live:resolve({ stopped = true, source = self:full_source() })
		end
	end

	local function on_settled()
		pending = pending - 1
		if pending < 0 then
			pending = 0
		end
		maybe_resolve()
	end

	local function track_awaitable(awaited)
		if seen[awaited] then
			return
		end
		seen[awaited] = true

		if type(awaited.is_resolved) == "function" and awaited:is_resolved() then
			return
		end

		pending = pending + 1
		if type(awaited.on_resolve) == "function" then
			awaited:on_resolve(on_settled)
			return
		end

		coop.spawn(function()
			cooputil.await_all({ awaited })
			on_settled()
		end)
	end

	local function pump()
		pump_scheduled = false
		if stopped_live:is_resolved() then
			return
		end

		local selected = self:select_segments(selector)
		for _, seg in ipairs(selected) do
			local collected = cooputil.collect_awaitables(seg.stopped)
			for _, awaited in ipairs(collected) do
				track_awaitable(awaited)
			end
		end

		maybe_resolve()
		if not stopped_live:is_resolved() and not line_is_stopped() and not pump_scheduled then
			pump_scheduled = true
			vim.defer_fn(pump, 25)
		end
	end

	if type(self.stopped) == "table" and type(self.stopped.on_resolve) == "function" then
		self.stopped:on_resolve(function()
			pump()
		end)
	end

	pump_scheduled = true
	vim.defer_fn(pump, 0)
	return stopped_live
end

--- Ensure segments are stopped and resolve line.stopped when done.
---@return table stopped Deferred stop handle with await()
function Line:ensure_stopped()
	if type(self.stopped) ~= "table" or type(self.stopped.resolve) ~= "function" then
		self.stopped = done.create_deferred()
	end

	if self.stopped:is_resolved() then
		return self.stopped
	end

	local tasks = stop_prepared_segments(self)
	cooputil.await_all(tasks)
	self.stopped:resolve({ stopped = true, source = self:full_source() })
	return self.stopped
end

--- Close this line and return the stopped deferred.
--- Ensures prepared state, then runs ensure_stopped lifecycle.
---@return table stopped Deferred stop handle with await()
function Line:close()
	self:ensure_prepared()
	return self:ensure_stopped()
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
	-- TODO: when deleting segments, run ensure_stopped for removed segments before
	-- dropping references. add tests covering removal teardown behavior.
	self.pipe:splice(pos, delete_count, ...)
	self._segment_instances = nil
	self._segment_instance_sources = nil
	self._segment_init_done = nil
	local inserted_count = select("#", ...)
	for offset = 0, inserted_count - 1 do
		call_segment_init(self, pos + offset)
	end
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
	self:spliceSegment(pos, 0, handoff)
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

	if config.stopped ~= nil then
		instance.stopped = config.stopped
	else
		instance.stopped = done.create_deferred()
	end

	if config.auto_completion_done_on_close ~= nil then
		instance.auto_completion_done_on_close = config.auto_completion_done_on_close
	elseif not parent then
		instance.auto_completion_done_on_close = true
	end

	if config.auto_id ~= nil then
		instance.auto_id = config.auto_id
	elseif not parent then
		instance.auto_id = true
	end

	if config.auto_fork ~= nil then
		instance.auto_fork = config.auto_fork
	elseif not parent then
		instance.auto_fork = true
	end

	if config.auto_instance ~= nil then
		instance.auto_instance = config.auto_instance
	elseif not parent then
		instance.auto_instance = true
	end

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

	for k, v in pairs(config) do
		if k ~= "parent"
			and k ~= "pipe"
			and k ~= "output"
			and k ~= "fact"
			and k ~= "sourcer"
			and k ~= "stopped"
			and k ~= "auto_completion_done_on_close"
			and k ~= "auto_id"
			and k ~= "auto_fork"
			and k ~= "auto_instance" then
			instance[k] = v
		end
	end

	setmetatable(instance, LINE_MT)
	if instance.pipe then
		for pos = 1, #instance.pipe do
			call_segment_init(instance, pos)
		end
	end
	return instance
end

setmetatable(Line, {
	__call = function(_, config)
		return new_line(config)
	end,
})

return Line
