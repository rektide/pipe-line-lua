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

registry:register("timestamper", pipe.timestamper)
registry:register("cloudevent", pipe.cloudevent)
registry:register("module_filter", pipe.module_filter)
registry:register("priority_filter", pipe.priority_filter)
registry:register("ingester", pipe.ingester)

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

	function newLine:makePipeline(subConfig)
		local child = M.makePipeline(subConfig)
		setmetatable(child, { __index = self })
		return child
	end

	function newLine:startConsumer()
		return consumer.start_consumer(self)
	end

	function newLine:stopConsumer()
		consumer.stop_consumer(self)
	end

	return newLine
end

setmetatable(M, { __index = line })

return M
