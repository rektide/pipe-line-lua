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

---@param run table
---@param strategy? 'self'|'clone'|'fork'
---@param new_input? any
---@param owner? string
---@return table continuation
function M.continuation_for_strategy(run, strategy, new_input, owner)
	if strategy == nil or strategy == "self" then
		if new_input ~= nil then
			run.input = new_input
		end
		return run
	end

	if strategy == "clone" then
		local input = new_input
		if input == nil then
			input = run.input
		end
		return run:clone(input)
	end

	if strategy == "fork" then
		local input = new_input
		if input == nil then
			input = run.input
		end
		return run:fork(input)
	end

	if owner then
		error("invalid " .. owner .. " strategy: " .. tostring(strategy), 0)
	end
	error("invalid continuation strategy: " .. tostring(strategy), 0)
end

return M
