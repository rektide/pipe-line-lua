--- Consumer: async driver for mpsc_handoff segment
--- Drives explicit queue boundary segments in a line
local coop = require("coop")
local protocol = require("termichatter.protocol")
local segment = require("termichatter.segment")

local M = {}

local function is_task_active(task)
	if not task then
		return false
	end
	if type(task.status) == "function" then
		return task:status() ~= "dead"
	end
	return true
end

--- Create a consumer for a single mpsc queue
---@param queue table The MpscQueue to consume from
---@return function consumer The consumer coroutine function
function M.make_consumer(queue)
	return function()
		while true do
			local msg = queue:pop()
			if not msg then
				break
			end

			if protocol.isShutdown(msg) then
				break
			end

			if protocol.isCompletion(msg) then
				-- ignore completion signals on internal handoff queue
			else
				if type(msg) == "table" and msg[segment.HANDOFF_FIELD] then
					local continuation = msg[segment.HANDOFF_FIELD]
					if type(continuation) ~= "table" or type(continuation.next) ~= "function" then
						error("invalid mpsc_handoff continuation payload", 0)
					end
					continuation:next()
				else
					error("invalid mpsc queue payload; expected handoff continuation or protocol signal", 0)
				end
			end
		end
	end
end

local function queue_for_segment(line, pos)
	local seg = line.pipe[pos]
	local resolved = line:resolve_segment(seg)
	if segment.is_factory(resolved) then
		local created = resolved.create()
		line.pipe[pos] = created
		resolved = created
	end
	if segment.is_mpsc_handoff(resolved) then
		return resolved.queue
	end
	return nil
end

--- Start consumer for all explicit async queue boundaries in a line
---@param line table The line to start consumer for
---@return table[] task Array of spawned task
function M.start_consumer(line)
	line._consumer_task = line._consumer_task or {}
	line._consumer_task_by_queue = line._consumer_task_by_queue or {}

	local seen_queue = {}
	for i = 1, #line.pipe do
		local queue = queue_for_segment(line, i)
		if queue and not seen_queue[queue] then
			seen_queue[queue] = true
			local existing_task = line._consumer_task_by_queue[queue]
			if not is_task_active(existing_task) then
				local consumer_fn = M.make_consumer(queue)
				local task = coop.spawn(consumer_fn)
				line._consumer_task_by_queue[queue] = task
				table.insert(line._consumer_task, task)
			end
		end
	end

	local active_task_list = {}
	for queue, task in pairs(line._consumer_task_by_queue) do
		if not seen_queue[queue] then
			if is_task_active(task) then
				task:cancel()
			end
			line._consumer_task_by_queue[queue] = nil
		elseif is_task_active(task) then
			table.insert(active_task_list, task)
		else
			line._consumer_task_by_queue[queue] = nil
		end
	end
	line._consumer_task = active_task_list

	return line._consumer_task
end

--- Stop all consumer for a line
---@param line table The line to stop consumer for
function M.stop_consumer(line)
	if not line._consumer_task then
		return
	end

	for _, task in ipairs(line._consumer_task) do
		if is_task_active(task) then
			task:cancel()
		end
	end

	line._consumer_task = {}
	line._consumer_task_by_queue = {}
end

return M
