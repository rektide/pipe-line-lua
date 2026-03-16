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

---@param config? table
---@return table
function M.new(config)
	config = config or {}

	local aspect = {
		type = "gater.inflight",
		role = "gater",
		inflight = 0,
		pending = {},
		accepting = true,
		draining = false,
		stopping = false,
		stopped = Future.new(),
	}

	local function maybe_complete_stopped(self)
		if self.stopping and self.inflight == 0 and #self.pending == 0 and not is_stopped(self.stopped) then
			self.stopped:complete({
				stopped = true,
				type = self.type,
			})
		end
	end

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

	local function settle_gate_error(run, code, message)
		run:settle({
			status = "error",
			error = {
				code = code,
				message = message,
			},
		})
	end

	local function pump_pending(self)
		if #self.pending == 0 then
			maybe_complete_stopped(self)
			return
		end

		while #self.pending > 0 do
			local run = self.pending[1]
			if type(run) ~= "table" then
				table.remove(self.pending, 1)
			else
				local max = max_inflight(run)
				if max ~= nil and max <= 0 then
					table.remove(self.pending, 1)
					settle_gate_error(run, "gate_inflight_max_zero", "gate_inflight_max must be greater than zero")
				elseif max ~= nil and self.inflight >= max then
					break
				elseif not self.accepting and not self.draining then
					table.remove(self.pending, 1)
					settle_gate_error(run, "gate_not_accepting", "gater is not accepting new runs")
				else
					table.remove(self.pending, 1)
					self.inflight = self.inflight + 1
					run:on_settle(function()
						self.inflight = self.inflight - 1
						if self.inflight < 0 then
							self.inflight = 0
						end
						pump_pending(self)
						maybe_complete_stopped(self)
					end)
					run:dispatch()
				end
			end
		end

		maybe_complete_stopped(self)
	end

	local function admit_or_queue(self, run)
		local max = max_inflight(run)
		if max == nil then
			return run:dispatch()
		end

		if max <= 0 then
			settle_gate_error(run, "gate_inflight_max_zero", "gate_inflight_max must be greater than zero")
			return nil
		end

		if self.inflight < max then
			self.inflight = self.inflight + 1
			run:on_settle(function()
				self.inflight = self.inflight - 1
				if self.inflight < 0 then
					self.inflight = 0
				end
				pump_pending(self)
				maybe_complete_stopped(self)
			end)
			return run:dispatch()
		end

		local pending_max = pending_limit(run)
		if pending_max == nil or #self.pending < pending_max then
			table.insert(self.pending, run)
			return nil
		end

		local policy = overflow_policy(run)
		if policy == "drop_oldest" then
			local dropped = table.remove(self.pending, 1)
			if dropped ~= nil then
				settle_gate_error(dropped, "gate_overflow_drop_oldest", "dropped by gate overflow policy")
			end
			table.insert(self.pending, run)
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

		if not self.accepting and not self.draining then
			settle_gate_error(run, "gate_not_accepting", "gater is not accepting new runs")
			return nil
		end

		return admit_or_queue(self, run)
	end

	aspect.ensure_prepared = function(self, _context)
		if is_stopped(self.stopped) then
			self.stopped = Future.new()
		end
		self.accepting = true
		self.draining = false
		self.stopping = false
		return nil
	end

	aspect.ensure_stopped = function(self, context)
		if is_stopped(self.stopped) then
			return self.stopped
		end

		self.accepting = false
		self.stopping = true

		local stop_type = stop_type_from_context(context)
		if stop_type == "stop_immediate" then
			self.draining = false
			for _, pending_run in ipairs(self.pending) do
				settle_gate_error(pending_run, "gate_stop_immediate", "gater stopped immediately")
			end
			self.pending = {}
			maybe_complete_stopped(self)
			return self.stopped
		end

		self.draining = true
		pump_pending(self)
		maybe_complete_stopped(self)
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
