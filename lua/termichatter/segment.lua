--- Standard segment library for termichatter
--- Common processing segment for pipeline
local M = {}
local MpscQueue = require("coop.mpsc-queue").MpscQueue
local util = require("termichatter.util")
local logutil = require("termichatter.log")
local protocol = require("termichatter.protocol")

M.HANDOFF_FIELD = "__termichatter_handoff_run"

--- Define a segment with default protocol behavior.
--- By default protocol runs pass through and are not processed.
---@param spec table
---@return table segment
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

function M.mpsc_handoff_factory()
	return {
		type = "segment_factory",
		create = function()
			return M.mpsc_handoff()
		end,
	}
end

--- Timestamper segment: add hrtime timestamp
M.timestamper = M.define({
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
		input.type = input.type or "termichatter.log"

		return input
	end,
})

--- Module filter segment: filter by source pattern
--- Returns false to stop pipeline, input to continue
M.module_filter = M.define({
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

--- Completion segment: track mpsc completion protocol on the line.
M.completion = M.define({
	type = "completion",
	process_protocol = true,
	wants = {},
	emits = {},
	ensure_prepared = function(self, context)
		local line = context and context.line
		if not line then
			return
		end

		if type(line.done) ~= "table" or type(line.done.resolve) ~= "function" then
			line.done = protocol.create_deferred()
		end

		if type(line._completion_state) ~= "table" then
			line._completion_state = protocol.create_completion_state()
		end
	end,
	handler = function(run)
		if not protocol.is_completion_protocol(run) then
			return run.input
		end

		local line = run.line
		if not line then
			return run.input
		end

		local state = line._completion_state
		if not state then
			state = protocol.create_completion_state()
			line._completion_state = state
		end

		local status = protocol.query_completion(state, run)
		if not status then
			return run.input
		end

		if not state.resolved and status.settled and type(line.done) == "table" then
			state.resolved = true
			line.done:resolve({
				hello = status.hello,
				done = status.done,
				signal = status.signal,
			})
		end

		return nil
	end,
})

--- mpsc_handoff segment factory: enqueue continuation run and stop current run
---@param config? table { queue?: table, strategy?: 'self'|'clone'|'fork' }
---@return table segment
function M.mpsc_handoff(config)
	config = config or {}
	local queue = config.queue or MpscQueue.new()
	local handoff = {
		type = "mpsc_handoff",
		queue = queue,
		strategy = config.strategy or "self",
		wants = {},
		emits = {},
		ensure_prepared = function(self, context)
			local line = context and context.line
			if not line then
				return
			end
			if context.force ~= true and line.autoStartConsumers == false then
				return
			end
			require("termichatter.consumer").ensure_queue_consumer(line, self.queue)
		end,
		ensure_stopped = function(self, context)
			local line = context and context.line
			if not line then
				return
			end
			require("termichatter.consumer").stop_queue_consumer(line, self.queue)
		end,
	}

	handoff.handler = function(run)
		local continuation = util.continuation_for_strategy(run, handoff.strategy, run.input, "mpsc_handoff")
		queue:push({ [M.HANDOFF_FIELD] = continuation })
		return false
	end

	return handoff
end

---@param seg any
---@return boolean
function M.is_mpsc_handoff(seg)
	return type(seg) == "table"
		and seg.type == "mpsc_handoff"
		and seg.queue ~= nil
		and type(seg.queue.push) == "function"
		and type(seg.queue.pop) == "function"
end

return M
