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
		package.loaded["termichatter.protocol"] = nil
		package.loaded["termichatter.resolver"] = nil
		termichatter = require("termichatter")
	end)

	describe("timestamper", function()
		it("adds time field to message", function()
			local msg = { message = "test" }
			-- v1 compat: direct function call
			local result = termichatter.timestamper(msg)
			assert.is_not_nil(result.time)
			assert.is_number(result.time)
		end)

		it("preserves existing time", function()
			local msg = { message = "test", time = 12345 }
			local result = termichatter.timestamper(msg)
			assert.are.equal(12345, result.time)
		end)
	end)

	describe("uuid", function()
		it("generates valid uuid format", function()
			local id = termichatter.uuid()
			assert.is_string(id)
			assert.is_truthy(id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"))
		end)

		it("generates unique ids", function()
			local ids = {}
			for _ = 1, 100 do
				local id = termichatter.uuid()
				assert.is_nil(ids[id])
				ids[id] = true
			end
		end)
	end)

	describe("cloudevents", function()
		it("enriches message with id", function()
			local msg = { message = "test" }
			local result = termichatter.cloudevents(msg, {})
			assert.is_not_nil(result.id)
			assert.are.equal("1.0", result.specversion)
		end)

		it("uses source from context", function()
			local msg = { message = "test" }
			local ctx = { source = "myapp:module" }
			local result = termichatter.cloudevents(msg, ctx)
			assert.are.equal("myapp:module", result.source)
		end)

		it("preserves existing fields", function()
			local msg = { message = "test", id = "my-id", source = "my-source" }
			local result = termichatter.cloudevents(msg, { source = "other" })
			assert.are.equal("my-id", result.id)
			assert.are.equal("my-source", result.source)
		end)
	end)

	describe("module_filter", function()
		it("passes messages without filter", function()
			local msg = { source = "test" }
			local result = termichatter.module_filter(msg, {})
			assert.are.same(msg, result)
		end)

		it("filters by string pattern", function()
			local msg1 = { source = "myapp:auth" }
			local msg2 = { source = "myapp:db" }
			local ctx = { filter = "auth" }

			assert.is_not_nil(termichatter.module_filter(msg1, ctx))
			assert.is_nil(termichatter.module_filter(msg2, ctx))
		end)

		it("filters by function", function()
			local ctx = {
				filter = function(msg)
					return msg.priority == "error"
				end,
			}

			local msg1 = { priority = "error" }
			local msg2 = { priority = "debug" }

			assert.is_not_nil(termichatter.module_filter(msg1, ctx))
			assert.is_nil(termichatter.module_filter(msg2, ctx))
		end)
	end)

	describe("log", function()
		it("processes message through pipeline", function()
			local module = termichatter:new({ source = "test:module" })
			module.pipe = require("termichatter.pipe").new({ "timestamper", "cloudevent" })

			module:log({ message = "hello" })

			local received = nil
			local task = coop.spawn(function()
				received = module.outputQueue:pop()
			end)
			task:await(100, 10)

			assert.is_not_nil(received)
			assert.is_not_nil(received.time)
			assert.is_not_nil(received.id)
			assert.are.equal("test:module", received.source)
		end)

		it("stops when handler returns false", function()
			local module = termichatter:new()
			local reached = false

			module:addProcessor("blocker", function()
				return false
			end)
			module:addProcessor("after", function(run)
				reached = true
				return run.input
			end)

			module:log({})
			assert.is_false(reached)
		end)
	end)

	describe("new", function()
		it("creates new module with own pipeline", function()
			local module = termichatter:new()
			assert.is_not_nil(module.pipe)
			assert.is_not_nil(module.outputQueue)
		end)

		it("inherits from parent", function()
			local module = termichatter:new()
			assert.is_function(module.log)
		end)

		it("accepts config overrides", function()
			local module = termichatter:new({
				source = "custom:source",
				customField = "value",
			})
			assert.are.equal("custom:source", module.source)
			assert.are.equal("value", module.customField)
		end)

		it("accepts multiple config tables", function()
			local module = termichatter:new({ source = "first" }, { source = "second", extra = true })
			assert.are.equal("second", module.source)
			assert.is_true(module.extra)
		end)
	end)

	describe("addProcessor", function()
		it("adds handler to pipeline", function()
			local module = termichatter:new()
			local originalLen = #module.pipe

			module:addProcessor("myHandler", function(run)
				return run.input
			end)

			assert.are.equal(originalLen + 1, #module.pipe)
		end)

		it("inserts at specified position", function()
			local module = termichatter:new()
			module:addProcessor("first", function() end, 1)
			assert.are.equal("first", module.pipe[1])
		end)
	end)

	describe("log methods", function()
		it("module has priority methods", function()
			local module = termichatter:new()
			assert.is_function(module.error)
			assert.is_function(module.warn)
			assert.is_function(module.info)
			assert.is_function(module.debug)
			assert.is_function(module.trace)
		end)

		it("logs string messages", function()
			local module = termichatter:new({ source = "test" })
			local captured = nil

			module:addProcessor("capture", function(run)
				captured = run.input
				return run.input
			end)

			module:info("hello world")

			assert.is_not_nil(captured)
			assert.are.equal("hello world", captured.message)
			assert.are.equal("test", captured.source)
		end)

		it("priority methods set priority field", function()
			local module = termichatter:new()
			local captured = nil

			module:addProcessor("capture", function(run)
				captured = run.input
				return run.input
			end)

			module:error("error message")

			assert.are.equal("error", captured.priority)
			assert.are.equal(1, captured.priorityLevel)
		end)
	end)

	describe("drivers", function()
		describe("interval", function()
			it("creates driver with start/stop", function()
				local driver = termichatter.drivers.interval(100, function() end)
				assert.is_function(driver.start)
				assert.is_function(driver.stop)
			end)

			it("calls callback on interval", function()
				local count = 0
				local driver = termichatter.drivers.interval(10, function()
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
				local driver = termichatter.drivers.rescheduler({ interval = 100 }, function() end)
				assert.is_function(driver.start)
				assert.is_function(driver.stop)
			end)

			it("calls callback", function()
				local called = false
				local driver = termichatter.drivers.rescheduler({ interval = 10 }, function()
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
		it("hello message has correct type", function()
			assert.are.equal("termichatter.completion.hello", termichatter.completion.hello.type)
		end)

		it("done message has correct type", function()
			assert.are.equal("termichatter.completion.done", termichatter.completion.done.type)
		end)
	end)
end)
