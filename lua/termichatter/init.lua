--- termichatter: Asynchronous structured-data-flow atop coop.nvim
--- Main module providing core utilities and the default pipeline.
local M = {}

local MpscQueue = require("coop.mpsc-queue").MpscQueue

M.consumers = require("termichatter.consumers")

--- Completion protocol messages
M.completion = {
	hello = { type = "termichatter.completion.hello" },
	done = { type = "termichatter.completion.done" },
}

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

--- The default pipeline stages
M.pipeline = {
	"timestamper",
	"ingester",
	"cloudevents",
	"module_filter",
}

--- Corresponding queues for pipeline stages (nil = synchronous)
M.queues = {}

--- Log a message through the pipeline
--- Looks for pipeStep to start from, or sets to 1 and starts
--- Runs sync stages immediately, hands off to queues for async stages
---@param msg table the message to log
---@param self? table the module context (defaults to M)
M.log = function(msg, self)
	self = self or M
	msg.pipeStep = msg.pipeStep or 1

	local step = msg.pipeStep
	local pipeline = self.pipeline or M.pipeline

	while step <= #pipeline do
		local handler = pipeline[step]
		local queue = self.queues and self.queues[step]

		-- Resolve queue if it's a string or function
		if type(queue) == "string" then
			queue = self[queue]
		elseif type(queue) == "function" then
			queue = queue(msg)
		end

		-- If there's a queue at this step, push and return (async handoff)
		-- The consumer for this queue will continue processing
		if queue then
			msg.pipeStep = step
			queue:push(msg)
			return
		end

		-- Resolve handler if it's a string
		if type(handler) == "string" then
			handler = self[handler]
		end

		-- Run handler if present
		if handler and type(handler) == "function" then
			msg = handler(msg, self)
			if not msg then
				return -- Handler filtered the message
			end
		end

		step = step + 1
		msg.pipeStep = step
	end

	-- Message completed pipeline - push to output queue if present
	local outputQueue = self.outputQueue
	if outputQueue then
		outputQueue:push(msg)
	end
end

--- Add a processor to the pipeline at specified position
---@param self table the module
---@param name string the handler name
---@param handler function the handler function
---@param position? number position to insert (default: end)
---@param withQueue? boolean whether to create a queue at this position
---@return table self for chaining
M.addProcessor = function(self, name, handler, position, withQueue)
	position = position or (#self.pipeline + 1)
	self[name] = handler
	table.insert(self.pipeline, position, name)

	if withQueue then
		local queue = MpscQueue.new()
		table.insert(self.queues, position, queue)
	else
		table.insert(self.queues, position, nil)
	end

	return self
end

--- Create a new module/universe with its own pipeline
--- Copies all fields from parent, creates new pipeline/queues
---@param config? table configuration overrides
---@param parent? table parent module to inherit from (default: M)
---@return table module the new module
M.makePipeline = function(config, parent)
	parent = parent or M
	config = config or {}

	local module = {}

	-- Copy all fields from parent
	for k, v in pairs(parent) do
		if type(v) == "table" and k ~= "queues" and k ~= "pipeline" then
			module[k] = vim.deepcopy(v)
		else
			module[k] = v
		end
	end

	-- Create new pipeline and queues arrays
	module.pipeline = vim.deepcopy(parent.pipeline or M.pipeline)
	module.queues = {}

	-- Apply config overrides
	for k, v in pairs(config) do
		module[k] = v
	end

	-- Create output queue
	module.outputQueue = MpscQueue.new()

	return module
end

--- Priority levels for logging
M.priorities = {
	error = 1,
	warn = 2,
	info = 3,
	log = 4,
	debug = 5,
	trace = 6,
}

--- Base logger factory
--- Creates a logger function that inherits from its module
---@param config? table logger configuration
---@param parent? table parent module to inherit from
---@return table logger the logger (callable table with methods)
M.baseLogger = function(config, parent)
	parent = parent or M
	config = config or {}

	-- Create logger context inheriting from parent
	local ctx = {}
	setmetatable(ctx, { __index = parent })

	-- Apply config as overrides
	for k, v in pairs(config) do
		ctx[k] = v
	end

	--- The core log function
	---@param msg table|string the message to log
	---@return table msg the processed message
	local function doLog(msg)
		if type(msg) == "string" then
			msg = { message = msg }
		else
			msg = vim.deepcopy(msg)
		end

		-- Apply context fields
		if ctx.source then
			msg.source = msg.source or ctx.source
		end
		if ctx.module then
			msg.module = msg.module or ctx.module
		end

		-- Run timestamper if present
		if ctx.timestamper then
			msg = ctx.timestamper(msg)
		end

		-- Run ingester if present
		if ctx.ingester then
			msg = ctx.ingester(msg, ctx)
		end

		-- Forward to pipeline
		M.log(msg, ctx)

		return msg
	end

	-- Create logger as a callable table
	local logger = {
		ctx = ctx,
	}

	-- Attach priority-based logging methods
	for name, level in pairs(M.priorities) do
		logger[name] = function(msg)
			if type(msg) == "string" then
				msg = { message = msg }
			else
				msg = vim.deepcopy(msg)
			end
			msg.priority = name
			msg.priorityLevel = level
			return doLog(msg)
		end
	end

	-- Make logger callable
	setmetatable(logger, {
		__call = function(_, msg)
			return doLog(msg)
		end,
	})

	return logger
end

--- Default logger factory (alias to baseLogger)
M.logger = M.baseLogger

--- Drivers for scheduling async consumers
M.drivers = {}

--- Interval driver - fires at fixed intervals
---@param interval number milliseconds between iterations
---@param callback function the callback to run
---@return table driver with start/stop methods
M.drivers.interval = function(interval, callback)
	local timer = nil
	return {
		start = function()
			timer = vim.uv.new_timer()
			timer:start(0, interval, vim.schedule_wrap(callback))
		end,
		stop = function()
			if timer then
				timer:stop()
				timer:close()
				timer = nil
			end
		end,
	}
end

--- Rescheduler driver - reschedules after each iteration
---@param config table { interval: number, backoff?: number, maxInterval?: number }
---@param callback function the callback to run
---@return table driver with start/stop methods
M.drivers.rescheduler = function(config, callback)
	local timer = nil
	local currentInterval = config.interval or 100
	local backoff = config.backoff or 1
	local maxInterval = config.maxInterval or 5000
	local running = false

	local function schedule()
		if not running then
			return
		end
		timer = vim.uv.new_timer()
		timer:start(
			currentInterval,
			0,
			vim.schedule_wrap(function()
				if timer then
					timer:close()
					timer = nil
				end
				local hadWork = callback()
				if hadWork then
					currentInterval = config.interval or 100
				else
					currentInterval = math.min(currentInterval * backoff, maxInterval)
				end
				schedule()
			end)
		)
	end

	return {
		start = function()
			running = true
			schedule()
		end,
		stop = function()
			running = false
			if timer then
				timer:stop()
				timer:close()
				timer = nil
			end
		end,
	}
end

--- Default driver
M.driver = nil

return M
