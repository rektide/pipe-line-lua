--- termichatter: structured data-flow pipeline
--- Thin entry point: registers built-in segment, exports modules
local Line = require("pipe-line.line")
local Pipe = require("pipe-line.pipe")
local Run = require("pipe-line.run")
local registry = require("pipe-line.registry")
local segment = require("pipe-line.segment")
local consumer = require("pipe-line.consumer")
local outputter = require("pipe-line.outputter")
local driver = require("pipe-line.driver")
local protocol = require("pipe-line.protocol")
local resolver = require("pipe-line.resolver")
local inherit = require("pipe-line.inherit")
local log = require("pipe-line.log")

local M = {}

-- Export modules
M.Line = Line
M.Pipe = Pipe
M.Run = Run
M.registry = registry
M.segment = segment
M.consumer = consumer
M.outputter = outputter
M.driver = driver
M.protocol = protocol
M.Future = Future
M.resolver = resolver
M.inherit = inherit
M.log = log
M.level = log.level
M.set_default_level = log.set_default_level
M.get_default_level = log.get_default_level

-- Register built-in segment
registry:register("timestamper", segment.timestamper)
registry:register("cloudevent", segment.cloudevent)
registry:register("module_filter", segment.module_filter)
registry:register("level_filter", segment.level_filter)
registry:register("ingester", segment.ingester)
registry:register("completion", segment.completion)
registry:register("mpsc_handoff", segment.mpsc_handoff_factory())
registry:register("lattice_resolver", {
	wants = {},
	emits = {},
	handler = resolver.lattice_resolver,
})

-- Module is callable: termichatter(config) creates a Line
setmetatable(M, {
	__call = function(_, config)
		config = config or {}
		config.registry = config.registry or registry
		return Line(config)
	end,
})

return M
