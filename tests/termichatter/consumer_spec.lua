--- Busted tests for termichatter consumer module
local coop = require("coop")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("termichatter.consumer", function()
	local consumer, protocol, Pipe, Line, registry

	before_each(function()
		package.loaded["termichatter.consumer"] = nil
		package.loaded["termichatter.protocol"] = nil
		package.loaded["termichatter.pipe"] = nil
		package.loaded["termichatter.line"] = nil
		package.loaded["termichatter.run"] = nil
		package.loaded["termichatter.registry"] = nil
		consumer = require("termichatter.consumer")
		protocol = require("termichatter.protocol")
		Pipe = require("termichatter.pipe")
		Line = require("termichatter.line")
		registry = require("termichatter.registry")
	end)

	local function make_line(segment_list, extra)
		extra = extra or {}
		extra.pipe = segment_list
		extra.registry = registry
		return Line(extra)
	end

	describe("make_consumer", function()
		it("processes message from queue through segment", function()
			local processed = false
			registry:register("marker", { handler = function(run)
				processed = true
				return run.input
			end })

			local queue = MpscQueue.new()
			local l = make_line({ "marker" })
			l.mpsc = { [1] = queue }

			local consume = consumer.make_consumer(l, 1, queue)

			queue:push({ message = "test" })
			queue:push(vim.deepcopy(protocol.shutdown))

			local task = coop.spawn(consume)
			task:await(200, 10)

			assert.is_true(processed)
		end)

		it("forwards shutdown to output", function()
			local queue = MpscQueue.new()
			local l = make_line({})
			l.mpsc = { [1] = queue }

			local consume = consumer.make_consumer(l, 1, queue)

			queue:push(vim.deepcopy(protocol.shutdown))

			local task = coop.spawn(consume)
			task:await(100, 10)

			local msg = coop.spawn(function()
				return l.output:pop()
			end):await(50, 10)

			assert.are.equal("termichatter.shutdown", msg.type)
		end)

		it("forwards completion signal to output", function()
			local queue = MpscQueue.new()
			local l = make_line({})
			l.mpsc = { [1] = queue }

			local consume = consumer.make_consumer(l, 1, queue)

			queue:push(vim.deepcopy(protocol.done))
			queue:push(vim.deepcopy(protocol.shutdown))

			local task = coop.spawn(consume)
			task:await(100, 10)

			local msg = coop.spawn(function()
				return l.output:pop()
			end):await(50, 10)

			assert.are.equal("termichatter.completion.done", msg.type)
		end)
	end)

	describe("start_consumer / stop_consumer", function()
		it("starts and stops consumer for async stage", function()
			registry:register("async_seg", { handler = function(run)
				return run.input
			end })

			local l = make_line({ "async_seg" })
			l:ensure_mpsc(1)

			local task_list = consumer.start_consumer(l)
			assert.is_true(#task_list > 0)

			consumer.stop_consumer(l)
			assert.are.equal(0, #l._consumer_task)
		end)

		it("is idempotent when started repeatedly", function()
			registry:register("async_seg", { handler = function(run)
				return run.input
			end })

			local l = make_line({ "async_seg" })
			l:ensure_mpsc(1)

			local first = consumer.start_consumer(l)
			assert.are.equal(1, #first)

			local second = consumer.start_consumer(l)
			assert.are.equal(1, #second)
			assert.are.equal(first[1], second[1])

			consumer.stop_consumer(l)
		end)

		it("starts only newly added async stages on later calls", function()
			registry:register("async_a", { handler = function(run)
				return run.input
			end })
			registry:register("async_b", { handler = function(run)
				return run.input
			end })

			local l = make_line({ "async_a", "async_b" })
			l:ensure_mpsc(1)

			local first = consumer.start_consumer(l)
			assert.are.equal(1, #first)

			l:ensure_mpsc(2)
			local second = consumer.start_consumer(l)
			assert.are.equal(2, #second)
			assert.is_not_nil(l._consumer_task_by_pos[1])
			assert.is_not_nil(l._consumer_task_by_pos[2])

			consumer.stop_consumer(l)
		end)
	end)
end)
