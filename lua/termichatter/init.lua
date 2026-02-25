--- termichatter: structured data-flow pipeline
--- Thin entry point: registers built-in segment, exports modules
local Line = require("termichatter.line")
local Pipe = require("termichatter.pipe")
local Run = require("termichatter.run")
local registry = require("termichatter.registry")
local segment = require("termichatter.segment")
local consumer = require("termichatter.consumer")
local outputter = require("termichatter.outputter")
local driver = require("termichatter.driver")
local protocol = require("termichatter.protocol")
local resolver = require("termichatter.resolver")
local inherit = require("termichatter.inherit")

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
M.drivers = driver
M.protocol = protocol
M.completion = protocol
M.resolver = resolver
M.inherit = inherit
M.priority = Line.priority

-- Register built-in segment
registry:register("timestamper", segment.timestamper)
registry:register("cloudevent", segment.cloudevent)
registry:register("cloudevents", segment.cloudevent)
registry:register("module_filter", segment.module_filter)
registry:register("priority_filter", segment.priority_filter)
registry:register("ingester", segment.ingester)
registry:register("lattice_resolver", {
	wants = {},
	emits = {},
	handler = resolver.lattice_resolver,
})

-- v1 compat: direct segment handler access
M.timestamper = function(msg)
	if type(msg) == "table" and msg.input then
		return segment.timestamper.handler(msg)
	end
	if type(msg) == "table" then
		if not msg.time then
			msg.time = vim.uv.hrtime()
		end
	end
	return msg
end

M.cloudevents = function(msg, ctx)
	if type(msg) == "table" and msg.type == "run" then
		return segment.cloudevent.handler(msg)
	end
	local input = msg
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
	input.source = input.source or (ctx and ctx.source)
	input.type = input.type or "termichatter.log"
	return input
end

M.module_filter = function(msg, ctx)
	if type(msg) == "table" and msg.type == "run" then
		return segment.module_filter.handler(msg)
	end
	local filter = ctx and ctx.filter
	if not filter then
		return msg
	end
	if type(filter) == "function" then
		if filter(msg) then
			return msg
		end
		return nil
	end
	local source = type(msg) == "table" and msg.source or nil
	if type(filter) == "string" then
		if not source then return msg end
		if string.match(source, filter) then
			return msg
		end
		return nil
	end
	return msg
end

M.uuid = function()
	local random = math.random
	return string.format(
		"%08x-%04x-%04x-%04x-%012x",
		random(0, 0xffffffff),
		random(0, 0xffff),
		random(0x4000, 0x4fff),
		random(0x8000, 0xbfff),
		random(0, 0xffffffffffff)
	)
end

--- v1 compat: termichatter:new(...) creates a Line
function M:new(...)
	local configs = { ... }
	local merged = {}
	for _, cfg in ipairs(configs) do
		if type(cfg) == "table" then
			for k, v in pairs(cfg) do
				merged[k] = v
			end
		end
	end
	merged.registry = merged.registry or registry
	return Line(merged)
end

--- v1 compat: makePipeline delegates to Line()
function M.makePipeline(config)
	config = config or {}
	config.registry = config.registry or registry
	return Line(config)
end

-- Module is callable: termichatter(config) creates a Line
setmetatable(M, {
	__call = function(_, config)
		config = config or {}
		config.registry = config.registry or registry
		return Line(config)
	end,
})

return M
