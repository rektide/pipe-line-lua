--- Standard segment library for pipe-line
--- Common processing segment for pipeline
local M = {}
local logutil = require("pipe-line.log")
local errors = require("pipe-line.errors")
local completion = require("pipe-line.segment.completion")
local define = require("pipe-line.segment.define")

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

M.define = define.define

--- Timestamper segment: add hrtime timestamp
M.timestamper = M.define({
	type = "timestamper",
	wants = {},
	emits = { "time" },
	---@param run table The run context
	---@return any input Modified input
	handler = function(run)
		local input = run.input
		if type(input) == "table" then
			if not input.time then
				input.time = vim.uv.hrtime()
			end
		end
		return input
	end,
})

--- CloudEvent enricher segment: add id, source, type, specversion
M.cloudevent = M.define({
	type = "cloudevent",
	wants = {},
	emits = { "cloudevent" },
	---@param run table The run context
	---@return any input Modified input
	handler = function(run)
		local input = run.input
		if type(input) ~= "table" then
			return input
		end

		if not input.id then
			local random = math.random
			input.id = string.format(
				"%08x-%04x-%04x-%04x-%012x",
				random(0, 0xffffffff),
				random(0, 0xffff),
				random(0x4000, 0x4fff),
				random(0x8000, 0xbfff),
				random(0, 0xffffffffffff)
			)
		end

		input.specversion = input.specversion or "1.0"
		input.source = input.source or run.source or (run.line and logutil.full_source(run.line))
		input.type = input.type or "pipe-line.log"

		return input
	end,
})

--- Module filter segment: filter by source pattern
--- Returns false to stop pipeline, input to continue
M.module_filter = M.define({
	type = "module_filter",
	wants = {},
	emits = {},
	handler = function(run)
	local input = run.input
	local filter = run.filter or (run.line and run.line.filter)

	if not filter then
		return input
	end

	local source = type(input) == "table" and input.source or nil
	if not source then
		return input
	end

	if type(filter) == "function" then
		if filter(source, input, run) then
			return input
		end
		return false
	end

	if type(filter) == "string" then
		if string.match(source, filter) then
			return input
		end
		return false
	end

	return input
	end,
})

--- Level filter segment: filter by log level
--- Returns false to stop pipeline
M.level_filter = M.define({
	type = "level_filter",
	wants = {},
	emits = {},
	handler = function(run)
	local input = run.input
	local maxLevel = logutil.resolve_level(
		run.max_level or (run.line and run.line.max_level),
		math.huge,
		"max_level"
	)

	if type(input) ~= "table" then
		return input
	end

	local level = logutil.resolve_level(input.level, math.huge, "payload level")
	if level <= maxLevel then
		return input
	end

	return false
	end,
})

--- Ingester segment: apply custom decoration
M.ingester = M.define({
	type = "ingester",
	wants = {},
	emits = {},
	handler = function(run)
	local input = run.input
	local ingest = run.ingest or (run.line and run.line.ingest)

	if type(ingest) == "function" then
		return ingest(input, run)
	end

	return input
	end,
})

M.gate = M.define({
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

M.completion = completion.build_segment(M.define)

return M
