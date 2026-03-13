--- Protocol helpers for control runs.
local completion = require("pipe-line.segment.completion")

local M = {}

M.completion = completion
M.is_protocol = completion.is_protocol

return M
