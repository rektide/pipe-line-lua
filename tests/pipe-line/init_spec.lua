local helper = require("tests.test_helper")

describe("pipe-line init", function()
	before_each(function()
		helper.setup_vim()
		helper.reset_pipeline_modules()
	end)

	it("exports async architecture modules", function()
		local pipeline = require("pipe-line")
		assert.is_table(pipeline.async)
		assert.is_table(pipeline.errors)
		assert.is_table(pipeline.gater)
		assert.is_table(pipeline.executor)
	end)

	it("registers default gater and executor", function()
		local pipeline = require("pipe-line")
		assert.is_not_nil(pipeline.registry:resolve_gater("none"))
		assert.is_not_nil(pipeline.registry:resolve_gater("inflight"))
		assert.is_not_nil(pipeline.registry:resolve_executor("buffered"))
	end)

	it("creates line with default async policy", function()
		local pipeline = require("pipe-line")
		local line = pipeline()
		assert.are.equal("none", line.default_gater)
		assert.are.equal("buffered", line.default_executor)
	end)

	it("runs sync segment end-to-end", function()
		local pipeline = require("pipe-line")
		pipeline.registry:register("sync_add", {
			handler = function(run)
				run.input.sync_add = true
				return run.input
			end,
		})

		local line = pipeline({ pipe = { "sync_add" } })
		line:log("hello")
		local out = helper.pop_queue(line.output)
		assert.is_true(out.sync_add)
	end)

	it("runs task_fn async segment end-to-end", function()
		local pipeline = require("pipe-line")
		local async = pipeline.async

		pipeline.registry:register("async_add", {
			handler = function(run)
				return async.task_fn(function(ctx)
					ctx.input.async_add = true
					return ctx.input
				end)
			end,
		})

		local line = pipeline({ pipe = { "async_add" } })
		line:log("hello")
		local out = helper.pop_queue(line.output)
		assert.is_true(out.async_add)
	end)
end)
