local M = {}

---@param _config? table
---@return table aspect
function M.new(_config)
	return {
		type = "gater.none",
		role = "gater",
		handle = function(self, run)
			return run:dispatch()
		end,
	}
end

setmetatable(M, {
	__call = function(_, config)
		return M.new(config)
	end,
})

return M
