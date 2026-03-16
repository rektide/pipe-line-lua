local helper = require("tests.test_helper")

describe("pipe-line.gater.inflight", function()
	local inflight
	local async
	local AsyncControl

	before_each(function()
		helper.setup_vim()
		helper.reset_pipeline_modules()
		inflight = require("pipe-line.gater.inflight")
		async = require("pipe-line.async")
		AsyncControl = require("pipe-line.async.control")
	end)

	local function fake_run(config, control)
		local settle_cbs = {}
		local run = {
			_async = {
				op = async.task_fn(function()
					return true
				end),
				control = control,
			},
			dispatched = 0,
			settled = nil,
		}

		function run:cfg(key, fallback)
			local v = config[key]
			if v == nil then
				return fallback
			end
			return v
		end

		function run:on_settle(cb)
			table.insert(settle_cbs, cb)
		end

		function run:dispatch()
			self.dispatched = self.dispatched + 1
		end

		function run:settle(outcome)
			self.settled = outcome
		end

		function run:finish(outcome)
			for _, cb in ipairs(settle_cbs) do
				cb(outcome or { status = "ok" })
			end
			settle_cbs = {}
		end

		return run
	end

	it("admits immediately under inflight limit", function()
		local gate = inflight()
		local control = AsyncControl({})
		gate:ensure_prepared({ control = control })
		local run = fake_run({ gate_inflight_max = 1 }, control)
		gate:handle(run)
		assert.are.equal(1, run.dispatched)
		assert.are.equal(1, gate.inflight)
	end)

	it("queues when inflight is full and pending allows", function()
		local gate = inflight()
		local control = AsyncControl({})
		gate:ensure_prepared({ control = control })
		local r1 = fake_run({ gate_inflight_max = 1, gate_inflight_pending = 1 }, control)
		local r2 = fake_run({ gate_inflight_max = 1, gate_inflight_pending = 1 }, control)

		gate:handle(r1)
		gate:handle(r2)

		assert.are.equal(1, r1.dispatched)
		assert.are.equal(0, r2.dispatched)
		assert.are.equal(1, #gate.pending)

		r1:finish({ status = "ok" })
		assert.are.equal(1, r2.dispatched)
		assert.are.equal(0, #gate.pending)
	end)

	it("settles overflow error when pending is full", function()
		local gate = inflight()
		local control = AsyncControl({})
		gate:ensure_prepared({ control = control })
		local r1 = fake_run({ gate_inflight_max = 1, gate_inflight_pending = 0, gate_inflight_overflow = "error" }, control)
		local r2 = fake_run({ gate_inflight_max = 1, gate_inflight_pending = 0, gate_inflight_overflow = "error" }, control)

		gate:handle(r1)
		gate:handle(r2)

		assert.is_not_nil(r2.settled)
		assert.are.equal("error", r2.settled.status)
		assert.are.equal("gate_overflow", r2.settled.error.code)
	end)

	it("drops pending runs on stop_immediate", function()
		local gate = inflight()
		local control = AsyncControl({})
		gate:ensure_prepared({ control = control })
		local r1 = fake_run({ gate_inflight_max = 1, gate_inflight_pending = 1 }, control)
		local r2 = fake_run({ gate_inflight_max = 1, gate_inflight_pending = 1 }, control)

		gate:handle(r1)
		gate:handle(r2)
		local stopped = gate:ensure_stopped({ line = { gater_stop_type = "stop_immediate" } })

		assert.are.equal("error", r2.settled.status)
		assert.are.equal("gate_stop_immediate", r2.settled.error.code)
		assert.is_false(stopped.done)

		r1:finish({ status = "ok" })
		assert.is_true(stopped.done)
	end)
end)
