--- Busted tests for pipe-line consumer module
local coop = require("coop")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("pipe-line.consumer", function()
	local consumer, Line, registry, segment

	before_each(function()
		package.loaded["pipe-line.consumer"] = nil
		package.loaded["pipe-line.line"] = nil
		package.loaded["pipe-line.registry"] = nil
		package.loaded["pipe-line.segment"] = nil
		consumer = require("pipe-line.consumer")
		Line = require("pipe-line.line")
		registry = require("pipe-line.registry")
		segment = require("pipe-line.segment")
	end)

	local function make_line(segment_list, extra)
		extra = extra or {}
		extra.pipe = segment_list
		extra.registry = registry
		return Line(extra)
	end

	describe("make_consumer", function()
		it("processes enqueued continuation runs", function()
			local processed = false
			registry:register("marker", { handler = function(run)
				processed = true
				return run.input
			end })

			local queue = MpscQueue.new()
			local handoff = segment.mpsc_handoff({ queue = queue })
			local l = make_line({ handoff, "marker" }, { autoStartConsumers = false })

			consumer.ensure_queue_consumer(l, queue)

			l:log({ message = "test" })

			vim.wait(100, function()
				return processed
			end, 10)
			consumer.stop_queue_consumer(l, queue)
			assert.is_true(processed)
		end)

		it("default strategy queues the current run (self)", function()
			registry:register("marker", { handler = function(run)
				run.input.marker = true
				return run.input
			end })

			local queue = MpscQueue.new()
			local handoff = segment.mpsc_handoff({ queue = queue })
			local l = make_line({ handoff, "marker" }, { autoStartConsumers = false })
			local Run = require("pipe-line.run")

			local r = Run.new(l, { noStart = true, input = { message = "test" } })
			r:execute()
			r.pos = 99

			consumer.ensure_queue_consumer(l, queue)

			local msg = coop.spawn(function()
				return l.output:pop()
			end):await(50, 10)
			consumer.stop_queue_consumer(l, queue)
			assert.is_nil(msg.marker)
		end)

		it("clone strategy snapshots continuation cursor", function()
			registry:register("marker", { handler = function(run)
				run.input.marker = true
				return run.input
			end })

			local queue = MpscQueue.new()
			local handoff = segment.mpsc_handoff({ queue = queue, strategy = "clone" })
			local l = make_line({ handoff, "marker" }, { autoStartConsumers = false })
			local Run = require("pipe-line.run")

			local r = Run.new(l, { noStart = true, input = { message = "test" } })
			r:execute()
			r.pos = 99

			consumer.ensure_queue_consumer(l, queue)

			local msg = coop.spawn(function()
				return l.output:pop()
			end):await(50, 10)
			consumer.stop_queue_consumer(l, queue)
			assert.is_true(msg.marker)
		end)

		it("fork strategy isolates continuation from later pipe mutation", function()
			registry:register("marker", { handler = function(run)
				run.input.marker = true
				return run.input
			end })
			registry:register("replacement", { handler = function(run)
				run.input.replacement = true
				return run.input
			end })

			local queue = MpscQueue.new()
			local handoff = segment.mpsc_handoff({ queue = queue, strategy = "fork" })
			local l = make_line({ handoff, "marker" }, { autoStartConsumers = false })
			local Run = require("pipe-line.run")

			local r = Run.new(l, { noStart = true, input = { message = "test" } })
			r:execute()
			l.pipe:splice(2, 1, "replacement")

			consumer.ensure_queue_consumer(l, queue)

			local msg = coop.spawn(function()
				return l.output:pop()
			end):await(50, 10)
			consumer.stop_queue_consumer(l, queue)
			assert.is_true(msg.marker)
			assert.is_nil(msg.replacement)
		end)
	end)

	describe("start_async / stop / await_stopped", function()
		it("starts and stops consumers for handoff segments", function()
			local queue = MpscQueue.new()
			local handoff = segment.mpsc_handoff({ queue = queue })
			local l = make_line({ handoff })

			local task_list = consumer.start_async(l)
			assert.are.equal(1, #task_list)
			assert.is_not_nil(l._consumer_task_by_queue[queue])

			consumer.stop(l)
			assert.are.equal(0, #l._consumer_task)
			assert.is_nil(next(l._consumer_task_by_queue))
		end)

		it("is idempotent when started repeatedly", function()
			local queue = MpscQueue.new()
			local handoff = segment.mpsc_handoff({ queue = queue })
			local l = make_line({ handoff })

			local first = consumer.start_async(l)
			assert.are.equal(1, #first)

			local second = consumer.start_async(l)
			assert.are.equal(1, #second)
			assert.are.equal(first[1], second[1])

			consumer.stop(l)
		end)

		it("starts only newly discovered handoff queues on later calls", function()
			local queue1 = MpscQueue.new()
			local queue2 = MpscQueue.new()
			local handoff1 = segment.mpsc_handoff({ queue = queue1 })
			local l = make_line({ handoff1 })

			local first = consumer.start_async(l)
			assert.are.equal(1, #first)

			l:addHandoff(2, { queue = queue2 })
			local second = consumer.start_async(l)
			assert.are.equal(2, #second)
			assert.is_not_nil(l._consumer_task_by_queue[queue1])
			assert.is_not_nil(l._consumer_task_by_queue[queue2])

			consumer.stop(l)
		end)

		it("await_stopped resolves after cancel", function()
			local queue = MpscQueue.new()
			local handoff = segment.mpsc_handoff({ queue = queue })
			local l = make_line({ handoff })

			consumer.start_async(l)
			consumer.stop(l)

			assert.is_true(consumer.await_stopped(l, 200, 10))
		end)
	end)
end)
