--- Logger infrastructure for creating message loggers
local M = {}

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
---@param parent? table parent module to inherit from (must have log function)
---@return table logger the logger (callable table with methods)
M.baseLogger = function(config, parent)
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
		if parent and parent.log then
			parent.log(msg, ctx)
		end

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

return M

