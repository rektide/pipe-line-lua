--- Consumer: async driver for mpsc pipe
--- Drive async stage in a line
local coop = require("coop")

local M = {}

--- Create a consumer for a single mpsc stage
---@param line table The line with the pipeline
---@param pos number Position of the async stage
---@param queue table The MpscQueue to consume from
---@return function consumer The consumer coroutine function
function M.make_consumer(line, pos, queue)
	local Run = require("termichatter.run")

	return function()
		while true do
			local msg = queue:pop()
			if not msg then
				break
			end

			local pipe = line.pipe[pos]
			if pipe then
				local run = Run.new(line, {
					noStart = true,
					input = msg,
				})
				run.pos = pos
				run.current = pipe
				run:exec()

				if run.input ~= nil then
					run:next()
					if run.pos <= #run.pipe then
						run:execute()
					elseif run.output or (run.line and run.line.output) then
						local output = run.output or run.line.output
						output:push(run.input)
					end
				end
			end
		end
	end
end

--- Start consumer for all async stage in a line
---@param line table The line to start consumer for
---@return table[] task Array of spawned task
function M.start_consumer(line)
	line._consumer_task = line._consumer_task or {}

	for pos, queue in pairs(line.mpsc or {}) do
		if queue and type(queue.pop) == "function" then
			local consumer = M.make_consumer(line, pos, queue)
			local task = coop.spawn(consumer)
			table.insert(line._consumer_task, task)
		end
	end

	return line._consumer_task
end

--- Stop all consumer for a line
---@param line table The line to stop consumer for
function M.stop_consumer(line)
	if not line._consumer_task then
		return
	end

	for _, task in ipairs(line._consumer_task) do
		task:cancel()
	end

	line._consumer_task = {}
end

return M
