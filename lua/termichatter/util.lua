--- Utility functions for termichatter
local M = {}

-- Seed random once for UUID generation
math.randomseed(vim.uv.hrtime())

--- Generate UUID v4
---@return string
M.uuid = function()
	local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
	return string.gsub(template, "[xy]", function(c)
		local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
		return string.format("%x", v)
	end)
end

return M
