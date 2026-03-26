local helper = require("tests.test_helper")

describe("pipe-line.line async aspects", function()
	local pipeline

	before_each(function()
		helper.setup_vim()
		pipeline = helper.fresh_pipeline()
	end)

	it("injects default executor aspect", function()
		local seg = {
			type = "demo",
			handler = function(run)
				return run.input
			end,
		}
		local line = pipeline({ pipe = { seg } })
		local aspects = line:resolve_segment_aspects(1, seg)
		assert.are.equal(1, #aspects)
		assert.are.equal("executor", aspects[1].role)
	end)

	it("resolves shorthand executor refs", function()
		pipeline.registry:register_executor("test_exec", {
			type = "test_exec",
			role = "executor",
			handle = function(self, run)
				return run:settle({ status = "ok", value = run.input })
			end,
		})

		local seg = {
			type = "demo",
			executor = "test_exec",
			handler = function(run)
				return run.input
			end,
		}
		local line = pipeline({ pipe = { seg } })
		local aspects = line:resolve_segment_aspects(1, seg)
		assert.are.equal("test_exec", aspects[1].type)
	end)

	it("runs aspect lifecycle hooks in ensure_prepared and ensure_stopped", function()
		local prepared = 0
		local stopped = 0
		pipeline.registry:register_executor("life_exec", {
			role = "executor",
			handle = function(self, run)
				return run:settle({ status = "ok", value = run.input })
			end,
			ensure_prepared = function(self, _ctx)
				prepared = prepared + 1
			end,
			ensure_stopped = function(self, _ctx)
				stopped = stopped + 1
			end,
		})

		local seg = {
			type = "demo",
			executor = "life_exec",
			handler = function(run)
				return run.input
			end,
		}
		local line = pipeline({ pipe = { seg } })

		line:ensure_prepared()
		line:ensure_stopped()

		assert.are.equal(1, prepared)
		assert.are.equal(1, stopped)
	end)
end)
