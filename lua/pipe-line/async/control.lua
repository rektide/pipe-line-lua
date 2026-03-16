local Future = require("coop.future").Future
local errors = require("pipe-line.errors")

local M = {}

local STATES = { "new", "prepared", "running", "draining", "stopped" }
local TIMING_STAGES = { "handle", "dispatch", "settle", "queue_wait" }

local function now_ns()
	if type(vim) == "table" and type(vim.uv) == "table" and type(vim.uv.hrtime) == "function" then
		return vim.uv.hrtime()
	end
	return math.floor(os.clock() * 1000000000)
end

local function ensure_array(value)
	if type(value) == "table" then
		return value
	end
	return {}
end

local function ensure_future(value)
	if type(value) == "table" and type(value.await) == "function" and type(value.complete) == "function" then
		return value
	end
	return Future.new()
end

local function future_done(future)
	return type(future) == "table" and future.done == true
end

local function complete_future_once(future, payload)
	if type(future) ~= "table" then
		return
	end
	if future.done == true then
		return
	end
	future:complete(payload)
end

local function as_number(value)
	if type(value) == "number" then
		return value
	end
	if type(value) == "string" then
		return tonumber(value)
	end
	return nil
end

local function resolve_stage_enabled(config, stage)
	if type(config) == "boolean" then
		return config
	end
	if type(config) ~= "table" then
		return false
	end

	if config[stage] ~= nil then
		return config[stage] == true
	end

	if config.enabled == true then
		return true
	end

	return false
end

local function resolve_stop_controls(segment, line, context_or_type)
	if type(context_or_type) == "string" then
		if context_or_type == "stop_immediate" then
			return {
				accept_new = false,
				pending = "drop",
				inflight = "cancel",
			}
		end
		return {
			accept_new = false,
			pending = "drain",
			inflight = "finish",
		}
	end

	local seg = segment
	local ln = line
	if type(context_or_type) == "table" then
		seg = context_or_type.segment or seg
		ln = context_or_type.line or ln
	end

	local seg_stop = type(seg) == "table" and seg.stop or nil
	local line_stop = type(ln) == "table" and ln.stop or nil

	local accept_new = (type(seg_stop) == "table" and seg_stop.accept_new)
	if accept_new == nil and type(seg) == "table" then
		accept_new = seg.stop_accept_new
	end
	if accept_new == nil and type(line_stop) == "table" then
		accept_new = line_stop.accept_new
	end
	if accept_new == nil and type(ln) == "table" then
		accept_new = ln.stop_accept_new
	end
	if accept_new == nil then
		accept_new = false
	end

	local pending = (type(seg_stop) == "table" and seg_stop.pending)
	if pending == nil and type(seg) == "table" then
		pending = seg.stop_pending
	end
	if pending == nil and type(line_stop) == "table" then
		pending = line_stop.pending
	end
	if pending == nil and type(ln) == "table" then
		pending = ln.stop_pending
	end
	if pending ~= "drop" then
		pending = "drain"
	end

	local inflight = (type(seg_stop) == "table" and seg_stop.inflight)
	if inflight == nil and type(seg) == "table" then
		inflight = seg.stop_inflight
	end
	if inflight == nil and type(line_stop) == "table" then
		inflight = line_stop.inflight
	end
	if inflight == nil and type(ln) == "table" then
		inflight = ln.stop_inflight
	end
	if inflight ~= "cancel" then
		inflight = "finish"
	end

	return {
		accept_new = accept_new == true,
		pending = pending,
		inflight = inflight,
	}
end

