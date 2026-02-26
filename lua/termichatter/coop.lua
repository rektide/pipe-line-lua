local coop = require("coop")

local M = {}

---@param value any
---@param out? table
---@return table
function M.collect_awaitables(value, out)
	out = out or {}
	if value == nil then
		return out
	end

	if type(value) == "table" and type(value.await) == "function" then
		table.insert(out, value)
		return out
	end

	if type(value) == "table" then
		for _, item in ipairs(value) do
			M.collect_awaitables(item, out)
		end
	end

	return out
end

---@param tasks table
---@param timeout? number
---@param interval? number
---@return boolean
function M.await_all(tasks, timeout, interval)
	if #tasks == 0 then
		return true
	end

	if type(coop.await_all) == "function" then
		local ok, result = pcall(coop.await_all, tasks)
		if ok then
			return result
		end
		if type(result) == "string" and string.match(result, "cancelled") then
			return true
		end
	end

	for _, task in ipairs(tasks) do
		local ok, err = pcall(function()
			task:await(timeout or 200, interval or 10)
		end)
		if not ok and not tostring(err):match("cancelled") then
			error(err, 0)
		end
	end

	return true
end

return M
