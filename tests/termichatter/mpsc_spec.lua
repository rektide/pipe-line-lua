--- Busted tests for explicit mpsc_handoff behavior and ergonomics
local coop = require("coop")

describe("termichatter.mpsc", function()
	local termichatter, Pipe

	before_each(function()
		package.loaded["termichatter"] = nil
		package.loaded["termichatter.init"] = nil
		package.loaded["termichatter.registry"] = nil
		package.loaded["termichatter.line"] = nil
		package.loaded["termichatter.run"] = nil
		package.loaded["termichatter.pipe"] = nil
		package.loaded["termichatter.segment"] = nil
		package.loaded["termichatter.consumer"] = nil
		package.loaded["termichatter.protocol"] = nil
		termichatter = require("termichatter")
		Pipe = require("termichatter.pipe")
	end)

	local function pop_with_timeout(queue, timeout)
		return coop.spawn(function()
			return queue:pop()
		end):await(timeout or 200, 10)
	end

	it("runs async with named mpsc_handoff via normal line:log", function()
		local app = termichatter()
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
		local app = termichatter()
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
		local app = termichatter({ autoStartConsumers = false })
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
		local app = termichatter({ autoStartConsumers = false })
		local seen = false
		local handoff = termichatter.segment.mpsc_handoff()

		app:addSegment("capture", function(run)
			seen = true
			return run.input
		end)
		app.pipe = Pipe.new({ handoff, "capture" })

		app:log({ message = "manual" })

		local envelope = pop_with_timeout(handoff.queue)
		local continuation = envelope[termichatter.segment.HANDOFF_FIELD]
		continuation:next()

		local out = pop_with_timeout(app.output)
		assert.is_true(seen)
		assert.are.equal("manual", out.message)
	end)
end)
