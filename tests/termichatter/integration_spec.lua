--- Integration tests for termichatter end-to-end flows
local coop = require("coop")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("termichatter integration", function()
	local termichatter
	local consumer
	local processors
	local outputters

	before_each(function()
		package.loaded["termichatter"] = nil
		package.loaded["termichatter.consumer"] = nil
		package.loaded["termichatter.processors"] = nil
		package.loaded["termichatter.outputters"] = nil
		termichatter = require("termichatter")
		consumer = require("termichatter.consumer")
		processors = require("termichatter.processors")
		outputters = require("termichatter.outputters")
	end)

	describe("logger to buffer outputter", function()
		it("logs messages to a buffer", function()
			local bufnr = vim.api.nvim_create_buf(false, true)

			-- Create module with output queue
			local module = termichatter.makePipeline({ source = "test:app" })

			-- Create buffer outputter
			local bufOut = outputters.buffer({
				n = bufnr,
				queue = module.outputQueue,
			})

			-- Start outputter
			local outTask = coop.spawn(function()
				bufOut:start()
			end)

			-- Log some messages using module's log methods
			module.info("Starting up")
			module.debug("Debug info here")
			module.error("Something went wrong")

			-- Signal done
			module.outputQueue:push(termichatter.completion.done)

			-- Wait for outputter
			outTask:await(200, 10)

			-- Wait for vim.schedule
			vim.wait(100, function()
				local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
				return #lines >= 3
			end, 10)

			-- Check buffer contents
			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			local content = table.concat(lines, "\n")

			assert.is_truthy(content:match("Starting up"))
			assert.is_truthy(content:match("Debug info"))
			assert.is_truthy(content:match("Something went wrong"))

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)
	end)

	describe("logger through processor to outputter", function()
		it("filters by priority level", function()
			-- Create queues
			local inputQ = MpscQueue.new()
			local outputQ = MpscQueue.new()

			-- Create priority filter (only error and warn)
			local filter = processors.PriorityFilter({
				minLevel = 1,
				maxLevel = 2,
				inputQueue = inputQ,
				outputQueue = outputQ,
			})

			-- Start filter
			local filterTask = coop.spawn(function()
				filter:start()
			end)

			-- Create module that outputs to filter's input
			local module = termichatter.makePipeline()
			module.outputQueue = inputQ

			-- Log at different levels using module's methods
			module.error("Error message")
			module.warn("Warning message")
			module.info("Info message")
			module.debug("Debug message")

			-- Signal done
			inputQ:push(termichatter.completion.done)

			filterTask:await(200, 10)

			-- Collect results
			local results = {}
			for _ = 1, 3 do -- 2 messages + done
				local msg = coop.spawn(function()
					return outputQ:pop()
				end):await(50, 10)
				table.insert(results, msg)
			end

			-- Should only have error and warn
			assert.are.equal("error", results[1].priority)
			assert.are.equal("warn", results[2].priority)
			assert.are.equal("termichatter.completion.done", results[3].type)
		end)
	end)

	describe("nested module inheritance", function()
		it("child loggers inherit parent context", function()
			local captured = {}

			-- Create root module
			local root = termichatter.makePipeline({
				source = "myapp",
				environment = "production",
			})

			-- Create child module (use colon syntax for inheritance)
			local authModule = root:makePipeline({
				source = "myapp:auth",
				component = "authentication",
			})

			-- Add processor to authModule (after creation, on child's own pipeline)
			authModule:addProcessor("capture", function(msg)
				table.insert(captured, msg)
				return msg
			end)

			-- Set module on authModule and log
			authModule.module = "jwt"
			authModule.info("Token validated")

			-- Check captured message
			assert.are.equal(1, #captured)
			local msg = captured[1]

			assert.are.equal("myapp:auth", msg.source)
			assert.are.equal("jwt", msg.module)
			assert.are.equal("info", msg.priority)
			assert.is_not_nil(msg.time)
			assert.is_not_nil(msg.id)
		end)
	end)

	describe("async consumer pipeline", function()
		it("processes through multiple async stages", function()
			local inputQ = MpscQueue.new()
			local outputQ = MpscQueue.new()

			-- Create pipeline with enricher and filter
			local pipeline = consumer.createPipeline(
				{
					{
						handlers = {
							function(msg)
								-- CloudEvents enrichment
								msg.specversion = "1.0"
								msg.id = msg.id or termichatter.uuid()
								return msg
							end,
						},
					},
					{
						handlers = {
							function(msg)
								-- Filter out debug in production
								if msg.priority == "debug" then
									return nil
								end
								return msg
							end,
						},
					},
					{
						handlers = {
							function(msg)
								-- Add processing timestamp
								msg.processedAt = vim.uv.hrtime()
								return msg
							end,
						},
					},
				},
				inputQ,
				outputQ
			)

			local tasks = pipeline:start()

			-- Send messages
			pipeline:push({ priority = "error", message = "Error!" })
			pipeline:push({ priority = "debug", message = "Debug" })
			pipeline:push({ priority = "info", message = "Info" })
			pipeline:finish()

			-- Wait for completion
			for _, task in ipairs(tasks) do
				task:await(300, 10)
			end

			-- Collect results
			local results = {}
			for _ = 1, 3 do -- 2 messages + done
				local msg = coop.spawn(function()
					return outputQ:pop()
				end):await(50, 10)
				table.insert(results, msg)
			end

			-- Should have error, info, done (debug filtered)
			assert.are.equal("error", results[1].priority)
			assert.is_not_nil(results[1].specversion)
			assert.is_not_nil(results[1].processedAt)

			assert.are.equal("info", results[2].priority)
			assert.is_not_nil(results[2].specversion)

			assert.are.equal("termichatter.shutdown", results[3].type)
		end)
	end)

	describe("multiple producers single consumer", function()
		it("handles concurrent logging from multiple loggers", function()
			local module = termichatter.makePipeline()
			local received = {}

			-- Start consumer
			local consumerTask = coop.spawn(function()
				for _ = 1, 10 do -- Expect 10 messages
					local msg = module.outputQueue:pop()
					if msg.type == "termichatter.completion.done" then
						break
					end
					table.insert(received, msg)
				end
			end)

			-- Create child modules for each producer
			local modA = module:makePipeline({ module = "A" })
			local modB = module:makePipeline({ module = "B" })
			local modC = module:makePipeline({ module = "C" })
			-- Point their output to parent's outputQueue
			modA.outputQueue = module.outputQueue
			modB.outputQueue = module.outputQueue
			modC.outputQueue = module.outputQueue

			-- Log from each
			for i = 1, 3 do
				modA.info("Message from A: " .. i)
				modB.info("Message from B: " .. i)
				modC.info("Message from C: " .. i)
			end

			-- Signal done
			module.outputQueue:push(termichatter.completion.done)

			consumerTask:await(300, 10)

			-- Should have received 9 messages
			assert.are.equal(9, #received)

			-- Check we got messages from all modules
			local modules = {}
			for _, msg in ipairs(received) do
				modules[msg.module] = (modules[msg.module] or 0) + 1
			end

			assert.are.equal(3, modules["A"])
			assert.are.equal(3, modules["B"])
			assert.are.equal(3, modules["C"])
		end)
	end)

	describe("fanout to multiple outputs", function()
		it("writes to multiple destinations", function()
			local inputQ = MpscQueue.new()

			-- Create mock outputters
			local buffer1 = {}
			local buffer2 = {}

			local mock1 = {
				queue = MpscQueue.new(),
				write = function(_, msg)
					table.insert(buffer1, msg)
				end,
			}
			local mock2 = {
				queue = MpscQueue.new(),
				write = function(_, msg)
					table.insert(buffer2, msg)
				end,
			}

			local fan = outputters.fanout({
				outputters = { mock1, mock2 },
				queue = inputQ,
			})

			local task = coop.spawn(function()
				fan:start()
			end)

			inputQ:push({ message = "broadcast 1" })
			inputQ:push({ message = "broadcast 2" })
			inputQ:push({ type = "termichatter.completion.done" })

			task:await(200, 10)

			-- Both should have received the messages
			assert.are.equal(2, #buffer1)
			assert.are.equal(2, #buffer2)
			assert.are.equal("broadcast 1", buffer1[1].message)
			assert.are.equal("broadcast 2", buffer2[2].message)
		end)
	end)
end)
