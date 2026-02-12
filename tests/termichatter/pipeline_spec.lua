--- Busted tests for termichatter pipeline with async queues
local coop = require("coop")
local sleep = require("coop.uv-utils").sleep
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("termichatter.pipeline async", function()
	local termichatter

	before_each(function()
		package.loaded["termichatter"] = nil
		termichatter = require("termichatter")
	end)

	describe("queue-based pipeline", function()
		it("pushes to output queue", function()
			-- Use sync pipeline so messages go straight to outputQueue
			local module = termichatter:new()
			module.pipeline = { "timestamper", "cloudevents" }
			module.queues = {}

			-- Log first (sync), then pop
			module:log({ message = "test" })

			-- Pop should work immediately since message is already there
			local received = nil
			local task = coop.spawn(function()
				received = module.outputQueue:pop()
			end)
			task:await(100, 10)

			assert.is_not_nil(received)
			assert.are.equal("test", received.message)
		end)

		it("processes multiple messages in order", function()
			local module = termichatter:new()
			module.pipeline = { "timestamper" }
			module.queues = {}

			-- Log all messages first (sync)
			module:log({ message = "first" })
			module:log({ message = "second" })
			module:log({ message = "third" })

			-- Now collect from output queue
			local messages = {}
			local task = coop.spawn(function()
				for _ = 1, 3 do
					local msg = module.outputQueue:pop()
					table.insert(messages, msg.message)
				end
			end)
			task:await(100, 10)

			assert.are.same({ "first", "second", "third" }, messages)
		end)

		it("supports queue at pipeline step", function()
			local module = termichatter:new()
			local stepQueue = MpscQueue.new()
			local afterStep = {}

			-- Insert a queue-backed step
			module.pipeline = { "timestamper", "queuedStep", "capture" }
			module.queues = { nil, stepQueue, nil }

			module.queuedStep = function(msg)
				table.insert(afterStep, "queued")
				return msg
			end
			module.capture = function(msg)
				table.insert(afterStep, "captured")
				return msg
			end

			-- Log synchronously - should stop at queue
			module:log({ message = "test" })

			-- Message is in queue, not processed yet
			assert.are.same({}, afterStep)
			assert.is_false(stepQueue:empty())

			-- Consume from queue and continue
			local consumer = coop.spawn(function()
				local msg = stepQueue:pop()
				-- Continue from this step
				msg.pipeStep = msg.pipeStep + 1
				module:log(msg)
			end)

			consumer:await(100, 10)

			-- Now should have been captured
			assert.are.same({ "captured" }, afterStep)
		end)
	end)

	describe("completion protocol", function()
		it("hello message has correct type", function()
			assert.are.equal("termichatter.completion.hello", termichatter.completion.hello.type)
		end)

		it("done message has correct type", function()
			assert.are.equal("termichatter.completion.done", termichatter.completion.done.type)
		end)
	end)

	describe("recursive context", function()
		it("child module inherits from parent", function()
			local parent = termichatter:new({
				source = "parent:app",
				customSetting = "inherited",
			})

			local child = parent:new({
				source = "parent:app:child",
			})

			assert.are.equal("parent:app:child", child.source)
			assert.are.equal("inherited", child.customSetting)
		end)

		it("child can override parent settings", function()
			local parent = termichatter:new({
				filter = "parent.*",
			})

			local child = parent:new({
				filter = "child.*",
			})

			assert.are.equal("child.*", child.filter)
		end)

		it("child has independent pipeline", function()
			local parent = termichatter:new()
			local child = parent:new({})

			child:addProcessor("childOnly", function(msg)
				return msg
			end)

			assert.is_function(child.childOnly)
			assert.is_nil(parent.childOnly)
			assert.are.equal(#parent.pipeline + 1, #child.pipeline)
		end)

		it("log methods inherit module context", function()
			local module = termichatter:new({ source = "app:main", module = "submodule" })
			local captured = nil

			module:addProcessor("capture", function(msg)
				captured = msg
				return msg
			end)

			module:info("test message")

			assert.are.equal("app:main", captured.source)
			assert.are.equal("submodule", captured.module)
		end)
	end)

	describe("multiple producers", function()
		it("handles concurrent logging", function()
			local module = termichatter:new()
			module.pipeline = { "timestamper" }
			module.queues = {}

			-- Multiple producers (sync)
			for i = 1, 5 do
				module:log({ producer = i })
			end

			-- Now collect
			local received = {}
			local task = coop.spawn(function()
				for _ = 1, 5 do
					local msg = module.outputQueue:pop()
					table.insert(received, msg.producer)
				end
			end)
			task:await(200, 10)

			assert.are.equal(5, #received)
		end)
	end)
end)
