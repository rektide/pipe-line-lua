--- Driver: schedule periodic execution for consumer
local M = {}

--- Interval driver: fixed interval scheduling
---@param ms number Interval in millisecond
---@param callback function Function to call each interval
---@return table driver { start, stop }
function M.interval(ms, callback)
	local timer = nil

	return {
		start = function()
			if timer then
				return
			end
			timer = vim.uv.new_timer()
			timer:start(ms, ms, vim.schedule_wrap(callback))
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

--- Rescheduler driver: adaptive rescheduling with backoff
---@param config table { interval: number, backoff?: number, maxInterval?: number }
---@param callback function Function to call, return true to reset interval
---@return table driver { start, stop }
function M.rescheduler(config, callback)
	local baseInterval = config.interval or 50
	local backoff = config.backoff or 1.5
	local maxInterval = config.maxInterval or 2000
	local currentInterval = baseInterval
	local timer = nil

	local function schedule()
		if not timer then
			return
		end
		timer:start(
			currentInterval,
			0,
			vim.schedule_wrap(function()
				local hadWork = callback()
				if hadWork then
					currentInterval = baseInterval
				else
					currentInterval = math.min(currentInterval * backoff, maxInterval)
				end
				schedule()
			end)
		)
	end

	return {
		start = function()
			if timer then
				return
			end
			timer = vim.uv.new_timer()
			schedule()
		end,
		stop = function()
			if timer then
				timer:stop()
				timer:close()
				timer = nil
			end
		end,
		reset = function()
			currentInterval = baseInterval
		end,
	}
end

return M
