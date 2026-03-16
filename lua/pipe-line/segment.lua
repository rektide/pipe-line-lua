--- Standard segment library for pipe-line
--- Common processing segment for pipeline
local M = {}
local logutil = require("pipe-line.log")
local completion = require("pipe-line.segment.completion")
local define = require("pipe-line.segment.define")

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

M.completion = completion.build_segment(M.define)

return M
