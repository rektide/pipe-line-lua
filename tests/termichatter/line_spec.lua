--- Busted tests for termichatter Line class
local coop = require("coop")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("termichatter.line", function()
	local Line, Pipe, registry, Run

	before_each(function()
		package.loaded["termichatter.line"] = nil
		package.loaded["termichatter.pipe"] = nil
		package.loaded["termichatter.registry"] = nil
		package.loaded["termichatter.run"] = nil
		package.loaded["termichatter.segment"] = nil
		package.loaded["termichatter.consumer"] = nil
		Line = require("termichatter.line")
		Pipe = require("termichatter.pipe")
		registry = require("termichatter.registry")
		Run = require("termichatter.run")
	end)

	describe("constructor", function()
		it("creates a line with default pipe", function()
			local l = Line({ registry = registry })
			assert.are.equal("line", l.type)
			assert.is_not_nil(l.pipe)
			assert.is_true(#l.pipe > 0)
		end)

		it("creates a line with custom pipe", function()
			local l = Line({ pipe = { "a", "b" }, registry = registry })
			assert.are.equal(2, #l.pipe)
			assert.are.equal("a", l.pipe[1])
			assert.are.equal("b", l.pipe[2])
		end)

		it("accepts a Pipe object directly", function()
			local p = Pipe({ "x", "y" })
			local l = Line({ pipe = p, registry = registry })
			assert.are.equal(p, l.pipe)
		end)

		it("creates output queue automatically", function()
			local l = Line({ registry = registry })
			assert.is_not_nil(l.output)
		end)

		it("accepts custom output queue", function()
			local q = MpscQueue.new()
			local l = Line({ output = q, registry = registry })
			assert.are.equal(q, l.output)
		end)

		it("applies config fields to instance", function()
			local l = Line({ source = "myapp", custom = 42, registry = registry })
			assert.are.equal("myapp", l.source)
			assert.are.equal(42, l.custom)
		end)

		it("has empty fact table", function()
			local l = Line({ registry = registry })
			assert.is_table(l.fact)
		end)

		it("has priority method", function()
			local l = Line({ registry = registry })
			assert.is_function(l.error)
			assert.is_function(l.warn)
			assert.is_function(l.info)
			assert.is_function(l.debug)
			assert.is_function(l.trace)
		end)

		it("gets priority methods from prototype", function()
			local l = Line({ registry = registry })
			assert.is_nil(rawget(l, "error"))
			assert.is_nil(rawget(l, "warn"))
			assert.is_nil(rawget(l, "info"))
			assert.is_nil(rawget(l, "debug"))
			assert.is_nil(rawget(l, "trace"))
			assert.is_function(l.error)
			assert.is_function(l.warn)
			assert.is_function(l.info)
			assert.is_function(l.debug)
			assert.is_function(l.trace)
		end)

		it("is callable via Line(config)", function()
			local l = Line({ registry = registry })
			assert.are.equal("line", l.type)
		end)
	end)

	describe("derive", function()
		it("creates child that inherits parent config", function()
			local parent = Line({ source = "parent", custom = "inherited", registry = registry })
			local child = parent:derive({ source = "child" })
			assert.are.equal("child", child.source)
			assert.are.equal("inherited", child.custom)
		end)

		it("child has independent pipe", function()
			local parent = Line({ pipe = { "a", "b" }, registry = registry })
			local child = parent:derive({})
			assert.are.equal(2, #child.pipe)
			child.pipe:splice(1, 1)
			assert.are.equal(1, #child.pipe)
			assert.are.equal(2, #parent.pipe)
		end)

		it("child has independent output", function()
			local parent = Line({ registry = registry })
			local child = parent:derive({})
			assert.are_not.equal(parent.output, child.output)
		end)

		it("child inherits registry via metatable", function()
			local parent = Line({ registry = registry })
			local child = parent:derive({})
			assert.are.equal(registry, child.registry)
		end)

		it("child can share parent output explicitly", function()
			local parent = Line({ registry = registry })
			local child = parent:derive({ output = parent.output })
			assert.are.equal(parent.output, child.output)
		end)

		it("grandchild inherits from parent chain", function()
			local root = Line({ source = "root", env = "prod", registry = registry })
			local mid = root:derive({ source = "mid" })
			local leaf = mid:derive({ source = "leaf" })
			assert.are.equal("leaf", leaf.source)
			assert.are.equal("prod", leaf.env)
		end)
	end)

	describe("resolve_segment", function()
		it("resolves from registry", function()
			local handler = function(run) return run.input end
			registry:register("my_seg", handler)
			local l = Line({ registry = registry })
			assert.are.equal(handler, l:resolve_segment("my_seg"))
		end)

		it("resolves from instance rawget", function()
			local handler = function(run) return run.input end
			local l = Line({ registry = registry })
			rawset(l, "local_seg", handler)
			assert.are.equal(handler, l:resolve_segment("local_seg"))
		end)

		it("returns function directly", function()
			local fn = function() end
			local l = Line({ registry = registry })
			assert.are.equal(fn, l:resolve_segment(fn))
		end)

		it("returns table directly", function()
			local tbl = { handler = function() end }
			local l = Line({ registry = registry })
			assert.are.equal(tbl, l:resolve_segment(tbl))
		end)

		it("returns nil for unknown string", function()
			local l = Line({ registry = registry })
			assert.is_nil(l:resolve_segment("nonexistent"))
		end)

		it("returns nil for non-string non-function non-table", function()
			local l = Line({ registry = registry })
			assert.is_nil(l:resolve_segment(42))
		end)
	end)

	describe("addHandoff", function()
		it("inserts an explicit mpsc_handoff segment", function()
			local l = Line({ pipe = { "a", "b" }, registry = registry })
			local handoff = l:addHandoff(2)
			assert.are.equal(3, #l.pipe)
			assert.are.equal(handoff, l.pipe[2])
			assert.are.equal("mpsc_handoff", handoff.type)
			assert.is_function(handoff.queue.push)
			assert.is_function(handoff.queue.pop)
		end)

		it("uses provided queue when configured", function()
			local l = Line({ pipe = { "a" }, registry = registry })
			local q = MpscQueue.new()
			local handoff = l:addHandoff(2, { queue = q })
			assert.are.equal(q, handoff.queue)
		end)
	end)

	describe("run", function()
		it("creates and executes a Run", function()
			local executed = false
			registry:register("marker", { handler = function(run)
				executed = true
				return run.input
			end })
			local l = Line({ pipe = { "marker" }, registry = registry })
			l:run({ input = {} })
			assert.is_true(executed)
		end)

		it("pushes result to output", function()
			registry:register("pass", { handler = function(run) return run.input end })
			local l = Line({ pipe = { "pass" }, registry = registry })
			l:run({ input = { msg = "hello" } })

			local received = nil
			local task = coop.spawn(function()
				received = l.output:pop()
			end)
			task:await(100, 10)
			assert.are.equal("hello", received.msg)
		end)
	end)

	describe("log", function()
		it("wraps string in table", function()
			local captured = nil
			registry:register("cap", { handler = function(run)
				captured = run.input
				return run.input
			end })
			local l = Line({ pipe = { "cap" }, registry = registry, source = "test" })
			l:log("hello")
			assert.are.equal("hello", captured.message)
			assert.are.equal("test", captured.source)
		end)
	end)

	describe("baseLogger", function()
		it("uses shared priority methods", function()
			local l = Line({ source = "app", registry = registry })
			local a = l:baseLogger({ module = "a" })
			local b = l:baseLogger({ module = "b" })

			assert.are.equal("app:a", a.source)
			assert.are.equal("app:b", b.source)
			assert.are.equal(a.info, b.info)
			assert.are.equal(a.error, b.error)
		end)

		it("keeps logger methods on metatable", function()
			local l = Line({ registry = registry })
			local logger = l:baseLogger({})

			assert.is_nil(rawget(logger, "info"))
			assert.is_nil(rawget(logger, "error"))
			assert.is_function(logger.info)
			assert.is_function(logger.error)
		end)

		it("allows config to intentionally shadow logger methods", function()
			local l = Line({ registry = registry })
			local logger = l:baseLogger({ info = "not-a-method" })

			assert.are.equal("not-a-method", logger.info)
		end)
	end)

	describe("addSegment", function()
		it("appends to end by default", function()
			local l = Line({ pipe = { "a" }, registry = registry })
			l:addSegment("b", function() end)
			assert.are.equal(2, #l.pipe)
			assert.are.equal("b", l.pipe[2])
		end)

		it("inserts at specified position", function()
			local l = Line({ pipe = { "a", "c" }, registry = registry })
			l:addSegment("b", function() end, 2)
			assert.are.equal(3, #l.pipe)
			assert.are.equal("b", l.pipe[2])
			assert.are.equal("c", l.pipe[3])
		end)

		it("does not inject async queue metadata", function()
			local l = Line({ pipe = { "a" }, registry = registry })
			l:addSegment("async_seg", function() end, 2)
			assert.is_nil(l.mpsc)
		end)
	end)

	describe("spliceSegment", function()
		it("splices segment entries directly", function()
			local l = Line({ pipe = { "a", "c" }, registry = registry })
			l:spliceSegment(2, 0, "b")
			assert.are.same({ "a", "b", "c" }, { l.pipe[1], l.pipe[2], l.pipe[3] })
		end)
	end)

	describe("clone_pipe", function()
		it("clones existing pipe", function()
			local l = Line({ pipe = { "a", "b" }, registry = registry })
			local cloned = l:clone_pipe()
			assert.are.equal(2, #cloned)
			cloned:splice(1, 1)
			assert.are.equal(2, #l.pipe)
		end)

		it("creates new pipe from segment list", function()
			local l = Line({ pipe = { "a" }, registry = registry })
			local fresh = l:clone_pipe({ "x", "y", "z" })
			assert.are.equal(3, #fresh)
			assert.are.equal("x", fresh[1])
		end)
	end)
end)
