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
			local module = termichatter.makePipeline()
			local received = nil

			local consumer = coop.spawn(function()
				received = module.outputQueue:pop()
			end)

			termichatter.log({ message = "test" }, module)
			consumer:await(100, 10)

			assert.is_not_nil(received)
			assert.are.equal("test", received.message)
		end)

		it("processes multiple messages in order", function()
			local module = termichatter.makePipeline()
			local messages = {}

			local consumer = coop.spawn(function()
				for _ = 1, 3 do
					local msg = module.outputQueue:pop()
					table.insert(messages, msg.message)
				end
			end)

			termichatter.log({ message = "first" }, module)
			termichatter.log({ message = "second" }, module)
			termichatter.log({ message = "third" }, module)

			consumer:await(100, 10)

			assert.are.same({ "first", "second", "third" }, messages)
		end)

		it("supports queue at pipeline step", function()
			local module = termichatter.makePipeline()
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
			termichatter.log({ message = "test" }, module)

			-- Message is in queue, not processed yet
			assert.are.same({}, afterStep)
			assert.is_false(stepQueue:empty())

			-- Consume from queue and continue
			local consumer = coop.spawn(function()
				local msg = stepQueue:pop()
				-- Continue from this step
				msg.pipeStep = msg.pipeStep + 1
				termichatter.log(msg, module)
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
			local parent = termichatter.makePipeline({
				source = "parent:app",
				customSetting = "inherited",
			})

			local child = termichatter.makePipeline({
				source = "parent:app:child",
			}, parent)

			assert.are.equal("parent:app:child", child.source)
			assert.are.equal("inherited", child.customSetting)
		end)

		it("child can override parent settings", function()
			local parent = termichatter.makePipeline({
				filter = "parent.*",
			})

			local child = termichatter.makePipeline({
				filter = "child.*",
			}, parent)

			assert.are.equal("child.*", child.filter)
		end)

		it("child has independent pipeline", function()
			local parent = termichatter.makePipeline()
			local child = termichatter.makePipeline({}, parent)

			child:addProcessor("childOnly", function(msg)
				return msg
			end)

			assert.is_function(child.childOnly)
			assert.is_nil(parent.childOnly)
			assert.are.equal(#parent.pipeline + 1, #child.pipeline)
		end)

		it("logger inherits module context", function()
			local module = termichatter.makePipeline({ source = "app:main" })
			local captured = nil

			module:addProcessor("capture", function(msg)
				captured = msg
				return msg
			end)

			-- Create child logger
			local logger = termichatter.baseLogger({
				module = "submodule",
			}, module)

			logger("test message")

			assert.are.equal("app:main", captured.source)
			assert.are.equal("submodule", captured.module)
		end)
	end)

	describe("multiple producers", function()
		it("handles concurrent logging", function()
			local module = termichatter.makePipeline()
			local received = {}

			local consumer = coop.spawn(function()
				for _ = 1, 5 do
					local msg = module.outputQueue:pop()
					table.insert(received, msg.producer)
				end
			end)

			-- Multiple producers
			for i = 1, 5 do
				termichatter.log({ producer = i }, module)
			end

			consumer:await(200, 10)

			assert.are.equal(5, #received)
		end)
	end)
end)
