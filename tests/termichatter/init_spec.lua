--- Busted tests for termichatter core module
local coop = require("coop")
local sleep = require("coop.uv-utils").sleep
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("termichatter", function()
	local termichatter

	before_each(function()
		package.loaded["termichatter"] = nil
		termichatter = require("termichatter")
	end)

	describe("timestamper", function()
		it("adds time field to message", function()
			local msg = { message = "test" }
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
			local module = termichatter.makePipeline({ source = "test:module" })
			local processed = nil

			-- Add a capture handler at end
			module:addProcessor("capture", function(msg)
				processed = msg
				return msg
			end)

			termichatter.log({ message = "hello" }, module)

			assert.is_not_nil(processed)
			assert.is_not_nil(processed.time)
			assert.is_not_nil(processed.id)
			assert.are.equal("test:module", processed.source)
		end)

		it("respects pipeStep", function()
			local module = termichatter.makePipeline()
			local steps = {}

			module.step1 = function(msg)
				table.insert(steps, 1)
				return msg
			end
			module.step2 = function(msg)
				table.insert(steps, 2)
				return msg
			end
			module.pipeline = { "step1", "step2" }

			-- Start from step 2
			termichatter.log({ pipeStep = 2 }, module)
			assert.are.same({ 2 }, steps)
		end)

		it("stops when handler returns nil", function()
			local module = termichatter.makePipeline()
			local reached = false

			module.blocker = function()
				return nil
			end
			module.after = function(msg)
				reached = true
				return msg
			end
			module.pipeline = { "blocker", "after" }

			termichatter.log({}, module)
			assert.is_false(reached)
		end)
	end)

	describe("makePipeline", function()
		it("creates new module with own pipeline", function()
			local module = termichatter.makePipeline()
			assert.is_not_nil(module.pipeline)
			assert.is_not_nil(module.queues)
			assert.is_not_nil(module.outputQueue)
		end)

		it("inherits from parent", function()
			local module = termichatter.makePipeline()
			assert.is_function(module.timestamper)
			assert.is_function(module.cloudevents)
			assert.is_function(module.log)
		end)

		it("accepts config overrides", function()
			local module = termichatter.makePipeline({
				source = "custom:source",
				customField = "value",
			})
			assert.are.equal("custom:source", module.source)
			assert.are.equal("value", module.customField)
		end)
	end)

	describe("addProcessor", function()
		it("adds handler to pipeline", function()
			local module = termichatter.makePipeline()
			local originalLen = #module.pipeline

			module:addProcessor("myHandler", function(msg)
				return msg
			end)

			assert.are.equal(originalLen + 1, #module.pipeline)
			assert.is_function(module.myHandler)
		end)

		it("inserts at specified position", function()
			local module = termichatter.makePipeline()
			module:addProcessor("first", function() end, 1)
			assert.are.equal("first", module.pipeline[1])
		end)
	end)

	describe("baseLogger", function()
		it("creates callable logger", function()
			local module = termichatter.makePipeline()
			local logger = module:baseLogger({ source = "test" })
			assert.is_table(logger)
			-- Verify it's callable via metatable
			local mt = getmetatable(logger)
			assert.is_not_nil(mt)
			assert.is_function(mt.__call)
		end)

		it("has priority methods", function()
			local module = termichatter.makePipeline()
			local logger = module:baseLogger()
			assert.is_function(logger.error)
			assert.is_function(logger.warn)
			assert.is_function(logger.info)
			assert.is_function(logger.debug)
			assert.is_function(logger.trace)
		end)

		it("logs string messages", function()
			local module = termichatter.makePipeline()
			local captured = nil

			module:addProcessor("capture", function(msg)
				captured = msg
				return msg
			end)

			local logger = module:baseLogger({ source = "test" })
			logger("hello world")

			assert.is_not_nil(captured)
			assert.are.equal("hello world", captured.message)
			assert.are.equal("test", captured.source)
		end)

		it("logs structured messages", function()
			local module = termichatter.makePipeline()
			local captured = nil

			module:addProcessor("capture", function(msg)
				captured = msg
				return msg
			end)

			local logger = module:baseLogger({})
			logger({ message = "test", data = { key = "value" } })

			assert.is_not_nil(captured)
			assert.are.equal("test", captured.message)
			assert.are.same({ key = "value" }, captured.data)
		end)

		it("priority methods set priority field", function()
			local module = termichatter.makePipeline()
			local captured = nil

			module:addProcessor("capture", function(msg)
				captured = msg
				return msg
			end)

			local logger = module:baseLogger({})
			logger.error("error message")

			assert.are.equal("error", captured.priority)
			assert.are.equal(1, captured.priorityLevel)
		end)

		it("inherits from parent module", function()
			local parent = termichatter.makePipeline({ source = "parent:source" })
			local captured = nil

			parent:addProcessor("capture", function(msg)
				captured = msg
				return msg
			end)

			local logger = parent:baseLogger({ module = "child" })
			logger("test")

			assert.are.equal("parent:source", captured.source)
			assert.are.equal("child", captured.module)
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
end)
