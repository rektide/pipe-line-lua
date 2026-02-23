--- termichatter pipecopy implementation
--- Fresh take with line/pipe/run/registry architecture
local M = {}

local inherit = require("termichatter.inherit")
local registry = require("termichatter.registry")
local line = require("termichatter.line")
local run = require("termichatter.run")
local pipe = require("termichatter.pipe")
local consumer = require("termichatter.consumer")
local outputter = require("termichatter.outputter")
local driver = require("termichatter.driver")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

M.inherit = inherit
M.registry = registry
M.line = line
M.run = run
M.pipe = pipe
M.consumer = consumer
M.outputter = outputter
M.driver = driver

local resolver_mod = require("termichatter.resolver")

registry:register("timestamper", pipe.timestamper)
registry:register("cloudevent", pipe.cloudevent)
registry:register("module_filter", pipe.module_filter)
registry:register("priority_filter", pipe.priority_filter)
registry:register("ingester", pipe.ingester)
registry:register("lattice_resolver", {
	wants = {},
	emits = {},
	handler = resolver_mod.lattice_resolver,
})

M.defaultPipe = {
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

M.completion = {
	hello = { type = "termichatter.completion.hello" },
	done = { type = "termichatter.completion.done" },
}

--- Create a new line (pipeline) with optional config
---@param config? table { pipe?: string[], source?: string, ... }
---@return table pipeline The new line with logging method
function M.makePipeline(config)
	config = config or {}

	local newLine = line:clone({
		pipe = config.pipe or M.defaultPipe,
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

		return logger
	end

	function newLine:addProcessor(name, handler, pos)
		if handler then
			local reg = self.registry or registry
			reg:register(name, handler)
		end
		pos = pos or (#self.pipe + 1)
		self.pipe:splice(pos, 0, name)
	end

	function newLine:makePipeline(subConfig)
		subConfig = subConfig or {}
		local child = M.makePipeline(subConfig)
		-- child shares parent's output unless explicitly overridden
		if not subConfig.output then
			child.output = self.output
			child.outputQueue = self.outputQueue
		end
		setmetatable(child, { __index = self })
		return child
	end

	function newLine:new(config)
		return self:makePipeline(config)
	end

	function newLine:startConsumer()
		return consumer.start_consumer(self)
	end

	function newLine:stopConsumer()
		consumer.stop_consumer(self)
	end

	for name, level in pairs(M.priority) do
		if name ~= "log" then
			newLine[name] = function(self, msg)
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

	return newLine
end

--- Create a new module instance, inheriting from self
---@param config? table { pipe?: string[], source?: string, ... }
---@return table module The new module with logging method
function M:new(config)
	if self == M then
		return M.makePipeline(config)
	end
	return self:makePipeline(config)
end

setmetatable(M, { __index = line })

return M
