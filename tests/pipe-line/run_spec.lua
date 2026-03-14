--- Busted tests for pipe-line run
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("pipe-line.run", function()
	local Run, Pipe, registry, Line

	before_each(function()
		package.loaded["pipe-line.run"] = nil
		package.loaded["pipe-line.pipe"] = nil
		package.loaded["pipe-line.registry"] = nil
		package.loaded["pipe-line.line"] = nil
		Run = require("pipe-line.run")
		Pipe = require("pipe-line.pipe")
		registry = require("pipe-line.registry")
		Line = require("pipe-line.line")
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
			local r = Run.new(l, { auto_start = false, input = {} })

			-- methods should NOT be in rawget
			assert.is_nil(rawget(r, "execute"))
			assert.is_nil(rawget(r, "resolve"))
			assert.is_nil(rawget(r, "sync"))
			assert.is_nil(rawget(r, "clone"))
			assert.is_nil(rawget(r, "fork"))
			assert.is_nil(rawget(r, "own"))
			assert.is_nil(rawget(r, "set_fact"))
			assert.is_nil(rawget(r, "next"))
			assert.is_nil(rawget(r, "emit"))

			-- but they should be accessible
			assert.is_function(r.execute)
			assert.is_function(r.resolve)
			assert.is_function(r.emit)
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
			local r = Run.new(l, { auto_start = false, input = {} })
			r.pos = 1
			r:next()
			assert.are.same({ "s2" }, order)
		end)
	end)

	describe("emit", function()
		it("clones and advances with new element", function()
			local results = {}
			registry:register("anchor", { handler = function(run) return run.input end })
			registry:register("collector", { handler = function(run)
				table.insert(results, run.input)
				return run.input
			end })

			local l = make_line({ "anchor", "collector" })
			local r = Run.new(l, { auto_start = false, input = { source = true } })
			r.pos = 1

			local child = r:emit({ emitted = true })

			assert.are.equal(1, #results)
			assert.is_true(results[1].emitted)
			assert.are_not.equal(r, child)
			assert.is_true(child.input.emitted)
			assert.are.equal(1, r.pos)
		end)

		it("supports self strategy to continue on current run", function()
			local results = {}
			registry:register("anchor", { handler = function(run) return run.input end })
			registry:register("collector", { handler = function(run)
				table.insert(results, run.input)
				return run.input
			end })

			local l = make_line({ "anchor", "collector" })
			local r = Run.new(l, { auto_start = false, input = { source = true } })
			r.pos = 1

			local continued = r:emit({ self_emit = true }, "self")

			assert.are.equal(r, continued)
			assert.are.equal(1, #results)
			assert.is_true(results[1].self_emit)
			assert.are.equal(3, r.pos)
		end)

		it("supports fork strategy for independent continuation", function()
			local results = {}
			registry:register("anchor", { handler = function(run) return run.input end })
			registry:register("collector", { handler = function(run)
				table.insert(results, run.input)
				return run.input
			end })

			local l = make_line({ "anchor", "collector" })
			local r = Run.new(l, { auto_start = false, input = { source = true } })
			r.pos = 1

			local child = r:emit({ fork_emit = true }, "fork")

			assert.are_not.equal(r, child)
			assert.are_not.equal(r.pipe, child.pipe)
			assert.is_not_nil(rawget(child, "fact"))
			assert.are.equal(1, #results)
			assert.is_true(results[1].fork_emit)
			assert.are.equal(1, r.pos)
		end)
	end)

	describe("set_fact", function()
		it("lazily creates fact table", function()
			local l = make_line({})
			local r = Run.new(l, { auto_start = false, input = {} })
			assert.is_nil(rawget(r, "fact"))

			r:set_fact("time")
			assert.is_not_nil(rawget(r, "fact"))
			assert.is_true(r.fact.time)
		end)

		it("reads through to line.fact", function()
			local l = make_line({})
			l.fact.baseline = true

			local r = Run.new(l, { auto_start = false, input = {} })
			-- before set_fact, fact resolves to line.fact via metatable
			assert.is_true(r.fact.baseline)

			-- after set_fact, own fact still reads through
			r:set_fact("custom")
			assert.is_true(r.fact.baseline)
			assert.is_true(r.fact.custom)
		end)

		it("does not pollute line.fact", function()
			local l = make_line({})
			local r = Run.new(l, { auto_start = false, input = {} })
			r:set_fact("private")
			assert.is_nil(l.fact.private)
		end)
	end)

	describe("own", function()
		it("own pipe creates independent clone", function()
			local l = make_line({ "a", "b" })
			local r = Run.new(l, { auto_start = false, input = {} })

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

			local r = Run.new(l, { auto_start = false, input = {} })
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
			local r = Run.new(l, { auto_start = false, input = { orig = true } })

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
			local r = Run.new(l, { auto_start = false, input = {} })
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
			local r = Run.new(l, { auto_start = false, input = {} })
			r:set_fact("parent_fact")

			local c = r:clone({})
			assert.is_true(c.fact.parent_fact)
		end)
	end)

	describe("fork", function()
		it("creates fully independent run", function()
			local l = make_line({ "a", "b" })
			l.fact.shared = true

			local r = Run.new(l, { auto_start = false, input = { orig = true } })
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
			local r = Run.new(l, { auto_start = false, input = {} })
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
			local r = Run.new(l, { auto_start = false, input = {} })
			r.pos = 3
			r:own("pipe")

			l.pipe:splice(2, 0, "x", "y")
			r:sync()
			assert.are.equal(3, r.pos) -- unchanged
		end)

		it("is no-op when rev matches", function()
			local l = make_line({ "a", "b", "c" })
			local r = Run.new(l, { auto_start = false, input = {} })
			r.pos = 3

			r:sync()
			assert.are.equal(3, r.pos) -- no change
		end)

		it("handles multiple splice journal entries", function()
			local l = make_line({ "a", "b", "c", "d", "e" })
			local r = Run.new(l, { auto_start = false, input = {} })
			r.pos = 5 -- pointing at "e"

			-- first splice: insert "x" at position 2
			l.pipe:splice(2, 0, "x")
			-- pipe: a, x, b, c, d, e — pos should be 6

			-- second splice: insert "y", "z" at position 1
			l.pipe:splice(1, 0, "y", "z")
			-- pipe: y, z, a, x, b, c, d, e — pos should be 8

			r:sync()
			assert.are.equal(8, r.pos)
		end)

		it("snaps pos when inside deleted zone", function()
			local l = make_line({ "a", "b", "c", "d", "e" })
			local r = Run.new(l, { auto_start = false, input = {} })
			r.pos = 3 -- pointing at "c"

			-- delete positions 2-4 (b, c, d)
			l.pipe:splice(2, 3)
			-- pipe: a, e — pos was inside deleted zone, should snap to 2

			r:sync()
			assert.are.equal(2, r.pos)
		end)

		it("handles mixed insert and delete splices", function()
			local l = make_line({ "a", "b", "c", "d" })
			local r = Run.new(l, { auto_start = false, input = {} })
			r.pos = 4 -- pointing at "d"

			-- replace "b" with "x", "y", "z"
			l.pipe:splice(2, 1, "x", "y", "z")
			-- pipe: a, x, y, z, c, d — pos should be 6

			r:sync()
			assert.are.equal(6, r.pos)
		end)

		it("clone syncs against inherited owned pipe", function()
			local l = make_line({ "a", "b", "c" })
			local r = Run.new(l, { auto_start = false, input = {} })
			r.pos = 3
			r:own("pipe")

			local c = r:clone({})
			c.pos = 3

			r.pipe:splice(2, 0, "x", "y")
			-- owned pipe: a, x, y, b, c ; clone cursor should move from 3 -> 5

			c:sync()
			assert.are.equal(5, c.pos)
		end)
	end)

	describe("fan-out with clone + next", function()
		it("splitter pipe emits multiple element via clone", function()
			local results = {}
			registry:register("collector", { handler = function(run)
				table.insert(results, run.input)
				return run.input
			end })

			-- splitter: takes input with .part array, clones for each
			registry:register("splitter", { handler = function(run)
				for _, part in ipairs(run.input.part) do
					local child = run:clone(part)
					child:next()
				end
				return false -- stop this run, clones handle forwarding
			end })

			local l = make_line({ "splitter", "collector" })
			Run.new(l, { input = { part = { { id = 1 }, { id = 2 }, { id = 3 } } } })

			assert.are.equal(3, #results)
			assert.are.equal(1, results[1].id)
			assert.are.equal(2, results[2].id)
			assert.are.equal(3, results[3].id)
		end)

		it("splitter pipe emits multiple element via emit", function()
			local results = {}
			registry:register("collector", { handler = function(run)
				table.insert(results, run.input)
				return run.input
			end })

			registry:register("splitter_emit", { handler = function(run)
				for _, part in ipairs(run.input.part) do
					run:emit(part)
				end
				return false
			end })

			local l = make_line({ "splitter_emit", "collector" })
			Run.new(l, { input = { part = { { id = "a" }, { id = "b" }, { id = "c" } } } })

			assert.are.equal(3, #results)
			assert.are.equal("a", results[1].id)
			assert.are.equal("b", results[2].id)
			assert.are.equal("c", results[3].id)
		end)

		it("fan-out element reach output independently", function()
			registry:register("splitter", { handler = function(run)
				for _, part in ipairs(run.input.part) do
					local child = run:clone(part)
					child:next()
				end
				return false
			end })

			local l = make_line({ "splitter" })
			Run.new(l, { input = { part = { { v = "a" }, { v = "b" } } } })

			local received = {}
			local coop = require("coop")
			local task = coop.spawn(function()
				for _ = 1, 2 do
					local msg = l.output:pop()
					table.insert(received, msg.v)
				end
			end)
			task:await(100, 10)

			assert.are.equal(2, #received)
			assert.is_truthy(vim.tbl_contains(received, "a"))
			assert.is_truthy(vim.tbl_contains(received, "b"))
		end)

		it("fan-out with per-element fact", function()
			registry:register("tagger", { handler = function(run)
				run:set_fact("tagged_" .. tostring(run.input.id))
				return run.input
			end })
			registry:register("splitter", { handler = function(run)
				for _, part in ipairs(run.input.part) do
					local child = run:clone(part)
					child:next()
				end
				return false
			end })

			local l = make_line({ "splitter", "tagger" })
			Run.new(l, { input = { part = { { id = "x" }, { id = "y" } } } })

			-- each clone gets its own fact via set_fact
			-- line fact should not be polluted
			assert.is_nil(l.fact.tagged_x)
			assert.is_nil(l.fact.tagged_y)
		end)

		it("chained fan-out: splitter into splitter", function()
			local results = {}
			registry:register("collector", { handler = function(run)
				table.insert(results, run.input)
				return run.input
			end })
			registry:register("split2", { handler = function(run)
				if not run.input.sub then
					return run.input
				end
				for _, part in ipairs(run.input.sub) do
					local child = run:clone(part)
					child:next()
				end
				return false
			end })

			local l = make_line({ "split2", "split2", "collector" })
			Run.new(l, { input = {
				sub = {
					{ sub = { { leaf = 1 }, { leaf = 2 } } },
					{ sub = { { leaf = 3 } } },
				},
			} })

			assert.are.equal(3, #results)
		end)
	end)

	describe("fork pipe independence", function()
		it("forked run can splice without affecting parent", function()
			local l = make_line({ "a", "b", "c" })
			local r = Run.new(l, { auto_start = false, input = {} })

			local f = r:fork()
			f.pipe:splice(2, 1) -- remove "b" from fork

			assert.are.equal(2, #f.pipe)
			assert.are.equal(3, #r.pipe) -- parent unchanged
			assert.are.equal(3, #l.pipe) -- line unchanged
		end)

		it("sibling fork are independent", function()
			local l = make_line({ "a", "b", "c", "d" })
			local r = Run.new(l, { auto_start = false, input = {} })

			local f1 = r:fork({ id = 1 })
			local f2 = r:fork({ id = 2 })

			f1.pipe:splice(1, 1) -- remove "a" from f1
			f2.pipe:splice(4, 1) -- remove "d" from f2

			assert.are.equal(3, #f1.pipe)
			assert.are.equal(3, #f2.pipe)
			assert.are.equal("b", f1.pipe[1])
			assert.are.equal("a", f2.pipe[1])
			assert.are.equal(4, #l.pipe) -- line unchanged
		end)

		it("forked fact are independent", function()
			local l = make_line({})
			l.fact.shared = true
			local r = Run.new(l, { auto_start = false, input = {} })
			r:set_fact("parent_fact")

			local f1 = r:fork()
			local f2 = r:fork()

			f1.fact.f1_only = true
			f2.fact.f2_only = true

			-- each fork sees shared + parent
			assert.is_true(f1.fact.shared)
			assert.is_true(f1.fact.parent_fact)
			assert.is_true(f2.fact.shared)
			assert.is_true(f2.fact.parent_fact)

			-- but not each other's
			assert.is_nil(f2.fact.f1_only)
			assert.is_nil(f1.fact.f2_only)

			-- parent unaffected
			assert.is_nil(r.fact.f1_only)
			assert.is_nil(r.fact.f2_only)
		end)
	end)
end)
