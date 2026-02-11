#!/usr/bin/env -S nvim -l

-- Add coop.nvim to runtime path and package.path
local cwd = vim.fn.getcwd()
vim.opt.runtimepath:prepend(cwd .. "/.test-agent/coop")
vim.opt.runtimepath:prepend(cwd)

local impl = vim.env.TERMICHATTER_IMPL or "default"
local impl_lua_root = cwd .. "/implementations/" .. impl .. "/lua"
local impl_init = impl_lua_root .. "/termichatter/init.lua"
if impl ~= "default" and vim.fn.filereadable(impl_init) == 1 then
	vim.opt.runtimepath:prepend(cwd .. "/implementations/" .. impl)
	package.path = impl_lua_root .. "/?.lua;" .. package.path
	package.path = impl_lua_root .. "/?/init.lua;" .. package.path
end

-- Add to package.path for require() to work
package.path = cwd .. "/.test-agent/coop/lua/?.lua;" .. package.path
package.path = cwd .. "/.test-agent/coop/lua/?/init.lua;" .. package.path
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
