local M = {}

M.inspect_opts = { newline = " ", indent = "" }

function M.inspect(msg)
	return vim.inspect(msg, M.inspect_opts)
end

---@param value any
---@return boolean
function M.is_segment_factory(value)
	return type(value) == "table"
		and value.type == "segment_factory"
		and type(value.create) == "function"
end

return M
