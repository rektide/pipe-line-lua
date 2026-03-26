local define = require("pipe-line.segment.define")

local M = {}

M.timestamper = define.define({
	type = "timestamper",
	wants = {},
	emits = { "time" },
	handler = function(run)
		local input = run.input
		if type(input) == "table" then
			if not input.time then
				input.time = vim.uv.hrtime()
			end
		end
		return input
	end,
})

return M
