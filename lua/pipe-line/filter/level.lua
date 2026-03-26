local define = require("pipe-line.segment.define")
local logutil = require("pipe-line.log")

local M = {}

M.level_filter = define.define({
	type = "level_filter",
	wants = {},
	emits = {},
	handler = function(run)
		local input = run.input
		local maxLevel = logutil.resolve_level(
			run.max_level or (run.line and run.line.max_level),
			math.huge,
			"max_level"
		)

		if type(input) ~= "table" then
			return input
		end

		local level = logutil.resolve_level(input.level, math.huge, "payload level")
		if level <= maxLevel then
			return input
		end

		return false
	end,
})

return M
