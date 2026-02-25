--- Line: pipeline definition and execution entry point
--- Holds a pipe, registry, output, config. Methods on shared prototype.
local inherit = require("termichatter.inherit")
local Pipe = require("termichatter.pipe")
local consumer = require("termichatter.consumer")
local segment = require("termichatter.segment")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

local Line = {}
local Logger = {}
local LOGGER_MT = {}

Line.priority = {
	error = 1,
	warn = 2,
	info = 3,
	log = 4,
	debug = 5,
	trace = 6,
}

Line.defaultSegment = {
	"timestamper",
	"ingester",
	"cloudevent",
	"module_filter",
}

local function with_priority(msg, name, level)
	if type(msg) == "string" then
		msg = { message = msg }
	end
	msg = msg or {}
	msg.priority = name
	msg.priorityLevel = level
	return msg
end

for name, level in pairs(Line.priority) do
	if name ~= "log" then
		Line[name] = function(self, msg)
			return self:log(with_priority(msg, name, level))
		end
		Logger[name] = Line[name]
	end
end

function Logger:log(msg)
	return Line.log(self, msg)
end

LOGGER_MT.__index = function(self, k)
	local method = Logger[k]
	if method ~= nil then
		return method
	end
	return self.line[k]
end

LOGGER_MT.__call = function(t, msg)
	return t:log(msg)
end

--- Send a message through the pipeline
---@param msg string|table Message to log
---@return table run The run that executed
function Line:log(msg)
	if type(msg) == "string" then
		msg = { message = msg }
	end
	msg = msg or {}
	msg.source = msg.source or self.source
	return self:run({ input = msg })
end

--- Create a Run from this line
---@param config? table Config to pass to Run
---@return table run The Run instance
function Line:run(config)
	local Run = require("termichatter.run")
	if self.autoStartConsumers ~= false then
		consumer.start_consumer(self)
	end
	return Run(self, config)
end

--- Create a child line inheriting from this one
---@param config? table Config for the child
---@return table line New Line instance
function Line:derive(config)
	config = config or {}
	config.parent = self
	return Line(config)
end

--- Clone the pipe array for independent modification
---@param segment_list? string[] Optional new segment list
---@return table pipe New pipe object
function Line:clone_pipe(segment_list)
	if segment_list then
		return Pipe(segment_list)
	end
	return self.pipe:clone()
end

--- Resolve a segment name from the registry chain
---@param name string|function|table Segment identifier
---@return function|table|nil segment Resolved segment
function Line:resolve_segment(name)
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

	return nil
end

--- Create a logger with priority method
---@param config? table Logger config { module?: string, ... }
---@return table logger Logger with priority method
function Line:baseLogger(config)
	config = config or {}
	local logger = {
		type = "logger",
		line = self,
	}

	for k, v in pairs(config) do
		logger[k] = v
	end

	if config.module and self.source then
		logger.source = self.source .. ":" .. config.module
	end

	setmetatable(logger, LOGGER_MT)

	return logger
end

--- Splice segment entries into the pipeline
---@param pos number Position to splice at
---@param delete_count number Number of entries to delete
---@param ... any Segment entries to insert
---@return table pipe The updated pipe
function Line:spliceSegment(pos, delete_count, ...)
	self.pipe:splice(pos, delete_count, ...)
	return self.pipe
end

--- Add a segment to the pipeline
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

--- Add an explicit async queue boundary segment
---@param pos? number Position to insert boundary (default: end)
---@param config? table { queue?: table, strategy?: 'self'|'clone'|'fork' }
---@return table handoff The inserted mpsc_handoff segment
function Line:addHandoff(pos, config)
	local handoff = segment.mpsc_handoff(config)
	pos = pos or (#self.pipe + 1)
	self.pipe:splice(pos, 0, handoff)
	return handoff
end

--- Start async consumer for all mpsc_handoff segments
---@return table[] task Array of spawned task
function Line:startConsumer()
	return consumer.start_consumer(self)
end

--- Stop all async consumer
function Line:stopConsumer()
	consumer.stop_consumer(self)
end

--- Construct a new Line
---@param config? table Configuration
---@return table line New Line instance
local function new_line(config)
	config = config or {}
	local parent = config.parent
	config.parent = nil

	local instance = {
		type = "line",
		fact = {},
	}

	-- pipe: from config, or clone parent's, or default
	if config.pipe then
		if type(config.pipe) == "table" and config.pipe.splice then
			instance.pipe = config.pipe
		else
			instance.pipe = Pipe(config.pipe)
		end
		config.pipe = nil
	elseif parent and parent.pipe then
		instance.pipe = parent.pipe:clone()
	else
		instance.pipe = Pipe(Line.defaultSegment)
	end

	-- output queue
	if config.output then
		instance.output = config.output
		config.output = nil
	else
		instance.output = MpscQueue.new()
	end
	-- apply remaining config
	for k, v in pairs(config) do
		instance[k] = v
	end

	-- registry: inherit from parent or use default
	if not instance.registry and parent then
		-- will fall through via __index
	end

	-- set up metatable: methods from Line, data from parent
	setmetatable(instance, { __index = function(_, k)
		local method = Line[k]
		if method ~= nil then return method end
		if parent then return parent[k] end
		return nil
	end })

	return instance
end

setmetatable(Line, {
	__call = function(_, config)
		return new_line(config)
	end,
})

return Line
