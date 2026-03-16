local helper = require("tests.test_helper")

describe("pipe-line.async.control", function()
	local AsyncControl

	before_each(function()
		helper.setup_vim()
		helper.reset_pipeline_modules()
		AsyncControl = require("pipe-line.async.control")
	end)

	local function fake_run()
		local settle_cbs = {}
		local run = {}
		function run:on_settle(cb)
			table.insert(settle_cbs, cb)
		end
		function run:finish(outcome)
			for _, cb in ipairs(settle_cbs) do
				cb(outcome or { status = "ok" })
			end
			settle_cbs = {}
		end
		return run
	end

	it("tracks inflight admission and drains on settle", function()
		local control = AsyncControl({})
		local gater = {}
		control:register_component(gater)

		local run = fake_run()
		control:mark_admitted(run)
		assert.are.equal(1, control.inflight)

		control:request_stop("stop_drain")
		assert.is_false(control.drained.done)

		run:finish({ status = "ok" })
		assert.are.equal(0, control.inflight)
		assert.is_true(control.drained.done)

		control:mark_component_stopped(gater)
		assert.is_true(control.stopped.done)
	end)

	it("tracks pending and waits for pending to clear", function()
		local control = AsyncControl({})
		local comp = {}
		control:register_component(comp)

		control:track_pending(1)
		control:request_stop("stop_drain")
		assert.is_false(control.drained.done)

		control:track_pending(-1)
		assert.is_true(control.drained.done)

		control:mark_component_stopped(comp)
		assert.is_true(control.stopped.done)
	end)

	it("escalates stop_drain to stop_immediate", function()
		local control = AsyncControl({})
		local comp = {}
		control:register_component(comp)
		control:request_stop("stop_drain")
		assert.are.equal("stopping_drain", control.state)

		control:request_stop("stop_immediate")
		assert.are.equal("stopping_immediate", control.state)
		assert.are.equal("stop_immediate", control.stop_type)
	end)
end)
