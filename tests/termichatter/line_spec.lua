--- Busted tests for termichatter Line object
local coop = require("coop")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("termichatter.line", function()
	local Line, Pipe, registry

	before_each(function()
		package.loaded["termichatter.line"] = nil
		package.loaded["termichatter.pipe"] = nil
		package.loaded["termichatter.registry"] = nil
		package.loaded["termichatter.run"] = nil
		package.loaded["termichatter.segment"] = nil
		package.loaded["termichatter.log"] = nil
		Line = require("termichatter.line")
		Pipe = require("termichatter.pipe")
		registry = require("termichatter.registry")
	end)

	describe("construction", function()
		it("creates root line with defaults", function()
			local line = Line({ registry = registry, source = "app" })
			assert.are.equal("line", line.type)
			assert.are.equal("app", line.source)
			assert.is_not_nil(line.pipe)
			assert.is_not_nil(line.output)
			assert.is_table(line.fact)
			assert.is_function(line.sourcer)
		end)

		it("uses shared level helper methods", function()
			local line = Line({ registry = registry })
			assert.is_nil(rawget(line, "error"))
			assert.is_nil(rawget(line, "warn"))
			assert.is_nil(rawget(line, "info"))
			assert.is_nil(rawget(line, "debug"))
			assert.is_nil(rawget(line, "trace"))
			assert.is_function(line.error)
			assert.is_function(line.warn)
			assert.is_function(line.info)
			assert.is_function(line.debug)
			assert.is_function(line.trace)
		end)
	end)

	describe("child", function()
		it("creates thin child with local source", function()
			local root = Line({ source = "root", registry = registry })
			local child = root:child("auth")
			local leaf = child:child("jwt")

			assert.are.equal(root, child.parent)
			assert.are.equal(child, leaf.parent)
			assert.are.equal("auth", child.source)
			assert.are.equal("jwt", leaf.source)
			assert.are.equal("root:auth", child:full_source())
			assert.are.equal("root:auth:jwt", leaf:full_source())
		end)

		it("shares parent pipeline and output by default", function()
			local root = Line({ registry = registry })
			local child = root:child("mod")

			assert.are.equal(root.pipe, child.pipe)
			assert.are.equal(root.output, child.output)

			child:addSegment("child_seg", function(run)
				return run.input
			end)

			assert.are.equal(#root.pipe, #child.pipe)
			assert.are.equal("child_seg", root.pipe[#root.pipe])
		end)

		it("inherits arbitrary parent fields via metatable", function()
			local root = Line({ registry = registry, custom = "inherited" })
			local child = root:child("mod")
			assert.are.equal("inherited", child.custom)
		end)
	end)

	describe("fork", function()
		it("creates independent pipe and output", function()
			local root = Line({ pipe = { "a", "b" }, registry = registry })
			local forked = root:fork("worker")

			assert.are.equal(root, forked.parent)
			assert.are_not.equal(root.pipe, forked.pipe)
			assert.are_not.equal(root.output, forked.output)

			forked.pipe:splice(1, 1)
			assert.are.equal(1, #forked.pipe)
			assert.are.equal(2, #root.pipe)
		end)

		it("copies parent fact into independent table", function()
			local root = Line({ registry = registry })
			root.fact.mode = "root"
			local forked = root:fork("worker")

			assert.are_not.equal(root.fact, forked.fact)
			assert.are.equal("root", forked.fact.mode)
			forked.fact.mode = "fork"
			assert.are.equal("root", root.fact.mode)
		end)

		it("accepts explicit output override", function()
			local output = MpscQueue.new()
			local root = Line({ registry = registry })
			local forked = root:fork({ source = "worker", output = output })
			assert.are.equal(output, forked.output)
		end)
	end)

	describe("run integration", function()
		it("prepare_segments calls ensure_prepared hooks", function()
			local calls = 0
			local prepared = {
				handler = function(run) return run.input end,
				ensure_prepared = function(self, context)
					calls = calls + 1
					assert.are.equal(1, context.pos)
					assert.is_true(context.force)
				end,
			}
			local line = Line({ pipe = { prepared }, registry = registry })

			line:prepare_segments()

			assert.are.equal(1, calls)
		end)

		it("run executes ensure_prepared hooks lazily", function()
			local calls = 0
			local prepared = {
				handler = function(run) return run.input end,
				ensure_prepared = function(self, context)
					calls = calls + 1
					assert.is_nil(context.force)
					assert.is_not_nil(context.run)
				end,
			}
			local line = Line({ pipe = { prepared }, registry = registry })

			line:run({ input = { once = true } })

			assert.are.equal(1, calls)
		end)

		it("resolves registered segments", function()
			local called = false
			registry:register("marker", {
				handler = function(run)
					called = true
					return run.input
				end,
			})

			local line = Line({ pipe = { "marker" }, registry = registry })
			line:run({ input = {} })
			assert.is_true(called)
		end)

		it("pushes execution result to output", function()
			registry:register("pass", { handler = function(run) return run.input end })
			local line = Line({ pipe = { "pass" }, registry = registry })

			line:run({ input = { id = 42 } })

			local received = nil
			local task = coop.spawn(function()
				received = line.output:pop()
			end)
			task:await(100, 10)

			assert.are.equal(42, received.id)
		end)
	end)

	describe("pipe helpers", function()
		it("clone_pipe clones existing pipe", function()
			local line = Line({ pipe = { "a", "b" }, registry = registry })
			local cloned = line:clone_pipe()
			assert.are.equal(2, #cloned)
			cloned:splice(1, 1)
			assert.are.equal(2, #line.pipe)
		end)

		it("clone_pipe builds from segment list", function()
			local line = Line({ registry = registry })
			local fresh = line:clone_pipe({ "x", "y" })
			assert.are.equal(2, #fresh)
			assert.are.equal("x", fresh[1])
			assert.are.equal("y", fresh[2])
		end)

		it("accepts Pipe object directly", function()
			local pipe = Pipe({ "x", "y" })
			local line = Line({ pipe = pipe, registry = registry })
			assert.are.equal(pipe, line.pipe)
		end)
	end)
end)
