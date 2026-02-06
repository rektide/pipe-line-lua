--- Completion protocol messages for async pipeline coordination
local M = {}

M.hello = { type = "termichatter.completion.hello" }
M.done = { type = "termichatter.completion.done" }
M.shutdown = { type = "termichatter.shutdown" }

--- Check if a message is a completion signal
---@param msg table the message to check
---@return boolean
M.isCompletion = function(msg)
	return msg and msg.type and (
		msg.type == "termichatter.completion.done" or
		msg.type == "termichatter.completion.hello" or
		msg.type == "termichatter.shutdown"
	)
end

--- Check if a message is the final shutdown signal
---@param msg table the message to check
---@return boolean
M.isShutdown = function(msg)
	return msg and msg.type == "termichatter.shutdown"
end

--- Create a completion tracker for reference counting hello/done pairs
--- Tracks hello count and emits shutdown when all dones received
---@param outputQueue table the queue to push shutdown signal to
---@return table tracker with hello(), done(), and wrap() methods
M.createCompletionTracker = function(outputQueue)
	local helloCount = 0
	local doneCount = 0
	local shutdownEmitted = false

	local tracker = {
		--- Register a hello signal
		hello = function(self)
			helloCount = helloCount + 1
		end,

		--- Register a done signal, emit shutdown when balanced
		---@return boolean shutdownEmitted true if shutdown was just emitted
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

		--- Get current counts
		---@return number helloCount, number doneCount
		counts = function(self)
			return helloCount, doneCount
		end,

		--- Check if shutdown has been emitted
		---@return boolean
		isShutdown = function(self)
			return shutdownEmitted
		end,

		--- Reset the tracker
		reset = function(self)
			helloCount = 0
			doneCount = 0
			shutdownEmitted = false
		end,

		--- Wrap a handler to automatically track hello/done
		--- Returns a handler that intercepts completion messages
		---@param handler function the original handler
		---@return function wrappedHandler
		wrap = function(self, handler)
			return function(msg, ctx)
				if msg.type == "termichatter.completion.hello" then
					self:hello()
					return msg
				elseif msg.type == "termichatter.completion.done" then
					self:done()
					return msg
				else
					return handler(msg, ctx)
				end
			end
		end,
	}

	return tracker
end

return M
