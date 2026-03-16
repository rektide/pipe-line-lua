local Future = require("coop.future").Future

local M = {}

local function is_done(awaitable)
	return type(awaitable) == "table" and awaitable.done == true
end

local function stop_type_from_context(context)
	local seg = context and context.segment
	local line = context and context.line
	return (type(seg) == "table" and (seg.executor_stop_type or seg.gater_stop_type or seg.gate_stop_type))
		or (type(line) == "table" and (line.executor_stop_type or line.gater_stop_type or line.gate_stop_type))
		or "stop_drain"
end

---@param config? table
---@return table
function M.new(config)
	config = config or {}

	local control = {
		type = "async.control",
		state = "running",
		stop_type = nil,
		pending = 0,
		inflight = 0,
		admitted = setmetatable({}, { __mode = "k" }),
		components = setmetatable({}, { __mode = "k" }),
		drained = Future.new(),
		stopped = Future.new(),
		line = config.line,
		segment = config.segment,
		pos = config.pos,
	}

	function control:_is_stopping()
		return self.state == "stopping_drain" or self.state == "stopping_immediate" or self.state == "stopped"
	end

	function control:_all_components_stopped()
		for _, stopped in pairs(self.components) do
			if stopped ~= true then
				return false
			end
		end
		return true
	end

	function control:_maybe_complete_drained()
		if is_done(self.drained) then
			return
		end

		if self:_is_stopping() and self.pending == 0 and self.inflight == 0 then
			self.drained:complete({
				drained = true,
				state = self.state,
				stop_type = self.stop_type,
			})
		end
	end

	function control:_maybe_complete_stopped()
		if is_done(self.stopped) then
			return
		end

		self:_maybe_complete_drained()
		if not is_done(self.drained) then
			return
		end

		if self:_all_components_stopped() then
			self.state = "stopped"
			self.stopped:complete({
				stopped = true,
				stop_type = self.stop_type,
			})
		end
	end

	function control:register_component(component)
		if type(component) ~= "table" then
			return
		end
		if self.components[component] == nil then
			self.components[component] = false
		end
		self:_maybe_complete_stopped()
	end

	function control:mark_component_stopped(component)
		if type(component) ~= "table" then
			return
		end
		self.components[component] = true
		self:_maybe_complete_stopped()
	end

	function control:can_accept_new()
		return self.state == "running"
	end

	function control:is_stop_immediate()
		return self.state == "stopping_immediate" or self.state == "stopped" and self.stop_type == "stop_immediate"
	end

	function control:track_pending(delta)
		self.pending = self.pending + (delta or 0)
		if self.pending < 0 then
			self.pending = 0
		end
		self:_maybe_complete_drained()
		self:_maybe_complete_stopped()
	end

	function control:mark_admitted(run)
		if type(run) ~= "table" then
			return
		end
		if self.admitted[run] then
			return
		end

		self.admitted[run] = true
		self.inflight = self.inflight + 1
		self:_maybe_complete_drained()
		self:_maybe_complete_stopped()

		if type(run.on_settle) == "function" then
			run:on_settle(function()
				if not self.admitted[run] then
					return
				end
				self.admitted[run] = nil
				self.inflight = self.inflight - 1
				if self.inflight < 0 then
					self.inflight = 0
				end
				self:_maybe_complete_drained()
				self:_maybe_complete_stopped()
			end)
		end
	end

	function control:on_drained(callback)
		if type(callback) ~= "function" then
			return
		end
		if is_done(self.drained) then
			callback()
			return
		end

		local ok = pcall(function()
			self.drained:await(function()
				callback()
			end)
		end)
		if not ok then
			callback()
		end
	end

	function control:request_stop(context_or_type)
		local requested = context_or_type
		if type(context_or_type) == "table" then
			requested = stop_type_from_context(context_or_type)
		end
		if requested ~= "stop_immediate" then
			requested = "stop_drain"
		end

		if self.state == "running" then
			self.stop_type = requested
			self.state = (requested == "stop_immediate") and "stopping_immediate" or "stopping_drain"
		elseif self.state == "stopping_drain" and requested == "stop_immediate" then
			self.stop_type = "stop_immediate"
			self.state = "stopping_immediate"
		elseif self.stop_type == nil then
			self.stop_type = requested
		end

		self:_maybe_complete_drained()
		self:_maybe_complete_stopped()
		return self.stopped
	end

	return control
end

setmetatable(M, {
	__call = function(_, config)
		return M.new(config)
	end,
})

return M
