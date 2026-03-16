local M = {}

local function stop_type_from_context(context)
	local seg = context and context.segment
	local line = context and context.line
	return (type(seg) == "table" and (seg.gater_stop_type or seg.gate_stop_type))
		or (type(line) == "table" and (line.gater_stop_type or line.gate_stop_type))
		or "stop_drain"
end

local function settle_gate_error(run, code, message)
	run:settle({
		status = "error",
		error = {
			code = code,
			message = message,
		},
	})
end

---@param _config? table
---@return table aspect
function M.new(_config)
	return {
		type = "gater.none",
		role = "gater",
		control = nil,
		stopped = nil,
		handle = function(self, run)
			local control = (run._async and run._async.control) or self.control
			if type(control) == "table" then
				if not control:can_accept_new() then
					settle_gate_error(run, "gate_not_accepting", "gater is not accepting new runs")
					return nil
				end
				control:mark_admitted(run)
			end
			return run:dispatch()
		end,
		ensure_prepared = function(self, context)
			local control = context and context.control
			if type(control) == "table" then
				self.control = control
				control:register_component(self)
				self.stopped = control.stopped
			end
			return self.stopped
		end,
		ensure_stopped = function(self, context)
			local control = (context and context.control) or self.control
			if type(control) ~= "table" then
				return self.stopped
			end
			control:request_stop(stop_type_from_context(context))
			control:mark_component_stopped(self)
			self.stopped = control.stopped
			return self.stopped
		end,
	}
end

setmetatable(M, {
	__call = function(_, config)
		return M.new(config)
	end,
})

return M
