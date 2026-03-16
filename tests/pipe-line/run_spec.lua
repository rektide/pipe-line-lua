local helper = require("tests.test_helper")

describe("pipe-line.run async execution", function()
	local pipeline

	before_each(function()
		helper.setup_vim()
		pipeline = helper.fresh_pipeline()
	end)

	it("keeps sync semantics for nil/value/false", function()
		local seen = {}
		pipeline.registry:register("nil_seg", {
			handler = function(run)
				table.insert(seen, "nil")
				return nil
			end,
		})
		pipeline.registry:register("value_seg", {
			handler = function(run)
				table.insert(seen, "value")
				run.input.tag = "set"
				return run.input
			end,
		})
		pipeline.registry:register("stop_seg", {
			handler = function(run)
				table.insert(seen, "stop")
				return false
			end,
		})
		pipeline.registry:register("never", {
			handler = function(run)
				table.insert(seen, "never")
				return run.input
			end,
		})

		local line = pipeline({ pipe = { "nil_seg", "value_seg", "stop_seg", "never" } })
		line:log("hello")
		assert.are.same({ "nil", "value", "stop" }, seen)
	end)

	it("continues with downstream segment after task_fn async settle", function()
		local async = pipeline.async
		pipeline.registry:register("async_seg", {
			handler = function(run)
				return async.task_fn(function(ctx)
					ctx.input.async_done = true
					return ctx.input
				end)
			end,
		})
		pipeline.registry:register("after", {
			handler = function(run)
				run.input.after_done = true
				return run.input
			end,
		})

		local line = pipeline({ pipe = { "async_seg", "after" } })
		line:log("hello")
		local out = helper.pop_queue(line.output)
		assert.is_true(out.async_done)
		assert.is_true(out.after_done)
	end)

	it("supports duck-typed awaitable returns", function()
		local coop = require("coop")
		pipeline.registry:register("duck", {
			handler = function(run)
				return coop.spawn(function()
					run.input.duck = true
					return run.input
				end)
			end,
		})

		local line = pipeline({ pipe = { "duck" } })
		line:log("hello")
		local out = helper.pop_queue(line.output)
		assert.is_true(out.duck)
	end)

	it("propagates async failures as payload errors and continues", function()
		local async = pipeline.async
		local errors = pipeline.errors
		local saw_error_in_after = false

		pipeline.registry:register("fails", {
			handler = function(run)
				return async.task_fn(function(_ctx)
					return async.fail({ code = "fail_code", message = "fail msg" })
				end)
			end,
		})

		pipeline.registry:register("after", {
			handler = function(run)
				saw_error_in_after = errors.has(run.input)
				run.input.after = true
				return run.input
			end,
		})

		local line = pipeline({ pipe = { "fails", "after" } })
		line:log("hello")
		local out = helper.pop_queue(line.output)

		assert.is_true(saw_error_in_after)
		assert.is_true(out.after)
		assert.is_true(errors.has(out))
		assert.are.equal("fail_code", errors.list(out)[1].code)
	end)

	it("resolves cfg from segment before line", function()
		local from_cfg
		local seg = {
			type = "cfg_seg",
			gate_inflight_max = 9,
			handler = function(run)
				from_cfg = run:cfg("gate_inflight_max")
				return run.input
			end,
		}
		local line = pipeline({
			gate_inflight_max = 3,
			pipe = { seg },
		})
		line:log("hello")
		assert.are.equal(9, from_cfg)
	end)
end)
