--- Pipeline stage handlers and processor classes
local M = {}

local coop = require("coop")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

-- Seed random once at module load for UUID generation
math.randomseed(vim.uv.hrtime())

--- Default timestamper using high-resolution clock
---@param msg table the message to timestamp
---@return table msg the timestamped message
M.timestamper = function(msg)
	if not msg.time then
		msg.time = vim.uv.hrtime()
	end
	return msg
end

--- Default ingester (no-op, can be overridden)
---@param msg table the message
---@return table msg the message unchanged
M.ingester = function(msg)
	return msg
end

--- CloudEvents enricher - stamps standard fields onto messages
---@param msg table the message to enrich
---@param self table the module context
---@return table msg the enriched message
M.cloudevents = function(msg, self)
	if not msg.id then
		msg.id = M.uuid()
	end
	if not msg.source and self.source then
		msg.source = self.source
	end
	if not msg.specversion then
		msg.specversion = "1.0"
	end
	return msg
end

--- Generate a simple UUID v4
---@return string uuid
M.uuid = function()
	local random = math.random
	local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
	return string.gsub(template, "[xy]", function(c)
		local v = (c == "x") and random(0, 0xf) or random(8, 0xb)
		return string.format("%x", v)
	end)
end

--- Module filter - npm `debug` style filter system
--- Filters messages based on module name patterns
---@param msg table the message
---@param self table the module context
---@return table|nil msg the message or nil if filtered
M.module_filter = function(msg, self)
	local filter = self.filter
	if not filter then
		return msg
	end
	local source = msg.source or msg.module or ""
	if type(filter) == "string" then
		if string.match(source, filter) then
			return msg
		end
		return nil
	elseif type(filter) == "function" then
		return filter(msg, self) and msg or nil
	end
	return msg
end


--- ModuleFilter processor - npm `debug` style filter system
--- Filters messages based on module/source patterns
---@param config table { patterns?: string[], exclude?: string[] }
---@return table processor
M.ModuleFilter = function(config)
	config = config or {}
	local patterns = config.patterns or { ".*" } -- Match all by default
	local exclude = config.exclude or {}

	--- Check if a source matches the filter
	---@param source string the source/module name
	---@return boolean matched
	local function matches(source)
		source = source or ""

		-- Check exclusions first
		for _, pattern in ipairs(exclude) do
			if string.match(source, pattern) then
				return false
			end
		end

		-- Check inclusions
		for _, pattern in ipairs(patterns) do
			if string.match(source, pattern) then
				return true
			end
		end

		return false
	end

	return {
		inputQueue = config.inputQueue or MpscQueue.new(),
		outputQueue = config.outputQueue or MpscQueue.new(),

		--- Process a single message
		---@param msg table the message
		---@return table|nil msg the message or nil if filtered
		process = function(self, msg)
			local source = msg.source or msg.module or ""
			if matches(source) then
				return msg
			end
			return nil
		end,

		--- Start processing loop
		---@async
		start = function(self)
			while true do
				local msg = self.inputQueue:pop()
				if msg.type == "termichatter.completion.done" then
					self.outputQueue:push(msg)
					break
				end
				local result = self:process(msg)
				if result then
					self.outputQueue:push(result)
				end
			end
		end,

		--- Update filter patterns
		---@param newPatterns string[] new patterns
		setPatterns = function(self, newPatterns)
			patterns = newPatterns
		end,

		--- Update exclude patterns
		---@param newExclude string[] new exclusions
		setExclude = function(self, newExclude)
			exclude = newExclude
		end,
	}
end

--- CloudEventsEnricher processor - stamps CloudEvents fields onto messages
---@param config table { source?: string, type?: string }
---@return table processor
M.CloudEventsEnricher = function(config)
	config = config or {}
	local defaultSource = config.source or "termichatter"
	local defaultType = config.type or "termichatter.log"

	--- Generate UUID v4
	local function uuid()
		local random = math.random
		local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
		return string.gsub(template, "[xy]", function(c)
			local v = (c == "x") and random(0, 0xf) or random(8, 0xb)
			return string.format("%x", v)
		end)
	end

	return {
		inputQueue = config.inputQueue or MpscQueue.new(),
		outputQueue = config.outputQueue or MpscQueue.new(),

		--- Process a single message - enrich with CloudEvents fields
		---@param msg table the message
		---@return table msg the enriched message
		process = function(self, msg)
			msg.specversion = msg.specversion or "1.0"
			msg.id = msg.id or uuid()
			msg.source = msg.source or defaultSource
			msg.type = msg.type or defaultType
			if not msg.time then
				msg.time = os.date("!%Y-%m-%dT%H:%M:%SZ")
			end
			return msg
		end,

		--- Start processing loop
		---@async
		start = function(self)
			while true do
				local msg = self.inputQueue:pop()
				if msg.type == "termichatter.completion.done" then
					self.outputQueue:push(msg)
					break
				end
				local result = self:process(msg)
				self.outputQueue:push(result)
			end
		end,
	}
end

--- PriorityFilter processor - filters by log level
---@param config table { minLevel?: number, maxLevel?: number }
---@return table processor
M.PriorityFilter = function(config)
	config = config or {}
	local minLevel = config.minLevel or 1 -- error
	local maxLevel = config.maxLevel or 6 -- trace

	local priorities = {
		error = 1,
		warn = 2,
		info = 3,
		log = 4,
		debug = 5,
		trace = 6,
	}

	return {
		inputQueue = config.inputQueue or MpscQueue.new(),
		outputQueue = config.outputQueue or MpscQueue.new(),

		--- Process a single message
		---@param msg table the message
		---@return table|nil msg the message or nil if filtered
		process = function(self, msg)
			local level = msg.priorityLevel or priorities[msg.priority] or 4
			if level >= minLevel and level <= maxLevel then
				return msg
			end
			return nil
		end,

		--- Start processing loop
		---@async
		start = function(self)
			while true do
				local msg = self.inputQueue:pop()
				if msg.type == "termichatter.completion.done" then
					self.outputQueue:push(msg)
					break
				end
				local result = self:process(msg)
				if result then
					self.outputQueue:push(result)
				end
			end
		end,

		--- Set minimum level
		---@param level number|string the minimum level
		setMinLevel = function(self, level)
			if type(level) == "string" then
				level = priorities[level] or 1
			end
			minLevel = level
		end,

		--- Set maximum level
		---@param level number|string the maximum level
		setMaxLevel = function(self, level)
			if type(level) == "string" then
				level = priorities[level] or 6
			end
			maxLevel = level
		end,
	}
end

--- Transformer processor - applies a custom transform function
---@param config table { transform: function }
---@return table processor
M.Transformer = function(config)
	config = config or {}
	local transform = config.transform or function(msg)
		return msg
	end

	return {
		inputQueue = config.inputQueue or MpscQueue.new(),
		outputQueue = config.outputQueue or MpscQueue.new(),

		--- Process a single message
		---@param msg table the message
		---@return table|nil msg the transformed message
		process = function(self, msg)
			return transform(msg)
		end,

		--- Start processing loop
		---@async
		start = function(self)
			while true do
				local msg = self.inputQueue:pop()
				if msg.type == "termichatter.completion.done" then
					self.outputQueue:push(msg)
					break
				end
				local result = self:process(msg)
				if result then
					self.outputQueue:push(result)
				end
			end
		end,

		--- Update transform function
		---@param fn function new transform
		setTransform = function(self, fn)
			transform = fn
		end,
	}
end

return M
