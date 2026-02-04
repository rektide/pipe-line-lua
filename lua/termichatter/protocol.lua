--- Completion protocol messages for async pipeline coordination
local M = {}

M.hello = { type = "termichatter.completion.hello" }
M.done = { type = "termichatter.completion.done" }

return M