---@param config? table
---@return table
function M.new(config)
	config = config or {}

	local segment = config.segment
	local line = config.line
	local pos = config.pos

	if type(segment) ~= "table" then
		error("async.control requires segment table", 0)
	end

	segment.on_settle = ensure_array(segment.on_settle)
	segment.on_state_transition = ensure_array(segment.on_state_transition)
	segment.on_state_running = ensure_array(segment.on_state_running)

	segment.state = type(segment.state) == "table" and segment.state or {}
	segment.metric = type(segment.metric) == "table" and segment.metric or {}

	local state = segment.state
	state.value = state.value or "new"
	state.accept_new = state.accept_new ~= false
	state.pending = state.pending or 0
	state.inflight = state.inflight or 0
	state.stop = type(state.stop) == "table" and state.stop or {
		accept_new = false,
		pending = "drain",
		inflight = "finish",
	}
	state.promise = type(state.promise) == "table" and state.promise or {}
	for _, name in ipairs(STATES) do
		state.promise[name] = ensure_future(state.promise[name])
	end
	complete_future_once(state.promise.new, {
		state = "new",
		segment = segment,
		line = line,
		pos = pos,
	})

	local metric = segment.metric
	metric.counter = type(metric.counter) == "table" and metric.counter or {}
	metric.gauge = type(metric.gauge) == "table" and metric.gauge or {}
	metric.promise = type(metric.promise) == "table" and metric.promise or {}
	metric.timing = type(metric.timing) == "table" and metric.timing or {}

	metric.counter.admitted = metric.counter.admitted or 0
	metric.counter.queued = metric.counter.queued or 0
	metric.counter.dropped = metric.counter.dropped or 0
	metric.counter.settled_ok = metric.counter.settled_ok or 0
	metric.counter.settled_error = metric.counter.settled_error or 0
	metric.counter.running = metric.counter.running or 0

	metric.gauge.pending = metric.gauge.pending or 0
	metric.gauge.inflight = metric.gauge.inflight or 0

	metric.promise.drained = ensure_future(metric.promise.drained)
	metric.promise.stopped = state.promise.stopped

	local timing_config = segment.timing
	local timing_limit = 1024
	if type(timing_config) == "table" then
		timing_limit = as_number(timing_config.limit or timing_config.max_samples) or timing_limit
	end
	if timing_limit < 16 then
		timing_limit = 16
	end

	for _, stage in ipairs(TIMING_STAGES) do
		local bucket = metric.timing[stage]
		if type(bucket) ~= "table" then
			bucket = {}
			metric.timing[stage] = bucket
		end
		bucket.enabled = resolve_stage_enabled(timing_config, stage)
		bucket.values = ensure_array(bucket.values)
		bucket.count = bucket.count or 0
		bucket.resets = bucket.resets or 0
		bucket.limit = as_number(bucket.limit) or timing_limit
		if bucket.limit < 16 then
			bucket.limit = 16
		end
	end

	local control = {
		type = "async.control",
		line = line,
		segment = segment,
		pos = pos,
		state = state,
		metric = metric,
		timing = metric.timing,
		pending_queue = {},
		admitted = setmetatable({}, { __mode = "k" }),
		components = setmetatable({}, { __mode = "k" }),
		stop_requested = false,
		gate_policy = nil,
		pending = metric.gauge.pending,
		inflight = metric.gauge.inflight,
		drained = metric.promise.drained,
		stopped = state.promise.stopped,
	}

	function control:_sync_gauges()
		self.pending = self.metric.gauge.pending
		self.inflight = self.metric.gauge.inflight
		self.state.pending = self.pending
		self.state.inflight = self.inflight
	end

	function control:_transition(to, reason, detail)
		local from = self.state.value
		if from == to then
			return
		end

		self.state.value = to
		complete_future_once(self.state.promise[to], {
			state = to,
			from = from,
			reason = reason,
			detail = detail,
			segment = self.segment,
			line = self.line,
			pos = self.pos,
		})

		for _, hook in ipairs(self.segment.on_state_transition) do
			pcall(hook, {
				from = from,
				to = to,
				reason = reason,
				detail = detail,
				segment = self.segment,
				line = self.line,
				pos = self.pos,
				control = self,
			})
		end
	end

	function control:_record_timing(stage, duration_ns)
		local bucket = self.timing[stage]
		if type(bucket) ~= "table" or bucket.enabled ~= true then
			return
		end

		bucket.count = bucket.count + 1
		if #bucket.values >= bucket.limit then
			bucket.values = {}
			bucket.resets = bucket.resets + 1
			self.timing[stage] = bucket
		end

		table.insert(bucket.values, duration_ns)
	end

	function control:timing_start(stage)
		local bucket = self.timing[stage]
		if type(bucket) ~= "table" or bucket.enabled ~= true then
			return nil
		end
		return now_ns()
	end

	function control:timing_end(stage, started_at)
		if type(started_at) ~= "number" then
			return
		end
		self:_record_timing(stage, now_ns() - started_at)
	end

	function control:_resolve_gate_policy(run)
		local policy = self.gate_policy or {}
		local seg = self.segment
		local ln = self.line

		local max = policy.max
		if max == nil and type(seg) == "table" then
			max = seg.gate_inflight_max
		end
		if max == nil and type(ln) == "table" then
			max = ln.gate_inflight_max
		end
		if max == nil and type(run) == "table" and type(run.cfg) == "function" then
			max = run:cfg("gate_inflight_max")
		end
		max = as_number(max)
		if max ~= nil then
			max = math.floor(max)
			if max < 1 then
				max = 1
			end
		end

		local pending = policy.pending
		if pending == nil and type(seg) == "table" then
			pending = seg.gate_inflight_pending
		end
		if pending == nil and type(ln) == "table" then
			pending = ln.gate_inflight_pending
		end
		if pending == nil and type(run) == "table" and type(run.cfg) == "function" then
			pending = run:cfg("gate_inflight_pending")
		end
		pending = as_number(pending)
		if pending ~= nil then
			pending = math.floor(pending)
			if pending < 0 then
				pending = 0
			end
		end

		local overflow = policy.overflow
		if overflow == nil and type(seg) == "table" then
			overflow = seg.gate_inflight_overflow
		end
		if overflow == nil and type(ln) == "table" then
			overflow = ln.gate_inflight_overflow
		end
		if overflow == nil and type(run) == "table" and type(run.cfg) == "function" then
			overflow = run:cfg("gate_inflight_overflow")
		end
		if overflow ~= "drop_oldest" and overflow ~= "drop_newest" then
			overflow = "error"
		end

		return {
			max = max,
			pending = pending,
			overflow = overflow,
		}
	end

	function control:set_gate_policy(policy)
		if policy == nil then
			self.gate_policy = nil
			return
		end
		self.gate_policy = {
			max = policy.max,
			pending = policy.pending,
			overflow = policy.overflow,
			source = policy.source,
			target = policy.target,
		}
	end

	function control:ensure_prepared(_context)
		if self.state.value == "new" then
			self:_transition("prepared", "ensure_prepared")
		elseif self.state.value == "draining" and self.stop_requested == false then
			self:_transition("prepared", "resume_prepared")
		end

		self:_sync_gauges()
		return self.state.promise.prepared
	end

	function control:can_accept_new()
		if self.state.value == "stopped" then
			return false
		end
		return self.state.accept_new == true
	end

	function control:can_dispatch_pending()
		if self:can_accept_new() then
			return true
		end
		if not self.stop_requested then
			return false
		end
		return self.state.stop.pending == "drain"
	end

	function control:_emit_running(run)
		self.metric.counter.running = self.metric.counter.running + 1
		if self.state.value ~= "running" then
			self:_transition("running", "on_state_running")
		end

		for _, hook in ipairs(self.segment.on_state_running) do
			pcall(hook, {
				run = run,
				segment = self.segment,
				line = self.line,
				pos = self.pos,
				control = self,
			})
		end
	end

	function control:_emit_settle(run, outcome)
		for _, hook in ipairs(self.segment.on_settle) do
			pcall(hook, {
				run = run,
				outcome = outcome,
				segment = self.segment,
				line = self.line,
				pos = self.pos,
				control = self,
			})
		end
	end

	function control:_complete_when_stopped()
		if not self.stop_requested then
			return
		end

		if self.pending ~= 0 or self.inflight ~= 0 then
			return
		end

		complete_future_once(self.drained, {
			drained = true,
			segment = self.segment,
			line = self.line,
			pos = self.pos,
		})

		for _, stopped in pairs(self.components) do
			if stopped ~= true then
				return
			end
		end

		self:_transition("stopped", "all_components_stopped")
		complete_future_once(self.stopped, {
			stopped = true,
			segment = self.segment,
			line = self.line,
			pos = self.pos,
		})
	end

	function control:_reject_run(run, code, message, stage)
		self.metric.counter.dropped = self.metric.counter.dropped + 1
		if type(run) ~= "table" or type(run.clone) ~= "function" then
			return
		end

		local rejected = run:clone(run.input)
		rejected.pos = run.pos
		rejected.input = errors.add(rejected.input, {
			stage = stage or "segment",
			code = code,
			message = message,
			segment_type = self.segment and self.segment.type,
			segment_id = self.segment and self.segment.id,
		})
		rejected:next()
	end

	function control:_admit_run(run, opts)
		opts = opts or {}
		self.metric.counter.admitted = self.metric.counter.admitted + 1
		self.metric.gauge.inflight = self.metric.gauge.inflight + 1
		self:_sync_gauges()

		self.admitted[run] = {
			bound = false,
			admitted_at = now_ns(),
		}

		run._pipe_line_admitted = {
			control = self,
			pos = run.pos,
		}

		if opts.queue_wait_ns ~= nil then
			self:_record_timing("queue_wait", opts.queue_wait_ns)
		end
	end

	function control:bind_async_run(run)
		local entry = self.admitted[run]
		if type(entry) ~= "table" or entry.bound == true then
			return
		end

		local ok = pcall(function()
			run:on_settle(function(outcome)
				self:release_run(run, outcome)
			end)
		end)
		if ok then
			entry.bound = true
			return
		end

		self:release_run(run, {
			status = "error",
			error = {
				code = "segment_async_bind",
				message = "failed to bind on_settle callback",
			},
		})
	end

	function control:release_run(run, outcome)
		local entry = self.admitted[run]
		if type(entry) ~= "table" then
			return
		end

		self.admitted[run] = nil
		if type(run) == "table" and type(run._pipe_line_admitted) == "table" and run._pipe_line_admitted.control == self then
			run._pipe_line_admitted = nil
		end

		self.metric.gauge.inflight = self.metric.gauge.inflight - 1
		if self.metric.gauge.inflight < 0 then
			self.metric.gauge.inflight = 0
		end
		self:_sync_gauges()

		if type(outcome) == "table" and outcome.status == "error" then
			self.metric.counter.settled_error = self.metric.counter.settled_error + 1
		else
			self.metric.counter.settled_ok = self.metric.counter.settled_ok + 1
		end

		if outcome ~= nil then
			self:_emit_settle(run, outcome)
		end

		self:pump_pending()
		self:_complete_when_stopped()
	end

	function control:track_pending(delta)
		self.metric.gauge.pending = self.metric.gauge.pending + (delta or 0)
		if self.metric.gauge.pending < 0 then
			self.metric.gauge.pending = 0
		end
		self:_sync_gauges()
		self:_complete_when_stopped()
	end

	function control:mark_admitted(run)
		self:_admit_run(run)
		self:bind_async_run(run)
	end

	function control:_queue_run(source_run)
		if type(source_run) ~= "table" or type(source_run.clone) ~= "function" then
			return false
		end

		local queued = source_run:clone(source_run.input)
		queued.pos = source_run.pos
		table.insert(self.pending_queue, {
			run = queued,
			enqueued_at = now_ns(),
		})

		self.metric.counter.queued = self.metric.counter.queued + 1
		self:track_pending(1)
		return true
	end

	function control:admit_or_queue(run)
		self:ensure_prepared()
		self:_emit_running(run)

		if not self:can_accept_new() then
			self:_reject_run(run, "segment_not_accepting", "segment is not accepting new runs", "segment")
			return false
		end

		local policy = self:_resolve_gate_policy(run)
		if policy.max == nil or self.inflight < policy.max then
			self:_admit_run(run)
			return true
		end

		local pending_limit = policy.pending
		if pending_limit == nil or self.pending < pending_limit then
			self:_queue_run(run)
			return false
		end

		if policy.overflow == "drop_oldest" then
			local oldest = table.remove(self.pending_queue, 1)
			if type(oldest) == "table" and type(oldest.run) == "table" then
				self:track_pending(-1)
				self:_reject_run(oldest.run, "segment_overflow_drop_oldest", "dropped by overflow policy", "gate")
			end
			self:_queue_run(run)
			return false
		end

		if policy.overflow == "drop_newest" then
			self:_reject_run(run, "segment_overflow_drop_newest", "dropped by overflow policy", "gate")
			return false
		end

		self:_reject_run(run, "segment_overflow", "segment pending queue is full", "gate")
		return false
	end

	function control:pump_pending()
		while #self.pending_queue > 0 do
			if not self:can_dispatch_pending() then
				break
			end

			local head = self.pending_queue[1]
			if type(head) ~= "table" or type(head.run) ~= "table" then
				table.remove(self.pending_queue, 1)
				self:track_pending(-1)
			else
				local policy = self:_resolve_gate_policy(head.run)
				if policy.max ~= nil and self.inflight >= policy.max then
					break
				end

				table.remove(self.pending_queue, 1)
				self:track_pending(-1)

				if self.stop_requested and self.state.stop.pending == "drop" then
					self:_reject_run(head.run, "segment_pending_drop", "pending run dropped during stop", "segment")
				else
					local wait_ns = now_ns() - (head.enqueued_at or now_ns())
					self:_admit_run(head.run, { queue_wait_ns = wait_ns })
					head.run:execute()

					if rawget(head.run, "_async") ~= nil then
						self:bind_async_run(head.run)
					else
						self:release_run(head.run, { status = "ok", value = head.run.input })
					end
				end
			end
		end
	end

	function control:register_component(component)
		if type(component) ~= "table" then
			return
		end
		if self.components[component] == nil then
			self.components[component] = false
		end
	end

	function control:mark_component_stopped(component)
		if type(component) ~= "table" then
			return
		end
		self.components[component] = true
		self:_complete_when_stopped()
	end

	function control:on_drained(callback)
		if type(callback) ~= "function" then
			return
		end
		if future_done(self.drained) then
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

	function control:is_stop_immediate()
		return self.stop_requested
			and self.state.stop.pending == "drop"
			and self.state.stop.inflight == "cancel"
			and self.state.accept_new == false
	end

	function control:request_stop(context_or_type)
		local stop = resolve_stop_controls(self.segment, self.line, context_or_type)
		self.state.stop = stop
		self.state.accept_new = stop.accept_new == true
		self.stop_requested = true

		if self.state.value ~= "stopped" then
			self:_transition("draining", "request_stop", stop)
		end

		if stop.pending == "drop" then
			while #self.pending_queue > 0 do
				local entry = table.remove(self.pending_queue, 1)
				self:track_pending(-1)
				if type(entry) == "table" and type(entry.run) == "table" then
					self:_reject_run(entry.run, "segment_stop_drop_pending", "dropped pending run during stop", "segment")
				end
			end
		end

		if stop.inflight == "cancel" then
			local active = {}
			for run in pairs(self.admitted) do
				table.insert(active, run)
			end
			for _, run in ipairs(active) do
				pcall(function()
					run:settle({
						status = "error",
						error = {
							code = "segment_stop_cancel_inflight",
							message = "inflight run cancelled during stop",
						},
					})
				end)
			end
		end

		self:pump_pending()
		self:_complete_when_stopped()
		return self.stopped
	end

	control:_sync_gauges()
	return control
end

setmetatable(M, {
	__call = function(_, config)
		return M.new(config)
	end,
})

return M
