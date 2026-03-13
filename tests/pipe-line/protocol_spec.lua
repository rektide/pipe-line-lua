--- Busted tests for protocol helpers

describe("pipe-line.protocol", function()
	local protocol

	before_each(function()
		package.loaded["pipe-line.protocol"] = nil
		package.loaded["pipe-line"] = nil
		package.loaded["pipe-line.init"] = nil
		package.loaded["pipe-line.line"] = nil
		package.loaded["pipe-line.segment"] = nil
		protocol = require("pipe-line.protocol")
	end)

	it("applies completion state from protocol runs", function()
		local state = {}
		state = protocol.completion.ensure_completion_state(state)
		assert.is_false(state.settled)
		assert.is_not_nil(state.stopped)
		assert.is_function(state.stopped.await)

		assert.is_false(protocol.completion.apply(state, { random = true }))

		assert.is_true(protocol.completion.apply(state, protocol.completion.completion_run("hello", "worker:a")))
		assert.are.equal("hello", state.signal)
		assert.are.equal("worker:a", state.name)
		assert.are.equal(1, state.hello)
		assert.are.equal(0, state.done)
		assert.is_false(state.settled)

		assert.is_true(protocol.completion.apply(state, protocol.completion.completion_run("done", "worker:a")))
		assert.are.equal("done", state.signal)
		assert.are.equal(1, state.hello)
		assert.are.equal(1, state.done)
		assert.is_true(state.settled)
	end)

	it("ensure_completion_state initializes sparse payloads", function()
		local state = { done = 4 }
		state = protocol.completion.ensure_completion_state(state)

		assert.are.equal(0, state.hello)
		assert.are.equal(4, state.done)
		assert.is_false(state.settled)
		assert.is_not_nil(state.stopped)
		assert.is_function(state.stopped.complete)
	end)

	it("provides signal-specific helpers", function()
		local hello = protocol.completion.completion_run("hello")
		local done = protocol.completion.completion_run("done")
		local shutdown = protocol.completion.completion_run("shutdown")

		assert.is_true(protocol.completion.is_completion_hello(hello))
		assert.is_true(protocol.completion.is_completion_done(done))
		assert.is_true(protocol.completion.is_completion_shutdown(shutdown))
		assert.is_true(protocol.completion.is_completion_protocol(hello))
		assert.is_false(protocol.completion.is_completion_protocol({}))
	end)

	it("supports alternate completion handlers without resolving segment completion", function()
		local pipeline = require("pipe-line")
		local query_segment = pipeline.segment.define({
			type = "query_only_completion",
			process_protocol = true,
			ensure_prepared = function(self, context)
				if not context.line.completion_state then
					context.line.completion_state = protocol.completion.ensure_completion_state({})
				end
			end,
			handler = function(run)
				if protocol.completion.apply(run.line.completion_state, run) and run.line.completion_state.settled then
					run.line.query_settled = true
				end
				return nil
			end,
		})

		local line = pipeline({ pipe = { query_segment } })

		line:run(protocol.completion.completion_run("hello", "worker:a"))
		line:run(protocol.completion.completion_run("done", "worker:a"))

		assert.is_true(line.query_settled)
		local completions = line:select_segments("query_only_completion")
		assert.are.equal(1, #completions)
		assert.is_nil(completions[1].stopped)
	end)
end)
