local define = require("pipe-line.segment.define")
local logutil = require("pipe-line.log")

local M = {}

M.cloudevent = define.define({
	type = "cloudevent",
	wants = {},
	emits = { "cloudevent" },
	handler = function(run)
		local input = run.input
		if type(input) ~= "table" then
			return input
		end

		if not input.id then
			local random = math.random
			input.id = string.format(
				"%08x-%04x-%04x-%04x-%012x",
				random(0, 0xffffffff),
				random(0, 0xffff),
				random(0x4000, 0x4fff),
				random(0x8000, 0xbfff),
				random(0, 0xffffffffffff)
			)
		end

		input.specversion = input.specversion or "1.0"
		input.source = input.source or run.source or (run.line and logutil.full_source(run.line))
		input.type = input.type or "pipe-line.log"

		return input
	end,
})

return M
