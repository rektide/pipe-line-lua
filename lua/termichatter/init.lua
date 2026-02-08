--- termichatter: Asynchronous structured-data-flow atop coop.nvim
--- Re-exports pipeline as the main module, adds extras

local pipeline = require("termichatter.pipeline")

-- Start with pipeline as base (log methods inherited via __index)
local M = setmetatable({}, { __index = pipeline })

-- Add extra modules
M.consumer = require("termichatter.consumer")
M.drivers = require("termichatter.drivers")
M.outputters = require("termichatter.outputters")
M.processors = require("termichatter.processors")

return M
