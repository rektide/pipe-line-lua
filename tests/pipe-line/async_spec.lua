local helper = require("tests.test_helper")
local coop = require("coop")

describe("pipe-line.async", function()
	local async

	before_each(function()
		helper.setup_vim()
		helper.reset_pipeline_modules()
		async = require("pipe-line.async")
	end)

	it("builds task_fn async operations", function()
		local op = async.task_fn(function()
			return "ok"
		end)
		assert.is_true(async.is_async_op(op))
		assert.are.equal("task_fn", op.kind)
	end)

	it("builds awaitable async operations", function()
		local task = coop.spawn(function()
			return 42
		end)
		local op = async.awaitable(task)
		assert.is_true(async.is_async_op(op))
		assert.are.equal("awaitable", op.kind)
	end)

	it("normalizes duck-typed awaitables", function()
		local task = coop.spawn(function()
			return "duck"
		end)
		local op = async.normalize(task)
		assert.is_true(async.is_async_op(op))
		assert.are.equal("awaitable", op.kind)
	end)

	it("executes task_fn outcome", function()
		local outcome = async.execute(async.task_fn(function(ctx)
			return ctx.answer
		end), { answer = 7 })
		assert.are.equal("ok", outcome.status)
		assert.are.equal(7, outcome.value)
	end)

	it("executes task_fn fail outcome", function()
		local outcome = async.execute(async.task_fn(function()
			return async.fail({ code = "boom", message = "bad" })
		end), {})
		assert.are.equal("error", outcome.status)
		assert.are.equal("boom", outcome.error.code)
	end)

	it("executes awaitable outcome in task context", function()
		local outcome = coop.spawn(function()
			local task = coop.spawn(function()
				return "awaited"
			end)
			return async.execute(async.awaitable(task), {})
		end):await(200, 1)

		assert.are.equal("ok", outcome.status)
		assert.are.equal("awaited", outcome.value)
	end)
end)
