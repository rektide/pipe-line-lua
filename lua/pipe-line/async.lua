local M = {}
local coop = require("coop")
local task = require("coop.task")

local ASYNC_OP_TYPE = "async_op"
local ASYNC_FAIL_FIELD = "__pipe_line_async_fail"

local function normalize_error(err, fallback_code)
	if type(err) == "table" then
		if err.code == nil then
			err.code = fallback_code or "async_error"
		end
		if err.message == nil then
			err.message = tostring(err.detail or err.reason or "async error")
		end
		return err
	end

	return {
		code = fallback_code or "async_error",
		message = tostring(err),
	}
end

local function protected_call(fn, ...)
	if type(coop.copcall) == "function" and type(task.running) == "function" and task.running() ~= nil then
		return coop.copcall(fn, ...)
	end
	return pcall(fn, ...)
end

---@param value any
---@return boolean
function M.is_async_op(value)
	return type(value) == "table" and value.type == ASYNC_OP_TYPE and type(value.kind) == "string"
end

---@param value any
---@return boolean
function M.is_awaitable(value)
	if type(value) ~= "table" then
		return false
	end
	return type(value.await) == "function" or type(value.pawait) == "function"
end

---@param fn function
---@param meta? table
---@return table
function M.task_fn(fn, meta)
	if type(fn) ~= "function" then
		error("async.task_fn requires a function", 0)
	end

	return {
		type = ASYNC_OP_TYPE,
		kind = "task_fn",
		fn = fn,
		meta = meta,
	}
end

---@param awaitable table
---@param meta? table
---@return table
function M.awaitable(awaitable, meta)
	if type(awaitable) ~= "table" then
		error("async.awaitable requires a table", 0)
	end
	if not M.is_awaitable(awaitable) then
		error("async.awaitable requires await/pawait methods", 0)
	end

	return {
		type = ASYNC_OP_TYPE,
		kind = "awaitable",
		awaitable = awaitable,
		meta = meta,
	}
end

---@param err any
---@return table
function M.fail(err)
	return {
		[ASYNC_FAIL_FIELD] = true,
		error = normalize_error(err, "async_fail"),
	}
end

---@param value any
---@return boolean
function M.is_fail(value)
	return type(value) == "table" and value[ASYNC_FAIL_FIELD] == true
end

---@param value any
---@return table|nil
function M.normalize(value)
	if M.is_async_op(value) then
		return value
	end

	if M.is_awaitable(value) then
		return M.awaitable(value)
	end

	return nil
end

local function await_awaitable(awaitable)
	if type(awaitable.pawait) == "function" then
		local called, ok, value = protected_call(function()
			return awaitable:pawait()
		end)
		if not called then
			return {
				status = "error",
				error = normalize_error(ok, "async_awaitable_pawait"),
			}
		end
		if not ok then
			return {
				status = "error",
				error = normalize_error(value, "async_awaitable_error"),
			}
		end
		if M.is_fail(value) then
			return {
				status = "error",
				error = normalize_error(value.error, "async_fail"),
			}
		end
		return {
			status = "ok",
			value = value,
		}
	end

	if type(awaitable.await) == "function" then
		local ok, value = protected_call(function()
			return awaitable:await()
		end)
		if not ok then
			return {
				status = "error",
				error = normalize_error(value, "async_awaitable_await"),
			}
		end
		if M.is_fail(value) then
			return {
				status = "error",
				error = normalize_error(value.error, "async_fail"),
			}
		end
		return {
			status = "ok",
			value = value,
		}
	end

	return {
		status = "error",
		error = normalize_error("awaitable missing await/pawait", "async_invalid_awaitable"),
	}
end

---@param op table
---@param ctx table
---@return table outcome
function M.execute(op, ctx)
	if not M.is_async_op(op) then
		return {
			status = "error",
			error = normalize_error("invalid async op", "async_invalid_op"),
		}
	end

	if op.kind == "awaitable" then
		return await_awaitable(op.awaitable)
	end

	if op.kind == "task_fn" then
		local ok, value = protected_call(op.fn, ctx)
		if not ok then
			return {
				status = "error",
				error = normalize_error(value, "async_task_fn_error"),
			}
		end

		if M.is_fail(value) then
			return {
				status = "error",
				error = normalize_error(value.error, "async_fail"),
			}
		end

		if M.is_async_op(value) then
			return M.execute(value, ctx)
		end

		if M.is_awaitable(value) then
			return await_awaitable(value)
		end

		return {
			status = "ok",
			value = value,
		}
	end

	return {
		status = "error",
		error = normalize_error("unknown async op kind: " .. tostring(op.kind), "async_unknown_kind"),
	}
end

return M
