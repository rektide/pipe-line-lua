local cwd = vim.fn.getcwd()
local debug_enabled = vim.env.TERMICHATTER_BENCH_DEBUG == "1"

local function debug_log(...)
	if not debug_enabled then
		return
	end
	local parts = { ... }
	for i, value in ipairs(parts) do
		parts[i] = tostring(value)
	end
	io.stderr:write(table.concat(parts, " ") .. "\n")
end

local function has_coop(path)
	if vim.fn.isdirectory(path) ~= 1 then
		return false
	end
	if vim.fn.isdirectory(path .. "/lua") ~= 1 then
		return false
	end
	if vim.fn.filereadable(path .. "/lua/coop.lua") == 1 then
		return true
	end
	return vim.fn.filereadable(path .. "/lua/coop/init.lua") == 1
end

local function split_paths(value)
	local out = {}
	for item in string.gmatch(value, "[^:;]+") do
		table.insert(out, vim.fn.expand(vim.trim(item)))
	end
	return out
end

local function coop_candidates()
	local from_env = vim.env.TERMICHATTER_COOP_PATHS
	if from_env and from_env ~= "" then
		return split_paths(from_env)
	end

	return {
		cwd .. "/.test-agent/coop",
		vim.fn.expand("~/archive/gregorias/coop.nvim"),
		vim.fn.expand("~/src/coop.nvim"),
	}
end

local function find_coop_root()
	for _, path in ipairs(coop_candidates()) do
		if has_coop(path) then
			return path
		end
	end

	error("could not find coop.nvim checkout; set TERMICHATTER_COOP_PATHS")
end

local function setup_paths()
	local coop_root = find_coop_root()
	local impl = vim.env.TERMICHATTER_IMPL or "default"
	local impl_lua_root = cwd .. "/implementations/" .. impl .. "/lua"
	local impl_init = impl_lua_root .. "/termichatter/init.lua"
	local has_impl = impl ~= "default" and vim.fn.filereadable(impl_init) == 1

	if has_impl then
		vim.opt.runtimepath:prepend(cwd .. "/implementations/" .. impl)
	end

	vim.opt.runtimepath:prepend(cwd)
	vim.opt.runtimepath:prepend(coop_root)
	if has_impl then
		vim.opt.runtimepath:prepend(cwd .. "/implementations/" .. impl)
	end

	package.path = coop_root .. "/lua/?.lua;" .. package.path
	package.path = coop_root .. "/lua/?/init.lua;" .. package.path
	package.path = cwd .. "/lua/?.lua;" .. package.path
	package.path = cwd .. "/lua/?/init.lua;" .. package.path

	if has_impl then
		package.path = impl_lua_root .. "/?.lua;" .. package.path
		package.path = impl_lua_root .. "/?/init.lua;" .. package.path
	end
end

local function run_workload()
	setup_paths()

	local termichatter = require("termichatter")
	local MpscQueue = require("coop.mpsc-queue").MpscQueue
	debug_log("impl", vim.env.TERMICHATTER_IMPL or "default")
	debug_log("log source", debug.getinfo(termichatter.log).source)

	local stage_queue = MpscQueue.new()
	local count = tonumber(vim.env.TERMICHATTER_BENCH_COUNT or "600")

	local module = termichatter:new({
		pipeline = {
			{
				handler = function(msg)
					msg.score = msg.score + 1
					return msg
				end,
			},
			{
				queue = stage_queue,
			},
			{
				handler = function(msg)
					msg.score = msg.score + 1
					return msg
				end,
			},
		},
	})

	for i = 1, count do
		module:log({ id = i, score = 0 })
	end

	debug_log("stage queue empty after log", tostring(stage_queue:empty()))

	while not stage_queue:empty() do
		local msg = stage_queue:pop()
		if msg then
			msg.pipeStep = (msg.pipeStep or 1) + 1
			module:log(msg)
		end
	end

	local total = 0
	local seen = 0
	while not module.outputQueue:empty() do
		local msg = module.outputQueue:pop()
		if msg then
			seen = seen + 1
			total = total + msg.score
		end
	end

	if seen ~= count then
		error("unexpected output count: " .. tostring(seen))
	end

	debug_log("seen", tostring(seen), "total", tostring(total))

	if total ~= (count * 2) then
		error("unexpected total score: " .. tostring(total))
	end

	if type(module.stopConsumers) == "function" then
		module:stopConsumers()
	end
end

run_workload()
