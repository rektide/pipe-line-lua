local M = {}

M.inspect_opts = { newline = " ", indent = "" }

function M.inspect(msg)
	return vim.inspect(msg, M.inspect_opts)
end

return M
