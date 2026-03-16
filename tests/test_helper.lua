local M = {}

local buffers = {}
local next_buf = 1

local function simple_inspect(value)
	if type(value) ~= "table" then
		return tostring(value)
	end
	local parts = {}
	for k, v in pairs(value) do
		table.insert(parts, tostring(k) .. "=" .. tostring(v))
	end
	table.sort(parts)
	return "{" .. table.concat(parts, ",") .. "}"
end

function M.setup_vim()
	if type(_G.vim) == "table" and _G.vim.__pipe_line_test_stub == true then
		return
	end

	local ok_dkjson, dkjson = pcall(require, "dkjson")

	_G.vim = {
		__pipe_line_test_stub = true,
		uv = {
			hrtime = function()
				return math.floor(os.clock() * 1000000000)
			end,
			new_timer = function()
				local timer = {}
				function timer:start(_timeout, _repeat, cb)
					if type(cb) == "function" then
						cb()
					end
				end
				function timer:stop() end
				function timer:close() end
				return timer
			end,
		},
		api = {
			nvim_create_buf = function(_listed, _scratch)
				local bufnr = next_buf
				next_buf = next_buf + 1
				buffers[bufnr] = { name = nil, lines = {} }
				return bufnr
			end,
			nvim_buf_set_name = function(bufnr, name)
				if buffers[bufnr] then
					buffers[bufnr].name = name
				end
			end,
			nvim_buf_set_lines = function(bufnr, _start, _end, _strict, lines)
				if not buffers[bufnr] then
					return
				end
				for _, line in ipairs(lines or {}) do
					table.insert(buffers[bufnr].lines, line)
				end
			end,
		},
		schedule = function(fn)
			if type(fn) == "function" then
				return fn()
			end
		end,
		schedule_wrap = function(fn)
			return function(...)
				if type(fn) == "function" then
					return fn(...)
				end
			end
		end,
		defer_fn = function(fn, _ms)
			if type(fn) == "function" then
				fn()
			end
		end,
		inspect = simple_inspect,
		json = {
			encode = function(value)
				if ok_dkjson and dkjson and type(dkjson.encode) == "function" then
					return dkjson.encode(value)
				end
				return simple_inspect(value)
			end,
		},
		tbl_contains = function(list, needle)
			for _, item in ipairs(list or {}) do
				if item == needle then
					return true
				end
			end
			return false
		end,
		wait = function(timeout, condition, _interval)
			local deadline = os.clock() + ((timeout or 0) / 1000)
			while os.clock() <= deadline do
				if condition() then
					return true
				end
			end
			return condition()
		end,
	}
end

function M.reset_pipeline_modules()
	for name in pairs(package.loaded) do
		if name == "pipe-line" or string.match(name, "^pipe%-line%.") then
			package.loaded[name] = nil
		end
	end
end

function M.fresh_pipeline()
	M.setup_vim()
	M.reset_pipeline_modules()
	return require("pipe-line")
end

function M.wait_for(predicate, timeout_ms)
	timeout_ms = timeout_ms or 200
	local deadline = os.clock() + (timeout_ms / 1000)
	while os.clock() <= deadline do
		if predicate() then
			return true
		end
	end
	return predicate()
end

function M.pop_queue(queue, timeout, interval)
	local coop = require("coop")
	return coop.spawn(function()
		return queue:pop()
	end):await(timeout or 200, interval or 1)
end

return M
