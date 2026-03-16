local buffered = require("pipe-line.executor.buffered")

local M = {}

---@param config? table
---@return table
function M.new(config)
	local aspect = buffered(config)
	aspect.type = "executor.direct"
	return aspect
end

setmetatable(M, {
	__call = function(_, config)
		return M.new(config)
	end,
})

return M
