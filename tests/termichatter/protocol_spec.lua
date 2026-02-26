--- Busted tests for protocol helpers

describe("termichatter.protocol", function()
	local protocol

	before_each(function()
		package.loaded["termichatter.protocol"] = nil
		package.loaded["termichatter"] = nil
		package.loaded["termichatter.init"] = nil
		package.loaded["termichatter.line"] = nil
		package.loaded["termichatter.segment"] = nil
		protocol = require("termichatter.protocol")
	end)

	it("queries completion state from protocol runs", function()
		local state = protocol.create_completion_state()

		assert.is_nil(protocol.query_completion(state, { random = true }))

		local hello = protocol.query_completion(state, protocol.completion_run("hello", "worker:a"))
		assert.are.equal("hello", hello.signal)
		assert.are.equal("worker:a", hello.name)
		assert.are.equal(1, hello.hello)
		assert.are.equal(0, hello.done)
		assert.is_false(hello.settled)

		local done = protocol.query_completion(state, protocol.completion_run("done", "worker:a"))
		assert.are.equal("done", done.signal)
		assert.are.equal(1, done.hello)
		assert.are.equal(1, done.done)
		assert.is_true(done.settled)
	end)

	it("provides signal-specific helpers", function()
		local hello = protocol.completion_run("hello")
		local done = protocol.completion_run("done")
		local shutdown = protocol.completion_run("shutdown")

		assert.is_true(protocol.is_completion_hello(hello))
		assert.is_true(protocol.is_completion_done(done))
		assert.is_true(protocol.is_completion_shutdown(shutdown))
		assert.is_true(protocol.is_completion_protocol(hello))
		assert.is_false(protocol.is_completion_protocol({}))
	end)

	it("supports alternate completion handlers without resolving line.done", function()
		local termichatter = require("termichatter")
		local query_segment = termichatter.segment.define({
			type = "query_only_completion",
			process_protocol = true,
			ensure_prepared = function(self, context)
				if not context.line._query_state then
					context.line._query_state = protocol.create_completion_state()
				end
			end,
			handler = function(run)
				local status = protocol.query_completion(run.line._query_state, run)
				if status and status.settled then
					run.line.query_settled = true
				end
				return nil
			end,
		})

		local line = termichatter({ pipe = { query_segment } })

		line:run(protocol.completion_run("hello", "worker:a"))
		line:run(protocol.completion_run("done", "worker:a"))

		assert.is_true(line.query_settled)
		assert.is_false(line.done:is_resolved())
	end)
end)
