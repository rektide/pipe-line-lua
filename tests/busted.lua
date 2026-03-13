#!/usr/bin/env -S nvim -l

-- Add coop.nvim to runtime path and package.path
local cwd = vim.fn.getcwd()
vim.opt.runtimepath:prepend(cwd)

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
	local candidates = coop_candidates()

	for _, path in ipairs(candidates) do
		if has_coop(path) then
			return path
		end
	end

	error("could not find coop.nvim checkout; set TERMICHATTER_COOP_PATHS to a ':' or ';' separated list")
end

local coop_root = find_coop_root()
vim.opt.runtimepath:prepend(coop_root)

local impl = vim.env.TERMICHATTER_IMPL or "default"
local impl_lua_root = cwd .. "/implementations/" .. impl .. "/lua"
local impl_init = impl_lua_root .. "/pipe-line/init.lua"
if impl ~= "default" and vim.fn.filereadable(impl_init) == 1 then
	vim.opt.runtimepath:prepend(cwd .. "/implementations/" .. impl)
	package.path = impl_lua_root .. "/?.lua;" .. package.path
	package.path = impl_lua_root .. "/?/init.lua;" .. package.path
end

-- Add to package.path for require() to work
package.path = coop_root .. "/lua/?.lua;" .. package.path
package.path = coop_root .. "/lua/?/init.lua;" .. package.path
package.path = cwd .. "/lua/?.lua;" .. package.path
package.path = cwd .. "/lua/?/init.lua;" .. package.path

vim.env.LAZY_STDPATH = ".tests"
load(vim.fn.system("curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua"))()

require("lazy.minit").busted({
	spec = {
		{ "https://github.com/lunarmodules/luacov" },
	},
})

-- Trigger luacov to generate the coverage report
local luacov_success, runner = pcall(require, "luacov.runner")
if luacov_success and runner.initialized then
	runner.shutdown()
end
