local M = {}

local coop = require("coop")

local function resolve_handler(pipeline, stage)
	local handler = stage.handler
	if type(handler) == "string" then
		handler = pipeline[handler]
	end
	if type(handler) ~= "function" then
		return nil
	end
	return handler
end

local function run_stage(pipeline, stage_index, msg)
	local stage = pipeline.pipeline[stage_index]
	if not stage then
		return msg
	end

	local handler = resolve_handler(pipeline, stage)
	if not handler then
		return msg
	end

	return handler(msg, pipeline, stage)
end

function M.make_stage_consumer(pipeline, stage_index, queue)
	return function()
		while true do
			local msg = queue:pop()
			if not msg then
				break
			end

			local result = run_stage(pipeline, stage_index, msg)
			if result then
				pipeline:_run_from(result, stage_index + 1)
			end
		end
	end
end

function M.start_pipeline_consumers(pipeline)
	pipeline._consumer_tasks = pipeline._consumer_tasks or {}

	for stage_index, stage in ipairs(pipeline.pipeline or {}) do
		if stage._queue then
			local task = coop.spawn(M.make_stage_consumer(pipeline, stage_index, stage._queue))
			table.insert(pipeline._consumer_tasks, task)
		end
	end

	return pipeline._consumer_tasks
end

function M.stop_pipeline_consumers(pipeline)
	if not pipeline._consumer_tasks then
		return
	end

	for _, task in ipairs(pipeline._consumer_tasks) do
		task:cancel()
	end

	pipeline._consumer_tasks = {}
end

return M
