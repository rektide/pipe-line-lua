local helper = require("tests.test_helper")

describe("pipe-line.protocol completion", function()
	local pipeline
	local protocol

	before_each(function()
		helper.setup_vim()
		pipeline = helper.fresh_pipeline()
		protocol = require("pipe-line.protocol")
	end)

	it("tracks completion state counters", function()
		local state = protocol.completion.ensure_completion_state({})
		assert.is_false(state.settled)

		assert.is_true(protocol.completion.apply(state, protocol.completion.completion_run("hello", "worker:a")))
		assert.are.equal(1, state.hello)
		assert.are.equal(0, state.done)
		assert.is_false(state.settled)

		assert.is_true(protocol.completion.apply(state, protocol.completion.completion_run("done", "worker:a")))
		assert.are.equal(1, state.done)
		assert.is_true(state.settled)
	end)

	it("settles line.done via completion segment protocol runs", function()
		local line = pipeline({ pipe = { pipeline.segment.completion } })
		local completion = line:select_segments("completion")[1]
		line:ensure_prepared()
		line:run(protocol.completion.completion_run("done", "worker:a"))
		assert.is_true(completion.stopped.done)
	end)
end)
