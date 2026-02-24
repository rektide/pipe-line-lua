--- termichatter: structured data-flow pipeline
--- line/pipe/segment/run/registry architecture
local M = {}

local inherit = require("termichatter.inherit")
local Pipe = require("termichatter.pipe")
local registry = require("termichatter.registry")
local line = require("termichatter.line")
local Run = require("termichatter.run")
local segment = require("termichatter.segment")
local consumer = require("termichatter.consumer")
local outputter = require("termichatter.outputter")
local driver = require("termichatter.driver")
local protocol = require("termichatter.protocol")
local resolver = require("termichatter.resolver")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

M.inherit = inherit
M.Pipe = Pipe
M.registry = registry
M.line = line
M.Run = Run
M.segment = segment
M.consumer = consumer
M.outputter = outputter
M.driver = driver
M.protocol = protocol
M.completion = protocol
M.resolver = resolver

-- Register built-in segment
registry:register("timestamper", segment.timestamper)
registry:register("cloudevent", segment.cloudevent)
registry:register("cloudevents", segment.cloudevent)
registry:register("module_filter", segment.module_filter)
registry:register("priority_filter", segment.priority_filter)
registry:register("ingester", segment.ingester)
registry:register("lattice_resolver", resolver.lattice_resolver)

M.defaultSegment = {
	"timestamper",
	"ingester",
	"cloudevent",
	"module_filter",
}

M.priority = {
	error = 1,
	warn = 2,
	info = 3,
	log = 4,
	debug = 5,
	trace = 6,
}

-- expose segment handler directly for backward compat
-- v1 calling convention: timestamper(msg) not timestamper(run)
M.timestamper = function(msg)
	if type(msg) == "table" and msg.input then
		return segment.timestamper.handler(msg)
	end
	if type(msg) == "table" then
		if not msg.time then
			msg.time = vim.uv.hrtime()
		end
	end
	return msg
end
M.cloudevents = function(msg, ctx)
	-- v1 compat: segment receives (msg, ctx), but new segment receives (run)
	-- wrap to support both calling convention
	if type(msg) == "table" and msg.type == "run" then
		return segment.cloudevent(msg)
	end
	-- old calling convention: (msg, ctx)
	local input = msg
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
	input.source = input.source or (ctx and ctx.source)
	input.type = input.type or "termichatter.log"
	return input
end

M.module_filter = function(msg, ctx)
	if type(msg) == "table" and msg.type == "run" then
		return segment.module_filter(msg)
	end
	-- old calling convention
	local filter = ctx and ctx.filter
	if not filter then
		return msg
	end
	if type(filter) == "function" then
		if filter(msg) then
			return msg
		end
		return nil
	end
	local source = type(msg) == "table" and msg.source or nil
	if type(filter) == "string" then
		if not source then return msg end
		if string.match(source, filter) then
			return msg
		end
		return nil
	end
	return msg
end

M.uuid = function()
	local random = math.random
	return string.format(
		"%08x-%04x-%04x-%04x-%012x",
		random(0, 0xffffffff),
		random(0, 0xffff),
		random(0x4000, 0x4fff),
		random(0x8000, 0xbfff),
		random(0, 0xffffffffffff)
	)
end

--- Create a new line (pipeline) with optional config
---@param config? table { pipe?: string[], source?: string, ... }
---@return table pipeline The new line with logging method
function M.makePipeline(config)
	config = config or {}

	local newLine = line:clone({
		pipe = Pipe.new(config.pipe or M.defaultSegment),
		registry = registry,
		output = MpscQueue.new(),
	})

	for k, v in pairs(config) do
		if k ~= "pipe" then
			newLine[k] = v
		end
	end

	newLine.outputQueue = newLine.output

	function newLine:log(msg)
		if type(msg) == "string" then
			msg = { message = msg }
		end
		msg = msg or {}
		msg.source = msg.source or self.source
		return self:run({ input = msg })
	end

	function newLine:baseLogger(logConfig)
		logConfig = logConfig or {}

		local logger = inherit.derive(self, {
			type = "logger",
		})

		for k, v in pairs(logConfig) do
			logger[k] = v
		end

		if logConfig.module and self.source then
			logger.source = self.source .. ":" .. logConfig.module
		end

		setmetatable(logger, {
			__index = self,
			__call = function(t, msg)
				return t:log(msg)
			end,
		})

		for name, level in pairs(M.priority) do
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

	function newLine:makePipeline(subConfig)
		local child = M.makePipeline(subConfig)
		setmetatable(child, { __index = self })
		return child
	end

	-- v1 compat: :new() delegates to makePipeline
	function newLine:new(...)
		local configs = { ... }
		local merged = {}
		for _, cfg in ipairs(configs) do
			if type(cfg) == "table" then
				for k, v in pairs(cfg) do
					merged[k] = v
				end
			end
		end
		local child = M.makePipeline(merged)
		setmetatable(child, { __index = self })
		return child
	end

	-- v1 compat: addProcessor
	function newLine:addProcessor(name, handler, pos, withQueue)
		rawset(self, name, handler)
		pos = pos or (#self.pipe + 1)
		self.pipe:splice(pos, 0, name)
		if withQueue then
			self:ensure_mpsc(pos)
		end
	end

	-- v1 compat: priority method directly on line
	-- skip "log" to avoid overwriting the pipeline :log method
	for name, level in pairs(M.priority) do
		if name == "log" then goto skip_priority end
		newLine[name] = function(self, msg)
			if type(msg) == "string" then
				msg = { message = msg }
			end
			msg = msg or {}
			msg.priority = name
			msg.priorityLevel = level
			return self:log(msg)
		end
		::skip_priority::
	end

	function newLine:startConsumer()
		return consumer.start_consumer(self)
	end

	function newLine:stopConsumer()
		consumer.stop_consumer(self)
	end

	return newLine
end

-- v1 compat: M:new() creates a pipeline
function M:new(...)
	local configs = { ... }
	local merged = {}
	for _, cfg in ipairs(configs) do
		if type(cfg) == "table" then
			for k, v in pairs(cfg) do
				merged[k] = v
			end
		end
	end
	return M.makePipeline(merged)
end

-- expose drivers at top level
M.drivers = driver

setmetatable(M, { __index = line })

return M
