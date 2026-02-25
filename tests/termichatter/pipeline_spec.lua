--- Busted tests for termichatter pipeline (line/run integration)
local coop = require("coop")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

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
		package.loaded["termichatter.protocol"] = nil
		package.loaded["termichatter.resolver"] = nil
		termichatter = require("termichatter")
	end)

	describe("queue-based pipeline", function()
		it("pushes to output queue", function()
			local app = termichatter()
			app.pipe = require("termichatter.pipe").new({ "timestamper", "cloudevent" })

			app:log({ message = "test" })

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
			local stepQueue = MpscQueue.new()
			local afterStep = {}

			app.pipe = require("termichatter.pipe").new({ "timestamper", "queuedStep", "capture" })
			app.mpsc = { [2] = stepQueue }

			app.queuedStep = function(run)
				table.insert(afterStep, "queued")
				return run.input
			end
			app.capture = function(run)
				table.insert(afterStep, "captured")
				return run.input
			end

			app:log({ message = "test" })

			-- message is in queue, not processed yet
			assert.are.same({}, afterStep)
			assert.is_false(stepQueue:empty())

			-- consume from queue and continue
			local Run = require("termichatter.run")
			local consumer_task = coop.spawn(function()
				local msg = stepQueue:pop()
				local run = Run(app, {
					noStart = true,
					input = msg,
				})
				-- execute the segment at pos 2 manually, then advance
				run.pos = 2
				local handler = run:resolve(run.pipe[2])
				local result = handler(run)
				if result ~= nil then run.input = result end
				run:next()
			end)

			consumer_task:await(100, 10)
			assert.are.same({ "queued", "captured" }, afterStep)
		end)
	end)

	describe("recursive context", function()
		it("child line inherits from parent", function()
			local parent = termichatter({
				source = "parent:app",
				customSetting = "inherited",
			})

			local child = parent:derive({
				source = "parent:app:child",
			})

			assert.are.equal("parent:app:child", child.source)
			assert.are.equal("inherited", child.customSetting)
		end)

		it("child can override parent settings", function()
			local parent = termichatter({
				filter = "parent.*",
			})

			local child = parent:derive({
				filter = "child.*",
			})

			assert.are.equal("child.*", child.filter)
		end)

		it("child has independent pipeline", function()
			local parent = termichatter()
			local child = parent:derive({})

			child:addProcessor("childOnly", function(run)
				return run.input
			end)

			assert.is_nil(rawget(parent, "childOnly"))
			assert.are.equal(#parent.pipe + 1, #child.pipe)
		end)

		it("log methods inherit module context", function()
			local app = termichatter({ source = "app:main" })
			local captured = nil

			app:addProcessor("capture", function(run)
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
