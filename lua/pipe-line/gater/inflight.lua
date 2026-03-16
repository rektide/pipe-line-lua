local async = require("pipe-line.async")
local Future = require("coop.future").Future

local M = {}

local function as_number(value)
	if type(value) == "number" then
		return value
	end
	if type(value) == "string" then
		return tonumber(value)
	end
	return nil
end

local function stop_type_from_context(context)
	local seg = context and context.segment
	local line = context and context.line
	return (type(seg) == "table" and (seg.gater_stop_type or seg.gate_stop_type))
		or (type(line) == "table" and (line.gater_stop_type or line.gate_stop_type))
		or "stop_drain"
end

local function is_stopped(stopped)
	return type(stopped) == "table" and stopped.done == true
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

---@param config? table
---@return table
function M.new(config)
	config = config or {}

	local aspect = {
		type = "gater.inflight",
		role = "gater",
		inflight = 0,
		pending = {},
		control = nil,
		stop_marked = false,
		stopped = Future.new(),
	}

	local function max_inflight(run)
		local value = run:cfg("gate_inflight_max")
		local parsed = as_number(value)
		if parsed == nil then
			return nil
		end
		return math.floor(parsed)
	end

	local function pending_limit(run)
		local value = run:cfg("gate_inflight_pending")
		local parsed = as_number(value)
		if parsed == nil then
			return nil
		end
		return math.floor(parsed)
	end

	local function overflow_policy(run)
		return run:cfg("gate_inflight_overflow", "error")
	end

	local function maybe_mark_component_stopped(self)
		if self.stop_marked then
			return
		end
		if #self.pending ~= 0 then
			return
		end
		if self.inflight ~= 0 then
			return
		end
		if type(self.control) ~= "table" then
			return
		end
		self.stop_marked = true
		self.control:mark_component_stopped(self)
		if not is_stopped(self.stopped) then
			self.stopped:complete({ stopped = true, type = self.type })
		end
	end

	local function pump_pending(self)
		while #self.pending > 0 do
			local run = self.pending[1]
			if type(run) ~= "table" then
				table.remove(self.pending, 1)
				if type(self.control) == "table" then
					self.control:track_pending(-1)
				end
			else
				local max = max_inflight(run)
				if max ~= nil and max <= 0 then
					table.remove(self.pending, 1)
					if type(self.control) == "table" then
						self.control:track_pending(-1)
					end
					settle_gate_error(run, "gate_inflight_max_zero", "gate_inflight_max must be greater than zero")
				elseif max ~= nil and self.inflight >= max then
					break
				elseif type(self.control) == "table" and self.control:is_stop_immediate() then
					table.remove(self.pending, 1)
					self.control:track_pending(-1)
					settle_gate_error(run, "gate_stop_immediate", "gater stopped immediately")
				else
					table.remove(self.pending, 1)
					if type(self.control) == "table" then
						self.control:track_pending(-1)
						self.control:mark_admitted(run)
					end
					self.inflight = self.inflight + 1
					run:on_settle(function()
						self.inflight = self.inflight - 1
						if self.inflight < 0 then
							self.inflight = 0
						end
						pump_pending(self)
						maybe_mark_component_stopped(self)
					end)
					run:dispatch()
				end
			end
		end

		maybe_mark_component_stopped(self)
	end

	local function admit_or_queue(self, run)
		local max = max_inflight(run)
		if max == nil then
			if type(self.control) == "table" then
				self.control:mark_admitted(run)
			end
			return run:dispatch()
		end

		if max <= 0 then
			settle_gate_error(run, "gate_inflight_max_zero", "gate_inflight_max must be greater than zero")
			return nil
		end

		if self.inflight < max then
			self.inflight = self.inflight + 1
			if type(self.control) == "table" then
				self.control:mark_admitted(run)
			end
			run:on_settle(function()
				self.inflight = self.inflight - 1
				if self.inflight < 0 then
					self.inflight = 0
				end
				pump_pending(self)
				maybe_mark_component_stopped(self)
			end)
			return run:dispatch()
		end

		local pending_max = pending_limit(run)
		if pending_max == nil or #self.pending < pending_max then
			table.insert(self.pending, run)
			if type(self.control) == "table" then
				self.control:track_pending(1)
			end
			return nil
		end

		local policy = overflow_policy(run)
		if policy == "drop_oldest" then
			local dropped = table.remove(self.pending, 1)
			if dropped ~= nil then
				if type(self.control) == "table" then
					self.control:track_pending(-1)
				end
				settle_gate_error(dropped, "gate_overflow_drop_oldest", "dropped by gate overflow policy")
			end
			table.insert(self.pending, run)
			if type(self.control) == "table" then
				self.control:track_pending(1)
			end
			return nil
		end

		if policy == "drop_newest" then
			settle_gate_error(run, "gate_overflow_drop_newest", "dropped by gate overflow policy")
			return nil
		end

		settle_gate_error(run, "gate_overflow", "gate pending queue is full")
		return nil
	end

	aspect.handle = function(self, run)
		if not async.is_async_op(run._async and run._async.op) then
			return run:dispatch()
		end

		local control = (run._async and run._async.control) or self.control
		if type(control) == "table" then
			self.control = control
			if not control:can_accept_new() then
				settle_gate_error(run, "gate_not_accepting", "gater is not accepting new runs")
				return nil
			end
		end

		return admit_or_queue(self, run)
	end

	aspect.ensure_prepared = function(self, context)
		if is_stopped(self.stopped) then
			self.stopped = Future.new()
		end
		self.stop_marked = false
		local control = context and context.control
		if type(control) == "table" then
			self.control = control
			control:register_component(self)
			self.stopped = control.stopped
		end
		return nil
	end

	aspect.ensure_stopped = function(self, context)
		local control = (context and context.control) or self.control
		if type(control) == "table" then
			self.control = control
			control:request_stop(stop_type_from_context(context))
			self.stopped = control.stopped

			if control:is_stop_immediate() then
				for _, pending_run in ipairs(self.pending) do
					settle_gate_error(pending_run, "gate_stop_immediate", "gater stopped immediately")
				end
				if #self.pending > 0 then
					control:track_pending(-#self.pending)
				end
				self.pending = {}
			end
		end

		pump_pending(self)
		maybe_mark_component_stopped(self)
		return self.stopped
	end

	return aspect
end

setmetatable(M, {
	__call = function(_, config)
		return M.new(config)
	end,
})

return M
