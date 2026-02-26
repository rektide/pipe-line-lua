--- Busted tests for termichatter core module
local coop = require("coop")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("termichatter", function()
	local termichatter

	before_each(function()
		package.loaded["termichatter"] = nil
		package.loaded["termichatter.init"] = nil
		package.loaded["termichatter.registry"] = nil
		package.loaded["termichatter.line"] = nil
		package.loaded["termichatter.run"] = nil
		package.loaded["termichatter.pipe"] = nil
		package.loaded["termichatter.segment"] = nil
		package.loaded["termichatter.consumer"] = nil
		package.loaded["termichatter.log"] = nil
		package.loaded["termichatter.protocol"] = nil
		package.loaded["termichatter.resolver"] = nil
		termichatter = require("termichatter")
	end)

	describe("callable module", function()
		it("creates a Line when called", function()
			local app = termichatter({ source = "myapp" })
			assert.is_not_nil(app.pipe)
			assert.is_not_nil(app.output)
			assert.are.equal("myapp", app.source)
		end)

		it("uses default registry", function()
			local app = termichatter()
			assert.is_not_nil(app.registry)
		end)
	end)

	describe("log", function()
		it("processes message through pipeline", function()
			local app = termichatter({ source = "test:module" })
			app.pipe = require("termichatter.pipe").new({ "timestamper", "cloudevent" })

			app:log({ message = "hello" })

			local received = nil
			local task = coop.spawn(function()
				received = app.output:pop()
			end)
			task:await(100, 10)

			assert.is_not_nil(received)
			assert.is_not_nil(received.time)
			assert.is_not_nil(received.id)
			assert.are.equal("test:module", received.source)
		end)

		it("stops when handler returns false", function()
			local app = termichatter()
			local reached = false

			app:addSegment("blocker", function()
				return false
			end)
			app:addSegment("after", function(run)
				reached = true
				return run.input
			end)

			app:log({})
			assert.is_false(reached)
		end)
	end)

	describe("child and fork", function()
		it("creates thin child that shares output", function()
			local app = termichatter({ source = "root" })
			local child = app:child("auth")
			assert.are.equal(app.output, child.output)
			assert.are.equal("root:auth", child:full_source())
		end)

		it("creates fork with independent output", function()
			local app = termichatter({ source = "root" })
			local forked = app:fork("worker")
			assert.are_not.equal(app.output, forked.output)
			assert.are.equal("root:worker", forked:full_source())
		end)
	end)

	describe("addSegment", function()
		it("adds handler to pipeline", function()
			local app = termichatter()
			local originalLen = #app.pipe

			app:addSegment("myHandler", function(run)
				return run.input
			end)

			assert.are.equal(originalLen + 1, #app.pipe)
		end)

		it("inserts at specified position", function()
			local app = termichatter()
			app:addSegment("first", function() end, 1)
			assert.are.equal("first", app.pipe[1])
		end)
	end)

		describe("log methods", function()
		it("line has priority methods", function()
			local app = termichatter()
			assert.is_function(app.error)
			assert.is_function(app.warn)
			assert.is_function(app.info)
			assert.is_function(app.debug)
			assert.is_function(app.trace)
		end)

		it("logs string messages", function()
			local app = termichatter({ source = "test" })
			local captured = nil

			app:addSegment("capture", function(run)
				captured = run.input
				return run.input
			end)

			app:info("hello world")

			assert.is_not_nil(captured)
			assert.are.equal("hello world", captured.message)
			assert.are.equal("test", captured.source)
		end)

		it("priority methods set numeric level", function()
			local app = termichatter()
			local captured = nil

			app:addSegment("capture", function(run)
				captured = run.input
				return run.input
			end)

			app:error("error message")

			assert.are.equal(10, captured.level)
		end)
	end)

	describe("drivers", function()
		describe("interval", function()
			it("creates driver with start/stop", function()
				local driver = termichatter.driver.interval(100, function() end)
				assert.is_function(driver.start)
				assert.is_function(driver.stop)
			end)

			it("calls callback on interval", function()
				local count = 0
				local driver = termichatter.driver.interval(10, function()
					count = count + 1
				end)

				driver.start()
				vim.wait(50, function()
					return count >= 3
				end, 5)
				driver.stop()

				assert.is_true(count >= 3)
			end)
		end)

		describe("rescheduler", function()
			it("creates driver with start/stop", function()
				local driver = termichatter.driver.rescheduler({ interval = 100 }, function() end)
				assert.is_function(driver.start)
				assert.is_function(driver.stop)
			end)

			it("calls callback", function()
				local called = false
				local driver = termichatter.driver.rescheduler({ interval = 10 }, function()
					called = true
					return true
				end)

				driver.start()
				vim.wait(50, function()
					return called
				end, 5)
				driver.stop()

				assert.is_true(called)
			end)
		end)
	end)

	describe("completion protocol", function()
		it("exports line completion signals", function()
			assert.are.equal("hello", termichatter.protocol.completion.COMPLETION_HELLO)
			assert.are.equal("done", termichatter.protocol.completion.COMPLETION_DONE)
			assert.are.equal("shutdown", termichatter.protocol.completion.COMPLETION_SHUTDOWN)
		end)
	end)
end)
