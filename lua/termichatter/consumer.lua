--- Consumer: async driver for mpsc segment
--- Drive async stage in a line
local coop = require("coop")
local protocol = require("termichatter.protocol")

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

			if protocol.isShutdown(msg) then
				local output = line.output
				if output then
					output:push(msg)
				end
				break
			end

			if protocol.isCompletion(msg) then
				local output = line.output
				if output then
					output:push(msg)
				end
			else
				local run = Run.new(line, {
					noStart = true,
					input = msg,
				})
				run.pos = pos
				local seg = run.pipe[pos]
				local handler = run:resolve(seg)
				if handler then
					local result = handler(run)
					if result == false then
						-- filtered
					elseif result ~= nil then
						run.input = result
						run:next()
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
			local consumer_fn = M.make_consumer(line, pos, queue)
			local task = coop.spawn(consumer_fn)
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
