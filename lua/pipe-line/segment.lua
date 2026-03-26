local M = {}
local define = require("pipe-line.segment.define")
local completion = require("pipe-line.segment.completion")
local enrich = require("pipe-line.enrich")
local filter = require("pipe-line.filter")
local gate = require("pipe-line.async.gate")

M.define = define.define

M.timestamper = enrich.timestamper
M.cloudevent = enrich.cloudevent
M.module_filter = filter.module_filter
M.level_filter = filter.level_filter
M.gate = gate.gate

M.ingester = M.define({
	type = "ingester",
	wants = {},
	emits = {},
	handler = function(run)
		local input = run.input
		local ingest = run.ingest or (run.line and run.line.ingest)

		if type(ingest) == "function" then
			return ingest(input, run)
		end

		return input
	end,
})

M.completion = completion.build_segment(M.define)

return M
