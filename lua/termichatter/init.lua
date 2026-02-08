--- termichatter: Asynchronous structured-data-flow atop coop.nvim
--- Attaches registry to pipeline
local M = {}

local pipeline = require("termichatter.pipeline")
local registry = require("termichatter.registry")

-- Import modules so they register themselves
require("termichatter.processors")
require("termichatter.consumer")
require("termichatter.outputters")

-- Start with pipeline as base (log methods inherited via __index)
setmetatable(M, { __index = pipeline })

-- Attach registry
M.registry = registry

return M
