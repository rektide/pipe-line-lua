local define = require("pipe-line.segment.define")
local errors = require("pipe-line.errors")

local M = {}

local function resolve_gate_target(line, gate_pos, target)
	if target == nil or target == "next" then
		return gate_pos + 1, nil
	end

	if type(target) == "number" then
		if target < 1 or target ~= math.floor(target) then
			return nil, "gate target number must be positive integer offset"
		end
		return gate_pos + target, nil
	end

	if type(target) == "string" then
		for pos = 1, #line.pipe do
			local seg = line:resolve_pipe_segment(pos, true)
			if type(seg) == "table" and seg.id == target then
				return pos, nil
			end
		end
		return nil, "gate target segment id not found: " .. target
	end

	return nil, "gate target must be 'next', positive integer offset, or segment id"
end

M.gate = define.define({
	type = "gate",
	wants = {},
	emits = {},

	init = function(self, context)
		self.target = self.target or "next"
		self.gate_inflight_overflow = self.gate_inflight_overflow or "error"
		self._gate_target_pos = nil
		self._gate_target_error = nil
		self._gate_target_segment = nil
		self._gate_target_control = nil
	end,

	ensure_prepared = function(self, context)
		local line = context.line
		local gate_pos = context.pos

		local target_pos, target_err = resolve_gate_target(line, gate_pos, self.target)
		self._gate_target_pos = target_pos
		self._gate_target_error = target_err

		if target_pos == nil then
			self.metric = type(self.metric) == "table" and self.metric or {}
			self.metric.counter = type(self.metric.counter) == "table" and self.metric.counter or {}
			self.metric.counter.target_resolve_error = (self.metric.counter.target_resolve_error or 0) + 1
			return nil
		end

		if target_pos < 1 or target_pos > #line.pipe then
			self.metric = type(self.metric) == "table" and self.metric or {}
			self.metric.counter = type(self.metric.counter) == "table" and self.metric.counter or {}
			self.metric.counter.target_out_of_range = (self.metric.counter.target_out_of_range or 0) + 1
			self._gate_target_segment = nil
			self._gate_target_control = nil
			return nil
		end

		local target_segment = line:resolve_pipe_segment(target_pos, true)
		local target_control = line:resolve_segment_control(target_pos, target_segment)
		self._gate_target_segment = target_segment
		self._gate_target_control = target_control

		if type(target_control) == "table" and type(target_control.set_gate_policy) == "function" then
			target_control:set_gate_policy({
				source = self.id or self.type,
				target = self.target,
				max = self.gate_inflight_max,
				pending = self.gate_inflight_pending,
				overflow = self.gate_inflight_overflow,
			})
		end

		return nil
	end,

	handler = function(run)
		local seg = run.segment
		if type(seg) == "table" and type(seg._gate_target_error) == "string" then
			run.input = errors.add(run.input, {
				stage = "gate",
				code = "gate_target_resolve",
				message = seg._gate_target_error,
				segment_type = seg.type,
				segment_id = seg.id,
			})
		end
		return run.input
	end,
})

return M
