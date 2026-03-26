local define = require("pipe-line.segment.define")

local M = {}

M.module_filter = define.define({
	type = "module_filter",
	wants = {},
	emits = {},
	handler = function(run)
		local input = run.input
		local filter = run.filter or (run.line and run.line.filter)

		if not filter then
			return input
		end

		local source = type(input) == "table" and input.source or nil
		if not source then
			return input
		end

		if type(filter) == "function" then
			if filter(source, input, run) then
				return input
			end
			return false
		end

		if type(filter) == "string" then
			if string.match(source, filter) then
				return input
			end
			return false
		end

		return input
	end,
})

return M
