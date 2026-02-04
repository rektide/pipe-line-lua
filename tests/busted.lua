#!/usr/bin/env -S nvim -l

-- Add coop.nvim to runtime path and package.path
local cwd = vim.fn.getcwd()
vim.opt.runtimepath:prepend(cwd .. "/.test-agent/coop")
vim.opt.runtimepath:prepend(cwd)

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
