--- Processor classes for filtering and transformation
--- These wrap handler functions with queue-based async processing
local M = {}

local MpscQueue = require("coop.mpsc-queue").MpscQueue
local protocol = require("termichatter.protocol")
local util = require("termichatter.util")

--- Base processor loop - shared by all processor classes
---@param self table processor with inputQueue, outputQueue, process method
local function runProcessorLoop(self)
	while true do
		local msg = self.inputQueue:pop()
		if not msg then
			break
		end
		if protocol.isShutdown(msg) then
			self.outputQueue:push(msg)
			break
		end
		if protocol.isCompletion(msg) then
			self.outputQueue:push(msg)
		else
			local result = self:process(msg)
			if result then
				self.outputQueue:push(result)
			end
		end
	end
end

--------------------------------------------------
-- Built-in pipeline handlers
--------------------------------------------------

--- Add high-resolution timestamp
---@param msg table
---@return table
M.timestamper = function(msg)
	msg.time = msg.time or vim.uv.hrtime()
	return msg
end

--- No-op ingester (override to customize)
---@param msg table
---@return table
M.ingester = function(msg)
	return msg
end

--- Add CloudEvents fields (id, source, specversion)
---@param msg table
---@param self table
---@return table
M.cloudevents = function(msg, self)
	msg.id = msg.id or util.uuid()
	msg.source = msg.source or self.source
	msg.specversion = msg.specversion or "1.0"
	return msg
end

--- Filter by source/module pattern
---@param msg table
---@param self table
---@return table|nil
M.module_filter = function(msg, self)
	local filter = self.filter
	if not filter then
		return msg
	end
	local source = msg.source or msg.module or ""
	if type(filter) == "string" then
		return string.match(source, filter) and msg or nil
	elseif type(filter) == "function" then
		return filter(msg, self) and msg or nil
	end
	return msg
end

--- Generate UUID v4
---@return string
M.uuid = util.uuid

--------------------------------------------------
-- ModuleFilter - npm `debug` style pattern filter
--------------------------------------------------

---@param config table { patterns?: string[], exclude?: string[], inputQueue?, outputQueue? }
---@return table processor
M.ModuleFilter = function(config)
	config = config or {}
	local patterns = config.patterns or { ".*" }
	local exclude = config.exclude or {}

	local function matches(source)
		source = source or ""
		for _, pattern in ipairs(exclude) do
			if string.match(source, pattern) then
				return false
			end
		end
		for _, pattern in ipairs(patterns) do
			if string.match(source, pattern) then
				return true
			end
		end
		return false
	end

	local processor = {
		inputQueue = config.inputQueue or MpscQueue.new(),
		outputQueue = config.outputQueue or MpscQueue.new(),

		process = function(_, msg)
			local source = msg.source or msg.module or ""
			return matches(source) and msg or nil
		end,

		start = runProcessorLoop,

		setPatterns = function(_, newPatterns)
			patterns = newPatterns
		end,

		setExclude = function(_, newExclude)
			exclude = newExclude
		end,
	}
	return processor
end

--------------------------------------------------
-- CloudEventsEnricher - stamps CloudEvents fields
--------------------------------------------------

---@param config table { source?: string, type?: string, inputQueue?, outputQueue? }
---@return table processor
M.CloudEventsEnricher = function(config)
	config = config or {}
	local defaultSource = config.source or "termichatter"
	local defaultType = config.type or "termichatter.log"

	local processor = {
		inputQueue = config.inputQueue or MpscQueue.new(),
		outputQueue = config.outputQueue or MpscQueue.new(),

		process = function(_, msg)
			msg.specversion = msg.specversion or "1.0"
			msg.id = msg.id or util.uuid()
			msg.source = msg.source or defaultSource
			msg.type = msg.type or defaultType
			msg.time = msg.time or os.date("!%Y-%m-%dT%H:%M:%SZ")
			return msg
		end,

		start = runProcessorLoop,
	}
	return processor
end

--------------------------------------------------
-- PriorityFilter - filters by log level
--------------------------------------------------

---@param config table { minLevel?: number, maxLevel?: number, inputQueue?, outputQueue? }
---@return table processor
M.PriorityFilter = function(config)
	config = config or {}
	local minLevel = config.minLevel or 1
	local maxLevel = config.maxLevel or 6

	local priorities = {
		error = 1,
		warn = 2,
		info = 3,
		log = 4,
		debug = 5,
		trace = 6,
	}

	local processor = {
		inputQueue = config.inputQueue or MpscQueue.new(),
		outputQueue = config.outputQueue or MpscQueue.new(),

		process = function(_, msg)
			local level = msg.priorityLevel or priorities[msg.priority] or 4
			return (level >= minLevel and level <= maxLevel) and msg or nil
		end,

		start = runProcessorLoop,

		setMinLevel = function(_, level)
			if type(level) == "string" then
				level = priorities[level] or 1
			end
			minLevel = level
		end,

		setMaxLevel = function(_, level)
			if type(level) == "string" then
				level = priorities[level] or 6
			end
			maxLevel = level
		end,
	}
	return processor
end

--------------------------------------------------
-- Transformer - custom transform function
--------------------------------------------------

---@param config table { transform: function, inputQueue?, outputQueue? }
---@return table processor
M.Transformer = function(config)
	config = config or {}
	local transform = config.transform or function(msg)
		return msg
	end

	local processor = {
		inputQueue = config.inputQueue or MpscQueue.new(),
		outputQueue = config.outputQueue or MpscQueue.new(),

		process = function(_, msg)
			return transform(msg)
		end,

		start = runProcessorLoop,

		setTransform = function(_, fn)
			transform = fn
		end,
	}
	return processor
end

return M
