local M = {}

local function ensure_table_input(input)
	if type(input) == "table" then
		return input
	end

	return {
		value = input,
	}
end

---@param input any
---@return boolean
function M.has(input)
	if type(input) ~= "table" then
		return false
	end
	local pl = input._pipe_line
	if type(pl) ~= "table" then
		return false
	end
	local list = pl.errors
	return type(list) == "table" and #list > 0
end

---@param input any
---@return table
function M.list(input)
	if not M.has(input) then
		return {}
	end
	return input._pipe_line.errors
end

---@param input any
---@param err table
---@return table payload
function M.add(input, err)
	local payload = ensure_table_input(input)
	payload._pipe_line = payload._pipe_line or {}
	payload._pipe_line.errors = payload._pipe_line.errors or {}
	table.insert(payload._pipe_line.errors, err)
	return payload
end

---@param handler function
---@return function
function M.guard(handler)
	if type(handler) ~= "function" then
		error("errors.guard requires a handler function", 0)
	end

	return function(run)
		if M.has(run.input) then
			return run.input
		end
		return handler(run)
	end
end

return M
