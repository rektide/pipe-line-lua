--- Busted tests for unified sync/async pipeline
local coop = require("coop")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("termichatter unified pipeline", function()
	local termichatter

	before_each(function()
		package.loaded["termichatter"] = nil
		termichatter = require("termichatter")
	end)

	describe("interleaved sync/async stages", function()
		it("runs sync stages immediately", function()
			local steps = {}

			local module = termichatter.makePipeline()
			module.pipeline = { "step1", "step2", "step3" }
			module.queues = {} -- all sync

			module.step1 = function(msg)
				table.insert(steps, 1)
				return msg
			end
			module.step2 = function(msg)
				table.insert(steps, 2)
				return msg
			end
			module.step3 = function(msg)
				table.insert(steps, 3)
				return msg
			end

			termichatter.log({ message = "test" }, module)

			-- All steps run immediately
			assert.are.same({ 1, 2, 3 }, steps)
		end)

		it("hands off to queue at async stage", function()
			local steps = {}

			local module = termichatter.makePipeline()
			local asyncQueue = MpscQueue.new()

			module.pipeline = { "step1", "step2", "step3" }
			module.queues = { nil, asyncQueue, nil } -- step2 is async

			module.step1 = function(msg)
				table.insert(steps, 1)
				return msg
			end
			module.step2 = function(msg)
				table.insert(steps, 2)
				return msg
			end
			module.step3 = function(msg)
				table.insert(steps, 3)
				return msg
			end

			-- Log - should run step1, then push to queue
			termichatter.log({ message = "test" }, module)

			-- Only step1 ran synchronously
			assert.are.same({ 1 }, steps)
			-- Message is in queue
			assert.is_false(asyncQueue:empty())
		end)

		it("continues from queue through remaining stages", function()
			local steps = {}

			local module = termichatter.makePipeline()
			local asyncQueue = MpscQueue.new()

			module.pipeline = { "step1", "step2", "step3" }
			module.queues = { nil, asyncQueue, nil }

			module.step1 = function(msg)
				table.insert(steps, 1)
				return msg
			end
			module.step2 = function(msg)
				table.insert(steps, 2)
				return msg
			end
			module.step3 = function(msg)
				table.insert(steps, 3)
				return msg
			end

			-- Start consumers
			local tasks = termichatter.startConsumers(module)
			assert.are.equal(1, #tasks) -- one queue = one consumer

			-- Log message
			termichatter.log({ message = "test" }, module)

			-- Signal completion
			termichatter.finish(module)

			-- Wait for consumer
			tasks[1]:await(200, 10)

			-- All steps should have run
			assert.are.same({ 1, 2, 3 }, steps)

			-- Message should be in output queue
			local output = coop.spawn(function()
				return module.outputQueue:pop()
			end):await(50, 10)

			assert.are.equal("test", output.message)
		end)

		it("handles multiple async stages", function()
			local steps = {}

			local module = termichatter.makePipeline()
			local queue1 = MpscQueue.new()
			local queue2 = MpscQueue.new()

			module.pipeline = { "step1", "step2", "step3", "step4" }
			module.queues = { nil, queue1, nil, queue2 }

			module.step1 = function(msg)
				table.insert(steps, 1)
				return msg
			end
			module.step2 = function(msg)
				table.insert(steps, 2)
				return msg
			end
			module.step3 = function(msg)
				table.insert(steps, 3)
				return msg
			end
			module.step4 = function(msg)
				table.insert(steps, 4)
				return msg
			end

			-- Start consumers for both queues
			local tasks = termichatter.startConsumers(module)
			assert.are.equal(2, #tasks)

			-- Log message
			termichatter.log({ message = "test" }, module)

			-- Signal completion
			termichatter.finish(module)

			-- Wait for all consumers
			for _, task in ipairs(tasks) do
				task:await(200, 10)
			end

			-- All steps should have run in order
			assert.are.same({ 1, 2, 3, 4 }, steps)
		end)

		it("async stage at beginning", function()
			local steps = {}

			local module = termichatter.makePipeline()
			local queue1 = MpscQueue.new()

			module.pipeline = { "step1", "step2" }
			module.queues = { queue1, nil } -- first step is async

			module.step1 = function(msg)
				table.insert(steps, 1)
				return msg
			end
			module.step2 = function(msg)
				table.insert(steps, 2)
				return msg
			end

			-- Start consumers - consumer is waiting on pop()
			local tasks = termichatter.startConsumers(module)

			-- Log - pushes to queue, which resumes waiting consumer
			-- Consumer processes message immediately when resumed by push
			termichatter.log({ message = "test" }, module)

			-- Consumer already processed (push resumes waiting task)
			assert.are.same({ 1, 2 }, steps)

			-- Signal completion and wait
			termichatter.finish(module)
			tasks[1]:await(200, 10)

			-- Task should be complete
			assert.are.equal("dead", tasks[1]:status())
		end)

		it("async stage at end", function()
			local steps = {}

			local module = termichatter.makePipeline()
			local queue1 = MpscQueue.new()

			module.pipeline = { "step1", "step2" }
			module.queues = { nil, queue1 } -- last step is async

			module.step1 = function(msg)
				table.insert(steps, 1)
				return msg
			end
			module.step2 = function(msg)
				table.insert(steps, 2)
				return msg
			end

			-- Start consumers - consumer waiting on pop()
			local tasks = termichatter.startConsumers(module)

			-- Log - runs step1 sync, then pushes to queue
			-- Push resumes consumer which runs step2 immediately
			termichatter.log({ message = "test" }, module)

			-- Both steps ran (consumer resumed by push)
			assert.are.same({ 1, 2 }, steps)

			-- Signal completion and wait
			termichatter.finish(module)
			tasks[1]:await(200, 10)

			-- Task complete
			assert.are.equal("dead", tasks[1]:status())
		end)
	end)

	describe("filtering in async pipeline", function()
		it("filter in sync stage stops message", function()
			local steps = {}

			local module = termichatter.makePipeline()
			local asyncQueue = MpscQueue.new()

			module.pipeline = { "filter", "step2" }
			module.queues = { nil, asyncQueue }

			module.filter = function(msg)
				table.insert(steps, "filter")
				return nil -- filter out
			end
			module.step2 = function(msg)
				table.insert(steps, "step2")
				return msg
			end

			termichatter.log({ message = "test" }, module)

			-- Filter ran, message stopped
			assert.are.same({ "filter" }, steps)
			assert.is_true(asyncQueue:empty())
		end)

		it("filter in async stage stops message", function()
			local steps = {}

			local module = termichatter.makePipeline()
			local asyncQueue = MpscQueue.new()

			module.pipeline = { "step1", "filter", "step3" }
			module.queues = { nil, asyncQueue, nil }

			module.step1 = function(msg)
				table.insert(steps, 1)
				return msg
			end
			module.filter = function(msg)
				table.insert(steps, "filter")
				if msg.drop then
					return nil
				end
				return msg
			end
			module.step3 = function(msg)
				table.insert(steps, 3)
				return msg
			end

			local tasks = termichatter.startConsumers(module)

			-- Log two messages, one will be filtered
			-- Each message is fully processed before next (sync resume on push)
			termichatter.log({ message = "keep" }, module) -- step1, filter, step3
			termichatter.log({ message = "drop", drop = true }, module) -- step1, filter (stops)

			termichatter.finish(module)
			tasks[1]:await(200, 10)

			-- First message: step1 → filter → step3
			-- Second message: step1 → filter (filtered out)
			assert.are.same({ 1, "filter", 3, 1, "filter" }, steps)
		end)
	end)

	describe("multiple messages through async pipeline", function()
		it("processes multiple messages in order", function()
			local received = {}

			local module = termichatter.makePipeline()
			local asyncQueue = MpscQueue.new()

			module.pipeline = { "enrich", "capture" }
			module.queues = { asyncQueue, nil }

			module.enrich = function(msg)
				msg.enriched = true
				return msg
			end
			module.capture = function(msg)
				table.insert(received, msg.n)
				return msg
			end

			local tasks = termichatter.startConsumers(module)

			-- Log 5 messages
			for i = 1, 5 do
				termichatter.log({ n = i }, module)
			end

			termichatter.finish(module)
			tasks[1]:await(200, 10)

			-- All received in order
			assert.are.same({ 1, 2, 3, 4, 5 }, received)
		end)
	end)

	describe("completion protocol", function()
		it("done message propagates through queues", function()
			local module = termichatter.makePipeline()
			local queue1 = MpscQueue.new()
			local queue2 = MpscQueue.new()

			module.pipeline = { "step1", "step2", "step3" }
			module.queues = { queue1, nil, queue2 }

			module.step1 = function(msg)
				return msg
			end
			module.step2 = function(msg)
				return msg
			end
			module.step3 = function(msg)
				return msg
			end

			local tasks = termichatter.startConsumers(module)

			termichatter.finish(module)

			-- Wait for all consumers to finish
			for _, task in ipairs(tasks) do
				task:await(200, 10)
			end

			-- All tasks should be dead (finished)
			for _, task in ipairs(tasks) do
				assert.are.equal("dead", task:status())
			end

			-- Done should be in output queue
			local output = coop.spawn(function()
				return module.outputQueue:pop()
			end):await(50, 10)

			assert.are.equal("termichatter.completion.done", output.type)
		end)
	end)

	describe("stopConsumers", function()
		it("cancels running consumer tasks", function()
			local module = termichatter.makePipeline()
			local asyncQueue = MpscQueue.new()

			module.pipeline = { "step1" }
			module.queues = { asyncQueue }
			module.step1 = function(msg)
				return msg
			end

			local tasks = termichatter.startConsumers(module)

			-- Tasks should be running (waiting on pop)
			assert.are.equal("suspended", tasks[1]:status())

			-- Stop them
			termichatter.stopConsumers(module)

			-- Give it a moment to cancel
			vim.wait(50, function()
				return tasks[1]:status() == "dead"
			end, 10)

			-- Should be cancelled/dead now
			assert.are.equal("dead", tasks[1]:status())
		end)
	end)

	describe("continue function", function()
		it("runs handler at current step and advances", function()
			local steps = {}

			local module = termichatter.makePipeline()
			module.pipeline = { "step1", "step2" }
			module.queues = {}

			module.step1 = function(msg)
				table.insert(steps, 1)
				return msg
			end
			module.step2 = function(msg)
				table.insert(steps, 2)
				return msg
			end

			-- Manually set pipeStep and continue
			local msg = { message = "test", pipeStep = 1 }
			termichatter.continue(msg, module)

			-- Both steps ran (continue runs step1, then log runs step2)
			assert.are.same({ 1, 2 }, steps)
		end)

		it("returns nil if handler filters", function()
			local module = termichatter.makePipeline()
			module.pipeline = { "filter" }
			module.queues = {}

			module.filter = function(msg)
				return nil
			end

			local msg = { message = "test", pipeStep = 1 }
			local result = termichatter.continue(msg, module)

			assert.is_nil(result)
		end)
	end)
end)
