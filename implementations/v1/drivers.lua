--- Drivers for scheduling async consumers
local M = {}

--- Interval driver - fires at fixed intervals
---@param interval number milliseconds between iterations
---@param callback function the callback to run
---@return table driver with start/stop methods
M.interval = function(interval, callback)
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
M.rescheduler = function(config, callback)
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

return M
