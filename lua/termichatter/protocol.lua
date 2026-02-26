--- Protocol helpers for control runs.
local completion = require("termichatter.segment.completion")

local M = {}

M.completion = completion
M.is_protocol = completion.is_protocol

return M
