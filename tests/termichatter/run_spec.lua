--- Busted tests for termichatter run
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("termichatter.run", function()
	local Run, Pipe, registry, Line

	before_each(function()
		package.loaded["termichatter.run"] = nil
		package.loaded["termichatter.pipe"] = nil
		package.loaded["termichatter.registry"] = nil
		package.loaded["termichatter.line"] = nil
		Run = require("termichatter.run")
		Pipe = require("termichatter.pipe")
		registry = require("termichatter.registry")
		Line = require("termichatter.line")
	end)

	local function make_line(segment_list, extra)
		extra = extra or {}
		extra.pipe = segment_list
		extra.registry = registry
		return Line(extra)
	end

	describe("methods via metatable", function()
		it("does not copy methods onto instance", function()
			registry:register("noop", { handler = function(run) return run.input end })
			local l = make_line({ "noop" })
			local r = Run.new(l, { noStart = true, input = {} })

			-- methods should NOT be in rawget
			assert.is_nil(rawget(r, "execute"))
			assert.is_nil(rawget(r, "resolve"))
			assert.is_nil(rawget(r, "sync"))
			assert.is_nil(rawget(r, "clone"))
			assert.is_nil(rawget(r, "fork"))
			assert.is_nil(rawget(r, "own"))
			assert.is_nil(rawget(r, "set_fact"))
			assert.is_nil(rawget(r, "next"))

			-- but they should be accessible
			assert.is_function(r.execute)
			assert.is_function(r.resolve)
		end)
	end)

	describe("execute", function()
		it("walks pipe calling segment", function()
			local order = {}
			registry:register("a", { handler = function(run)
				table.insert(order, "a")
				return run.input
			end })
			registry:register("b", { handler = function(run)
				table.insert(order, "b")
				return run.input
			end })

			local l = make_line({ "a", "b" })
			Run.new(l, { input = { msg = "test" } })
			assert.are.same({ "a", "b" }, order)
		end)

		it("stops on false return (filtering)", function()
			local reached = false
			registry:register("blocker", { handler = function() return false end })
			registry:register("after", { handler = function(run)
				reached = true
				return run.input
			end })

			local l = make_line({ "blocker", "after" })
			Run.new(l, { input = {} })
			assert.is_false(reached)
		end)

		it("pushes to output at end of pipe", function()
			registry:register("pass", { handler = function(run) return run.input end })
			local l = make_line({ "pass" })
			Run.new(l, { input = { message = "hello" } })

			local received = nil
			local coop = require("coop")
			local task = coop.spawn(function()
				received = l.output:pop()
			end)
			task:await(100, 10)
			assert.is_not_nil(received)
			assert.are.equal("hello", received.message)
		end)

		it("updates input between segment", function()
			registry:register("add_x", { handler = function(run)
				run.input.x = true
				return run.input
			end })
			registry:register("check_x", { handler = function(run)
				assert.is_true(run.input.x)
				return run.input
			end })

			local l = make_line({ "add_x", "check_x" })
			Run.new(l, { input = {} })
		end)
	end)

	describe("next", function()
		it("advances and continues execution", function()
			local order = {}
			registry:register("s1", { handler = function(run)
				table.insert(order, "s1")
				return run.input
			end })
			registry:register("s2", { handler = function(run)
				table.insert(order, "s2")
				return run.input
			end })

			local l = make_line({ "s1", "s2" })
			local r = Run.new(l, { noStart = true, input = {} })
			r.pos = 1
			r:next()
			assert.are.same({ "s2" }, order)
		end)
	end)

	describe("set_fact", function()
		it("lazily creates fact table", function()
			local l = make_line({})
			local r = Run.new(l, { noStart = true, input = {} })
			assert.is_nil(rawget(r, "fact"))

			r:set_fact("time")
			assert.is_not_nil(rawget(r, "fact"))
			assert.is_true(r.fact.time)
		end)

		it("reads through to line.fact", function()
			local l = make_line({})
			l.fact.baseline = true

			local r = Run.new(l, { noStart = true, input = {} })
			-- before set_fact, fact resolves to line.fact via metatable
			assert.is_true(r.fact.baseline)

			-- after set_fact, own fact still reads through
			r:set_fact("custom")
			assert.is_true(r.fact.baseline)
			assert.is_true(r.fact.custom)
		end)

		it("does not pollute line.fact", function()
			local l = make_line({})
			local r = Run.new(l, { noStart = true, input = {} })
			r:set_fact("private")
			assert.is_nil(l.fact.private)
		end)
	end)

	describe("own", function()
		it("own pipe creates independent clone", function()
			local l = make_line({ "a", "b" })
			local r = Run.new(l, { noStart = true, input = {} })

			assert.are.equal(l.pipe, r.pipe) -- shared
			r:own("pipe")
			assert.are_not.equal(l.pipe, r.pipe) -- independent
			assert.are.equal(2, #r.pipe)

			r.pipe:splice(1, 1)
			assert.are.equal(1, #r.pipe)
			assert.are.equal(2, #l.pipe) -- original unchanged
		end)

		it("own fact snapshots all fact", function()
			local l = make_line({})
			l.fact.from_line = true

			local r = Run.new(l, { noStart = true, input = {} })
			r:set_fact("from_run")
			r:own("fact")

			-- snapshot contains both
			assert.is_true(r.fact.from_line)
			assert.is_true(r.fact.from_run)

			-- no longer reads through: changes to line.fact not visible
			l.fact.added_later = true
			assert.is_nil(r.fact.added_later)
		end)
	end)

	describe("clone", function()
		it("creates lightweight copy", function()
			registry:register("pass", { handler = function(run) return run.input end })
			local l = make_line({ "pass" })
			local r = Run.new(l, { noStart = true, input = { orig = true } })

			local c = r:clone({ cloned = true })
			assert.are.equal(r.line, c.line)
			assert.is_true(c.input.cloned)
			assert.are.equal(r.pos, c.pos)
		end)

		it("fan-out: multiple clone execute independently", function()
			local results = {}
			registry:register("collect", { handler = function(run)
				table.insert(results, run.input)
				return run.input
			end })

			local l = make_line({ "collect" })
			local r = Run.new(l, { noStart = true, input = {} })
			r.pos = 1

			local c1 = r:clone({ id = 1 })
			local c2 = r:clone({ id = 2 })
			c1:execute()
			c2:execute()

			assert.are.equal(2, #results)
			assert.are.equal(1, results[1].id)
			assert.are.equal(2, results[2].id)
		end)

		it("sees parent run owned fact", function()
			local l = make_line({})
			local r = Run.new(l, { noStart = true, input = {} })
			r:set_fact("parent_fact")

			local c = r:clone({})
			assert.is_true(c.fact.parent_fact)
		end)
	end)

	describe("fork", function()
		it("creates fully independent run", function()
			local l = make_line({ "a", "b" })
			l.fact.shared = true

			local r = Run.new(l, { noStart = true, input = { orig = true } })
			r:set_fact("run_fact")

			local f = r:fork({ forked = true })

			-- owns its own pipe
			assert.are_not.equal(l.pipe, f.pipe)
			-- owns its own fact (snapshot, no metatable)
			f.fact.forked_fact = true
			assert.is_nil(r.fact.forked_fact)

			-- has all fact from before fork
			assert.is_true(f.fact.shared)
			assert.is_true(f.fact.run_fact)
		end)
	end)

	describe("sync", function()
		it("adjusts pos after line pipe splice", function()
			local l = make_line({ "a", "b", "c" })
			local r = Run.new(l, { noStart = true, input = {} })
			r.pos = 3 -- pointing at "c"

			-- insert two element before pos
			l.pipe:splice(2, 0, "x", "y")
			-- pipe is now: a, x, y, b, c
			-- r.pos is still 3, should be 5

			r:sync()
			assert.are.equal(5, r.pos)
		end)

		it("is no-op when run owns pipe", function()
			local l = make_line({ "a", "b", "c" })
			local r = Run.new(l, { noStart = true, input = {} })
			r.pos = 3
			r:own("pipe")

			l.pipe:splice(2, 0, "x", "y")
			r:sync()
			assert.are.equal(3, r.pos) -- unchanged
		end)

		it("is no-op when rev matches", function()
			local l = make_line({ "a", "b", "c" })
			local r = Run.new(l, { noStart = true, input = {} })
			r.pos = 3

			r:sync()
			assert.are.equal(3, r.pos) -- no change
		end)
	end)
end)
