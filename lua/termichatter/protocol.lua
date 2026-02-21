--- Completion protocol for async pipeline coordination
--- Implements mpsc-completion hello/done counting protocol
local M = {}

M.hello = { type = "termichatter.completion.hello" }
M.done = { type = "termichatter.completion.done" }
M.shutdown = { type = "termichatter.shutdown" }

--- Check if a message is a completion signal
---@param msg table the message to check
---@return boolean
function M.isCompletion(msg)
	return msg
		and msg.type
		and (
			msg.type == "termichatter.completion.done"
			or msg.type == "termichatter.completion.hello"
			or msg.type == "termichatter.shutdown"
		)
end

--- Check if a message is the final shutdown signal
---@param msg table the message to check
---@return boolean
function M.isShutdown(msg)
	return msg and msg.type == "termichatter.shutdown"
end

--- Create a completion tracker for reference counting hello/done pair
---@param outputQueue? table the queue to push shutdown signal to
---@return table tracker with hello(), done(), and count() method
function M.createTracker(outputQueue)
	local helloCount = 0
	local doneCount = 0
	local shutdownEmitted = false

	return {
		hello = function(self)
			helloCount = helloCount + 1
		end,

		done = function(self)
			doneCount = doneCount + 1
			if doneCount >= helloCount and not shutdownEmitted then
				shutdownEmitted = true
				if outputQueue then
					outputQueue:push(vim.deepcopy(M.shutdown))
				end
				return true
			end
			return false
		end,

		count = function(self)
			return helloCount, doneCount
		end,

		isShutdown = function(self)
			return shutdownEmitted
		end,

		reset = function(self)
			helloCount = 0
			doneCount = 0
			shutdownEmitted = false
		end,
	}
end

return M
