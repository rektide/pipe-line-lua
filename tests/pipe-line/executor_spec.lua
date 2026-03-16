local helper = require("tests.test_helper")

describe("pipe-line.executor.buffered", function()
	local buffered
	local async

	before_each(function()
		helper.setup_vim()
		helper.reset_pipeline_modules()
		buffered = require("pipe-line.executor.buffered")
		async = require("pipe-line.async")
	end)

	local function fake_run(op)
		local run = {
			line = {},
			input = { message = "x" },
			_async = {
				op = op,
				segment = { type = "fake_segment", id = "fake-1" },
				continuation = { input = { message = "x" } },
			},
			settled = nil,
		}

		function run:settle(outcome)
			self.settled = outcome
		end

		return run
	end

	it("handles task_fn and settles ok outcome", function()
		local executor = buffered()
		executor:ensure_prepared({})

		local run = fake_run(async.task_fn(function(ctx)
			ctx.input.done = true
			return ctx.input
		end))

		executor:handle(run)
		assert.is_true(helper.wait_for(function()
			return run.settled ~= nil
		end, 200))
		assert.are.equal("ok", run.settled.status)
		assert.is_true(run.settled.value.done)
	end)

	it("settles async.fail as error outcome", function()
		local executor = buffered()
		executor:ensure_prepared({})

		local run = fake_run(async.task_fn(function()
			return async.fail({ code = "bad", message = "boom" })
		end))

		executor:handle(run)
		assert.is_true(helper.wait_for(function()
			return run.settled ~= nil
		end, 200))
		assert.are.equal("error", run.settled.status)
		assert.are.equal("bad", run.settled.error.code)
	end)

	it("rejects new runs after ensure_stopped", function()
		local executor = buffered()
		executor:ensure_prepared({})
		executor:ensure_stopped({ line = { executor_stop_type = "stop_immediate" } })

		local run = fake_run(async.task_fn(function()
			return true
		end))
		executor:handle(run)

		assert.are.equal("error", run.settled.status)
		assert.are.equal("executor_not_accepting", run.settled.error.code)
	end)
end)

describe("pipe-line.executor.direct", function()
	local direct
	local async
	local Future

	before_each(function()
		helper.setup_vim()
		helper.reset_pipeline_modules()
		direct = require("pipe-line.executor.direct")
		async = require("pipe-line.async")
		Future = require("coop.future").Future
	end)

	local function fake_run(op)
		local run = {
			line = {},
			input = { message = "x" },
			_async = {
				op = op,
				segment = { type = "fake_segment", id = "fake-1" },
				continuation = { input = { message = "x" } },
			},
			settled = nil,
		}

		function run:settle(outcome)
			self.settled = outcome
		end

		return run
	end

	it("executes one run with minimal handoff", function()
		local executor = direct()
		executor:ensure_prepared({})

		local run = fake_run(async.task_fn(function(ctx)
			ctx.input.direct = true
			return ctx.input
		end))

		executor:handle(run)
		assert.is_true(helper.wait_for(function()
			return run.settled ~= nil
		end, 200))
		assert.are.equal("ok", run.settled.status)
		assert.is_true(run.settled.value.direct)
	end)

	it("rejects concurrent run while current run is in-flight", function()
		local executor = direct()
		executor:ensure_prepared({})

		local block = Future.new()
		local first = fake_run(async.task_fn(function()
			return async.awaitable(block)
		end))
		local second = fake_run(async.task_fn(function()
			return true
		end))

		executor:handle(first)
		executor:handle(second)

		assert.are.equal("error", second.settled.status)
		assert.are.equal("executor_direct_busy", second.settled.error.code)

		block:complete(true)
		assert.is_true(helper.wait_for(function()
			return first.settled ~= nil
		end, 200))
		assert.are.equal("ok", first.settled.status)
	end)

	it("stops immediately and rejects new work", function()
		local executor = direct()
		executor:ensure_prepared({})
		executor:ensure_stopped({ line = { executor_stop_type = "stop_immediate" } })

		local run = fake_run(async.task_fn(function()
			return true
		end))
		executor:handle(run)
		assert.are.equal("error", run.settled.status)
		assert.are.equal("executor_not_accepting", run.settled.error.code)
	end)
end)
