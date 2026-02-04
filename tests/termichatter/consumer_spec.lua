--- Busted tests for termichatter consumer module
local coop = require("coop")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("termichatter.consumer", function()
	local consumer

	before_each(function()
		package.loaded["termichatter.consumer"] = nil
		consumer = require("termichatter.consumer")
	end)

	describe("create", function()
		it("creates consumer with queues", function()
			local inputQ = MpscQueue.new()
			local outputQ = MpscQueue.new()

			local c = consumer.create({
				inputQueue = inputQ,
				outputQueue = outputQ,
			})

			assert.are.equal(inputQ, c.inputQueue)
			assert.are.equal(outputQ, c.outputQueue)
		end)

		it("processes messages through handlers", function()
			local inputQ = MpscQueue.new()
			local outputQ = MpscQueue.new()

			local c = consumer.create({
				inputQueue = inputQ,
				outputQueue = outputQ,
				handlers = {
					function(msg)
						msg.step1 = true
						return msg
					end,
					function(msg)
						msg.step2 = true
						return msg
					end,
				},
			})

			local result = c:process({ original = true })

			assert.is_true(result.original)
			assert.is_true(result.step1)
			assert.is_true(result.step2)
		end)

		it("stops processing if handler returns nil", function()
			local inputQ = MpscQueue.new()

			local c = consumer.create({
				inputQueue = inputQ,
				handlers = {
					function(msg)
						return nil
					end,
					function(msg)
						msg.shouldNotRun = true
						return msg
					end,
				},
			})

			local result = c:process({ test = true })

			assert.is_nil(result)
		end)

		it("consumes from queue async", function()
			local inputQ = MpscQueue.new()
			local outputQ = MpscQueue.new()

			local c = consumer.create({
				inputQueue = inputQ,
				outputQueue = outputQ,
				handlers = {
					function(msg)
						msg.processed = true
						return msg
					end,
				},
			})

			local task = c:spawn()

			inputQ:push({ message = "test" })
			inputQ:push({ type = "termichatter.completion.done" })

			task:await(200, 10)

			-- Output queue should have processed message + done
			local msg1 = coop.spawn(function()
				return outputQ:pop()
			end):await(50, 10)

			assert.is_true(msg1.processed)
			assert.are.equal("test", msg1.message)
		end)

		it("forwards done message to output", function()
			local inputQ = MpscQueue.new()
			local outputQ = MpscQueue.new()

			local c = consumer.create({
				inputQueue = inputQ,
				outputQueue = outputQ,
			})

			local task = c:spawn()

			inputQ:push({ type = "termichatter.completion.done" })

			task:await(100, 10)

			local msg = coop.spawn(function()
				return outputQ:pop()
			end):await(50, 10)

			assert.are.equal("termichatter.completion.done", msg.type)
		end)

		it("adds handlers dynamically", function()
			local inputQ = MpscQueue.new()
			local c = consumer.create({ inputQueue = inputQ, handlers = {} })

			c:addHandler(function(msg)
				msg.added = true
				return msg
			end)

			local result = c:process({})
			assert.is_true(result.added)
		end)
	end)

	describe("createPipeline", function()
		it("creates connected consumers", function()
			local inputQ = MpscQueue.new()
			local outputQ = MpscQueue.new()

			local pipeline = consumer.createPipeline(
				{
					{
						handlers = {
							function(msg)
								msg.stage1 = true
								return msg
							end,
						},
					},
					{
						handlers = {
							function(msg)
								msg.stage2 = true
								return msg
							end,
						},
					},
				},
				inputQ,
				outputQ
			)

			assert.are.equal(2, #pipeline.consumers)
			assert.are.equal(2, #pipeline.queues) -- input + intermediate
		end)

		it("processes messages through all stages", function()
			local inputQ = MpscQueue.new()
			local outputQ = MpscQueue.new()

			local pipeline = consumer.createPipeline(
				{
					{
						handlers = {
							function(msg)
								msg.stage1 = true
								return msg
							end,
						},
					},
					{
						handlers = {
							function(msg)
								msg.stage2 = true
								return msg
							end,
						},
					},
				},
				inputQ,
				outputQ
			)

			local tasks = pipeline:start()

			pipeline:push({ message = "test" })
			pipeline:finish()

			-- Wait for all consumers to complete
			for _, task in ipairs(tasks) do
				task:await(200, 10)
			end

			-- Check output
			local msg = coop.spawn(function()
				return outputQ:pop()
			end):await(50, 10)

			assert.are.equal("test", msg.message)
			assert.is_true(msg.stage1)
			assert.is_true(msg.stage2)
		end)

		it("filters messages between stages", function()
			local inputQ = MpscQueue.new()
			local outputQ = MpscQueue.new()

			local pipeline = consumer.createPipeline(
				{
					{
						handlers = {
							function(msg)
								if msg.keep then
									return msg
								end
								return nil
							end,
						},
					},
					{
						handlers = {
							function(msg)
								msg.passedFilter = true
								return msg
							end,
						},
					},
				},
				inputQ,
				outputQ
			)

			local tasks = pipeline:start()

			pipeline:push({ message = "kept", keep = true })
			pipeline:push({ message = "filtered", keep = false })
			pipeline:push({ message = "also kept", keep = true })
			pipeline:finish()

			for _, task in ipairs(tasks) do
				task:await(200, 10)
			end

			-- Should only get 2 messages + done
			local results = {}
			for _ = 1, 3 do
				local msg = coop.spawn(function()
					return outputQ:pop()
				end):await(50, 10)
				table.insert(results, msg)
			end

			-- First two should be the kept messages
			assert.are.equal("kept", results[1].message)
			assert.is_true(results[1].passedFilter)
			assert.are.equal("also kept", results[2].message)
			assert.is_true(results[2].passedFilter)
			-- Third should be done
			assert.are.equal("termichatter.completion.done", results[3].type)
		end)
	end)
end)
