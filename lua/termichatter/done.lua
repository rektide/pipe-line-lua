--- Deferred helper for line done lifecycle.
local M = {}

---@return table deferred
function M.create_deferred()
	local resolved = false
	local value = nil
	local callbacks = {}

	return {
		resolve = function(self, next_value)
			if resolved then
				return false
			end
			resolved = true
			value = next_value
			for _, cb in ipairs(callbacks) do
				cb(next_value)
			end
			callbacks = {}
			return true
		end,

		await = function(self, timeout, interval)
			if resolved then
				return value
			end
			local ok = vim.wait(timeout or 1000, function()
				return resolved
			end, interval or 10)
			if ok then
				return value
			end
			return nil
		end,

		on_resolve = function(self, callback)
			if resolved then
				callback(value)
				return
			end
			table.insert(callbacks, callback)
		end,

		is_resolved = function(self)
			return resolved
		end,
	}
end

return M
