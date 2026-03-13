--- Busted tests for explicit mpsc_handoff behavior and ergonomics
local coop = require("coop")

describe("pipe-line.mpsc", function()
	local pipeline, Pipe

	before_each(function()
		package.loaded["pipe-line"] = nil
		package.loaded["pipe-line.init"] = nil
		package.loaded["pipe-line.registry"] = nil
		package.loaded["pipe-line.line"] = nil
		package.loaded["pipe-line.run"] = nil
		package.loaded["pipe-line.pipe"] = nil
		package.loaded["pipe-line.segment"] = nil
		package.loaded["pipe-line.consumer"] = nil
		package.loaded["pipe-line.protocol"] = nil
		pipeline = require("pipe-line")
		Pipe = require("pipe-line.pipe")
	end)

	local function pop_with_timeout(queue, timeout)
		return coop.spawn(function()
			return queue:pop()
		end):await(timeout or 200, 10)
	end

	it("runs async with named mpsc_handoff via normal line:log", function()
		local app = pipeline()
		local seen = {}

		app:addSegment("capture", function(run)
			table.insert(seen, run.input.message)
			return run.input
		end)
		app.pipe = Pipe.new({ "mpsc_handoff", "capture" })

		app:log({ message = "auto" })
		local out = pop_with_timeout(app.output)

		assert.are.equal("auto", out.message)
		assert.are.same({ "auto" }, seen)
		app:close():await(200, 10)
	end)

	it("auto-initializes consumer when first handoff executes", function()
		local app = pipeline()
		local seen = {}

		app:addSegment("capture", function(run)
			table.insert(seen, run.input.message)
			return run.input
		end)
		app.pipe = Pipe.new({ "mpsc_handoff", "capture" })

		assert.is_nil(app._consumer_task)

		app:log({ message = "first-run" })
		local out = pop_with_timeout(app.output)

		assert.are.equal("first-run", out.message)
		assert.are.same({ "first-run" }, seen)
		assert.is_table(app._consumer_task)
		assert.is_true(#app._consumer_task >= 1)

		app:close():await(200, 10)
	end)

	it("delays processing until explicit prepare_segments when autoStartConsumers is false", function()
		local app = pipeline({ autoStartConsumers = false })
		local seen = {}

		app:addSegment("capture", function(run)
			table.insert(seen, run.input.message)
			return run.input
		end)
		app.pipe = Pipe.new({ "mpsc_handoff", "capture" })

		app:log({ message = "delayed" })

		assert.are.equal("mpsc_handoff", app.pipe[1].type)
		assert.is_false(app.pipe[1].queue:empty())
		assert.are.same({}, seen)

		app:prepare_segments()
		local out = pop_with_timeout(app.output)

		assert.are.equal("delayed", out.message)
		assert.are.same({ "delayed" }, seen)
		app:close():await(200, 10)
	end)

	it("supports manual continuation by popping handoff queue payload", function()
		local app = pipeline({ autoStartConsumers = false })
		local seen = false
		local handoff = pipeline.segment.mpsc_handoff()

		app:addSegment("capture", function(run)
			seen = true
			return run.input
		end)
		app.pipe = Pipe.new({ handoff, "capture" })

		app:log({ message = "manual" })

		local envelope = pop_with_timeout(handoff.queue)
		local continuation = envelope[pipeline.segment.HANDOFF_FIELD]
		continuation:next()

		local out = pop_with_timeout(app.output)
		assert.is_true(seen)
		assert.are.equal("manual", out.message)
	end)
end)
