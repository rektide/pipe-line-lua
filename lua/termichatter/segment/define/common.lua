local util = require("termichatter.util")

local M = {}

function M.copy_spec(spec)
	spec = spec or {}
	local out = {}
	for k, v in pairs(spec) do
		out[k] = v
	end
	return out
end

function M.is_task_active(runner)
	if type(runner) ~= "table" or type(runner.status) ~= "function" then
		return false
	end
	return runner:status() ~= "dead"
end

function M.append_awaitable(list, awaited)
	if awaited == nil then
		return
	end

	if type(awaited) == "table" and type(awaited.await) == "function" then
		table.insert(list, awaited)
		return
	end

	if type(awaited) == "table" then
		for _, item in ipairs(awaited) do
			M.append_awaitable(list, item)
		end
	end
end

function M.compact_awaitables(list)
	if #list == 0 then
		return nil
	end
	if #list == 1 then
		return list[1]
	end
	return list
end

function M.stop_result_or_false(segment)
	if segment.stop_result ~= nil then
		return segment.stop_result
	end
	return false
end

function M.prepare_continuation(segment, run, wrapped_handler)
	local result = wrapped_handler(run)
	if result == false then
		return nil, false
	end

	if result ~= nil then
		run.input = result
	end

	local continuation
	if type(segment.continuation_for_run) == "function" then
		continuation = segment.continuation_for_run(run, segment)
	else
		continuation = util.continuation_for_strategy(
			run,
			segment.strategy,
			run.input,
			segment.continuation_owner or segment.type
		)
	end

	run.continuation = continuation

	return continuation, true
end

return M
