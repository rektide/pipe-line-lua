--- Busted tests for termichatter processors
local coop = require("coop")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("termichatter.processors", function()
	local processors

	before_each(function()
		package.loaded["termichatter.processors"] = nil
		processors = require("termichatter.processors")
	end)

	describe("ModuleFilter", function()
		it("creates processor with queues", function()
			local filter = processors.ModuleFilter()
			assert.is_not_nil(filter.inputQueue)
			assert.is_not_nil(filter.outputQueue)
		end)

		it("passes all messages by default", function()
			local filter = processors.ModuleFilter()

			local msg1 = filter:process({ source = "any:module" })
			local msg2 = filter:process({ source = "other:thing" })

			assert.is_not_nil(msg1)
			assert.is_not_nil(msg2)
		end)

		it("filters by pattern", function()
			local filter = processors.ModuleFilter({
				patterns = { "^myapp:" },
			})

			local msg1 = filter:process({ source = "myapp:auth" })
			local msg2 = filter:process({ source = "other:db" })

			assert.is_not_nil(msg1)
			assert.is_nil(msg2)
		end)

		it("excludes by pattern", function()
			local filter = processors.ModuleFilter({
				patterns = { ".*" },
				exclude = { "verbose" },
			})

			local msg1 = filter:process({ source = "myapp:auth" })
			local msg2 = filter:process({ source = "myapp:verbose:stuff" })

			assert.is_not_nil(msg1)
			assert.is_nil(msg2)
		end)

		it("processes async queue", function()
			local inputQ = MpscQueue.new()
			local outputQ = MpscQueue.new()
			local filter = processors.ModuleFilter({
				patterns = { "^keep" },
				inputQueue = inputQ,
				outputQueue = outputQ,
			})

			local consumer = coop.spawn(function()
				filter:start()
			end)

			-- Push messages
			inputQ:push({ source = "keep:this" })
			inputQ:push({ source = "drop:this" })
			inputQ:push({ source = "keep:also" })
			inputQ:push({ type = "termichatter.completion.done" })

			consumer:await(100, 10)

			-- Should have 2 messages + done
			local results = {}
			while not outputQ:empty() do
				local msg = coop.spawn(function()
					return outputQ:pop()
				end):await(50, 10)
				table.insert(results, msg)
			end

			-- Filter should have passed 2 messages + done
			assert.are.equal(3, #results)
			assert.are.equal("keep:this", results[1].source)
			assert.are.equal("keep:also", results[2].source)
		end)

		it("updates patterns dynamically", function()
			local filter = processors.ModuleFilter({ patterns = { "^old" } })

			assert.is_not_nil(filter:process({ source = "old:module" }))
			assert.is_nil(filter:process({ source = "new:module" }))

			filter:setPatterns({ "^new" })

			assert.is_nil(filter:process({ source = "old:module" }))
			assert.is_not_nil(filter:process({ source = "new:module" }))
		end)
	end)

	describe("CloudEventsEnricher", function()
		it("adds required fields", function()
			local enricher = processors.CloudEventsEnricher()

			local msg = enricher:process({ message = "test" })

			assert.are.equal("1.0", msg.specversion)
			assert.is_not_nil(msg.id)
			assert.is_not_nil(msg.source)
			assert.is_not_nil(msg.type)
			assert.is_not_nil(msg.time)
		end)

		it("uses configured defaults", function()
			local enricher = processors.CloudEventsEnricher({
				source = "myapp:service",
				type = "myapp.event.custom",
			})

			local msg = enricher:process({})

			assert.are.equal("myapp:service", msg.source)
			assert.are.equal("myapp.event.custom", msg.type)
		end)

		it("preserves existing fields", function()
			local enricher = processors.CloudEventsEnricher({
				source = "default",
			})

			local msg = enricher:process({
				id = "custom-id",
				source = "custom:source",
			})

			assert.are.equal("custom-id", msg.id)
			assert.are.equal("custom:source", msg.source)
		end)

		it("processes async queue", function()
			local inputQ = MpscQueue.new()
			local outputQ = MpscQueue.new()
			local enricher = processors.CloudEventsEnricher({
				inputQueue = inputQ,
				outputQueue = outputQ,
			})

			local consumer = coop.spawn(function()
				enricher:start()
			end)

			inputQ:push({ message = "one" })
			inputQ:push({ message = "two" })
			inputQ:push({ type = "termichatter.completion.done" })

			consumer:await(100, 10)

			local msg1 = coop.spawn(function()
				return outputQ:pop()
			end):await(50, 10)

			assert.are.equal("one", msg1.message)
			assert.is_not_nil(msg1.id)
			assert.is_not_nil(msg1.specversion)
		end)
	end)

	describe("PriorityFilter", function()
		it("filters by minimum level", function()
			local filter = processors.PriorityFilter({ minLevel = 3 }) -- info+

			assert.is_nil(filter:process({ priority = "error", priorityLevel = 1 }))
			assert.is_nil(filter:process({ priority = "warn", priorityLevel = 2 }))
			assert.is_not_nil(filter:process({ priority = "info", priorityLevel = 3 }))
			assert.is_not_nil(filter:process({ priority = "debug", priorityLevel = 5 }))
		end)

		it("filters by maximum level", function()
			local filter = processors.PriorityFilter({ maxLevel = 3 }) -- up to info

			assert.is_not_nil(filter:process({ priority = "error", priorityLevel = 1 }))
			assert.is_not_nil(filter:process({ priority = "info", priorityLevel = 3 }))
			assert.is_nil(filter:process({ priority = "debug", priorityLevel = 5 }))
		end)

		it("infers level from priority name", function()
			local filter = processors.PriorityFilter({ minLevel = 3 })

			assert.is_nil(filter:process({ priority = "error" }))
			assert.is_not_nil(filter:process({ priority = "info" }))
		end)

		it("updates levels dynamically", function()
			local filter = processors.PriorityFilter({ minLevel = 1, maxLevel = 6 })

			assert.is_not_nil(filter:process({ priority = "debug", priorityLevel = 5 }))

			filter:setMaxLevel("info")

			assert.is_nil(filter:process({ priority = "debug", priorityLevel = 5 }))
		end)
	end)

	describe("Transformer", function()
		it("applies transform function", function()
			local transformer = processors.Transformer({
				transform = function(msg)
					msg.transformed = true
					return msg
				end,
			})

			local msg = transformer:process({ message = "test" })

			assert.is_true(msg.transformed)
		end)

		it("can filter by returning nil", function()
			local transformer = processors.Transformer({
				transform = function(msg)
					if msg.drop then
						return nil
					end
					return msg
				end,
			})

			assert.is_not_nil(transformer:process({ keep = true }))
			assert.is_nil(transformer:process({ drop = true }))
		end)

		it("updates transform dynamically", function()
			local transformer = processors.Transformer({
				transform = function(msg)
					msg.version = 1
					return msg
				end,
			})

			assert.are.equal(1, transformer:process({}).version)

			transformer:setTransform(function(msg)
				msg.version = 2
				return msg
			end)

			assert.are.equal(2, transformer:process({}).version)
		end)
	end)
end)
