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
--- Creates a logger function that inherits from its module (self)
---@param config? table logger configuration
---@return table logger the logger (callable table with methods)
M.baseLogger = function(self, config)
	config = config or {}

	local ctx = {}
	setmetatable(ctx, { __index = self })

	for k, v in pairs(config) do
		ctx[k] = v
	end

	local function doLog(msg)
		if type(msg) == "string" then
			msg = { message = msg }
		else
			msg = vim.deepcopy(msg)
		end

		if ctx.source then
			msg.source = msg.source or ctx.source
		end
		if ctx.module then
			msg.module = msg.module or ctx.module
		end

		-- timestamper and ingester are handled by the pipeline stages,
		-- not duplicated here

		if self.log then
			self.log(msg, ctx)
		end

		return msg
	end

	local logger = {
		ctx = ctx,
	}

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

