--- Busted tests for termichatter pipeline (line/run integration)
local coop = require("coop")

describe("termichatter.pipeline", function()
	local termichatter

	before_each(function()
		package.loaded["termichatter"] = nil
		package.loaded["termichatter.init"] = nil
		package.loaded["termichatter.registry"] = nil
		package.loaded["termichatter.line"] = nil
		package.loaded["termichatter.run"] = nil
		package.loaded["termichatter.pipe"] = nil
		package.loaded["termichatter.segment"] = nil
		package.loaded["termichatter.consumer"] = nil
		package.loaded["termichatter.log"] = nil
		package.loaded["termichatter.protocol"] = nil
		package.loaded["termichatter.resolver"] = nil
		termichatter = require("termichatter")
	end)

	describe("queue-based pipeline", function()
		it("pushes to output queue", function()
			local app = termichatter()
			app.pipe = require("termichatter.pipe").new({ "timestamper", "cloudevent" })

			local Run = require("termichatter.run")
			local run = Run.new(app, { noStart = true, input = { message = "test" } })
			run:execute()

			local received = nil
			local task = coop.spawn(function()
				received = app.output:pop()
			end)
			task:await(100, 10)

			assert.is_not_nil(received)
			assert.are.equal("test", received.message)
		end)

		it("processes multiple messages in order", function()
			local app = termichatter()
			app.pipe = require("termichatter.pipe").new({ "timestamper" })

			app:log({ message = "first" })
			app:log({ message = "second" })
			app:log({ message = "third" })

			local messages = {}
			local task = coop.spawn(function()
				for _ = 1, 3 do
					local msg = app.output:pop()
					table.insert(messages, msg.message)
				end
			end)
			task:await(100, 10)

			assert.are.same({ "first", "second", "third" }, messages)
		end)

		it("supports queue at pipeline step", function()
			local app = termichatter()
			local afterStep = {}

			app.pipe = require("termichatter.pipe").new({ "timestamper", "mpsc_handoff", "queuedStep", "capture" })

			app.queuedStep = function(run)
				table.insert(afterStep, "queued")
				return run.input
			end
			app.capture = function(run)
				table.insert(afterStep, "captured")
				return run.input
			end

			app:log({ message = "test" })
			local out = coop.spawn(function()
				return app.output:pop()
			end):await(200, 10)
			assert.are.equal("test", out.message)
			assert.are.same({ "queued", "captured" }, afterStep)
		end)

		it("resolves named mpsc_handoff with no manual setup", function()
			local app = termichatter()
			local captured = nil

			app:addSegment("capture", function(run)
				captured = run.input
				return run.input
			end)

			app.pipe = require("termichatter.pipe").new({ "mpsc_handoff", "capture" })
			app:log({ message = "hello" })

			local received = coop.spawn(function()
				return app.output:pop()
			end):await(200, 10)

			assert.are.equal("hello", received.message)
			assert.are.equal("hello", captured.message)
		end)

		it("materializes distinct queues for repeated named mpsc_handoff entries", function()
			local app = termichatter()
			app.pipe = require("termichatter.pipe").new({ "mpsc_handoff", "mpsc_handoff" })
			app:log({ message = "materialize" })

			assert.are.equal("mpsc_handoff", app.pipe[1].type)
			assert.are.equal("mpsc_handoff", app.pipe[2].type)
			assert.are_not.equal(app.pipe[1].queue, app.pipe[2].queue)
		end)
	end)

	describe("recursive context", function()
		it("child line inherits from parent", function()
			local parent = termichatter({
				source = "parent",
				customSetting = "inherited",
			})

			local child = parent:child("child")

			assert.are.equal("child", child.source)
			assert.are.equal("parent:child", child:full_source())
			assert.are.equal("inherited", child.customSetting)
		end)

		it("child can override parent settings", function()
			local parent = termichatter({
				filter = "parent.*",
			})

			local child = parent:child({
				filter = "child.*",
			})

			assert.are.equal("child.*", child.filter)
		end)

		it("fork has independent pipeline", function()
			local parent = termichatter()
			local child = parent:fork("worker")

			child:addSegment("childOnly", function(run)
				return run.input
			end)

			assert.is_nil(rawget(parent, "childOnly"))
			assert.are.equal(#parent.pipe + 1, #child.pipe)
			assert.are_not.equal(parent.pipe, child.pipe)
		end)

		it("log methods inherit module context", function()
			local app = termichatter({ source = "app:main" })
			local captured = nil

			app:addSegment("capture", function(run)
				captured = run.input
				return run.input
			end)

			app:info("test message")

			assert.are.equal("app:main", captured.source)
		end)
	end)

	describe("multiple producers", function()
		it("handles concurrent logging", function()
			local app = termichatter()
			app.pipe = require("termichatter.pipe").new({ "timestamper" })

			for i = 1, 5 do
				app:log({ producer = i })
			end

			local received = {}
			local task = coop.spawn(function()
				for _ = 1, 5 do
					local msg = app.output:pop()
					table.insert(received, msg.producer)
				end
			end)
			task:await(200, 10)

			assert.are.equal(5, #received)
		end)
	end)
end)
