local protocol = require("termichatter.protocol")

local M = {}

function M.define(spec)
	spec = spec or {}
	local process_protocol = spec.process_protocol == true
	local pass_protocol = spec.pass_protocol ~= false
	local handler = spec.handler

	spec.handler = function(run)
		if protocol.is_protocol(run) and not process_protocol then
			if pass_protocol then
				return nil
			end
			return false
		end

		if type(handler) == "function" then
			return handler(run)
		end
		return run.input
	end

	return spec
end

return M
