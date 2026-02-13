local M = {}

local pipeline = require("termichatter.pipeline")
local consumer = require("termichatter.consumer")

setmetatable(M, { __index = pipeline })

M.consumer = consumer

return M
