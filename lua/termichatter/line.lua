--- Line: pipeline definition and execution entry point
--- Holds a pipe, registry, output, config. Methods on shared prototype.
local inherit = require("termichatter.inherit")
local Pipe = require("termichatter.pipe")
local consumer = require("termichatter.consumer")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

local Line = {}

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

--- Create mpsc queue for a segment at given position
---@param pos number Position in pipe array
---@return table queue The MpscQueue instance
function Line:ensure_mpsc(pos)
	if not rawget(self, "mpsc") then
		rawset(self, "mpsc", {})
	end
	if not self.mpsc[pos] then
		self.mpsc[pos] = MpscQueue.new()
	end
	return self.mpsc[pos]
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

	local self_ref = self
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

	setmetatable(logger, {
		__index = function(_, k)
			return self_ref[k]
		end,
		__call = function(t, msg)
			return t:log(msg)
		end,
	})

	for name, level in pairs(Line.priority) do
		if name ~= "log" then
			logger[name] = function(loggerSelf, msg)
				if type(msg) == "string" then
					msg = { message = msg }
				end
				msg = msg or {}
				msg.priority = name
				msg.priorityLevel = level
				return loggerSelf:log(msg)
			end
		end
	end

	return logger
end

--- v1 compat: :new(...) creates a child line
---@vararg table Config tables to merge
---@return table line New child Line
function Line:new(...)
	local configs = { ... }
	local merged = {}
	for _, cfg in ipairs(configs) do
		if type(cfg) == "table" then
			for k, v in pairs(cfg) do
				merged[k] = v
			end
		end
	end
	return self:derive(merged)
end

--- Add a processor segment to the pipeline
---@param name string Segment name
---@param handler function|table The segment handler
---@param pos? number Position to insert (default: end)
---@param withQueue? boolean Add mpsc queue at position
function Line:addProcessor(name, handler, pos, withQueue)
	rawset(self, name, handler)
	pos = pos or (#self.pipe + 1)
	self.pipe:splice(pos, 0, name)
	if withQueue then
		self:ensure_mpsc(pos)
	end
end

--- Start async consumer for all mpsc stage
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
		mpsc = {},
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
	instance.outputQueue = instance.output

	-- apply remaining config
	for k, v in pairs(config) do
		instance[k] = v
	end

	-- registry: inherit from parent or use default
	if not instance.registry and parent then
		-- will fall through via __index
	end

	-- priority method on the instance
	for name, level in pairs(Line.priority) do
		if name ~= "log" then
			instance[name] = function(self, msg)
				if type(msg) == "string" then
					msg = { message = msg }
				end
				msg = msg or {}
				msg.priority = name
				msg.priorityLevel = level
				return self:log(msg)
			end
		end
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
