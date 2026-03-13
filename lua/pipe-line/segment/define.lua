local protocol = require("pipe-line.protocol")

local M = {}

---@param run table
---@return boolean
function M.is_protocol_run(run)
	return protocol.is_protocol(run)
end

---@param spec table
---@param run table
---@return boolean passthrough
---@return boolean stop
function M.protocol_decision(spec, run)
	local process_protocol = spec.process_protocol == true
	local pass_protocol = spec.pass_protocol ~= false

	if not M.is_protocol_run(run) or process_protocol then
		return false, false
	end

	if pass_protocol then
		return true, false
	end

	return false, true
end

---@param spec table
---@param handler? function
---@return function
function M.wrap_handler(spec, handler)
	handler = handler or spec.handler

	return function(run)
		local passthrough, stop = M.protocol_decision(spec, run)
		if passthrough then
			return nil
		end
		if stop then
			return false
		end

		if type(handler) == "function" then
			return handler(run)
		end
		return run.input
	end
end

function M.define(spec)
	spec = spec or {}
	spec.handler = M.wrap_handler(spec, spec.handler)

	return spec
end

return M
