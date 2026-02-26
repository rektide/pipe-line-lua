--- Integration tests for termichatter end-to-end flow
local coop = require("coop")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("termichatter integration", function()
	local termichatter
	local outputter

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
		package.loaded["termichatter.outputter"] = nil
		package.loaded["termichatter.resolver"] = nil
		termichatter = require("termichatter")
		outputter = require("termichatter.outputter")
	end)

	describe("logger to buffer outputter", function()
		it("logs messages to a buffer", function()
			local bufnr = vim.api.nvim_create_buf(false, true)

			local app = termichatter({ source = "test:app" })

			local bufOut = outputter.buffer({
				n = bufnr,
				queue = app.output,
			})

			local outTask = bufOut:start_async()

			app:info("Starting up")
			app:debug("Debug info here")
			app:error("Something went wrong")

			vim.wait(100, function()
				local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
				return #lines >= 3
			end, 10)

			bufOut:stop(200, 10)
			assert.is_table(outTask)

			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			local content = table.concat(lines, "\n")

			assert.is_truthy(content:match("Starting up"))
			assert.is_truthy(content:match("Debug info"))
			assert.is_truthy(content:match("Something went wrong"))

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)
	end)

	describe("nested module inheritance", function()
		it("child line inherits parent context with composed source", function()
			local captured = {}

			local root = termichatter({
				source = "myapp",
				environment = "production",
			})

			local authModule = root:child({ source = "auth", component = "authentication" })

			authModule:addSegment("capture", function(run)
				table.insert(captured, run.input)
				return run.input
			end)

			local jwtModule = authModule:child("jwt")
			authModule:info("Token validated")
			jwtModule:info("Token validated jwt")

			assert.are.equal(2, #captured)
			local first = captured[1]
			local second = captured[2]

			assert.are.equal("myapp:auth", first.source)
			assert.are.equal("myapp:auth:jwt", second.source)
			assert.are.equal(30, first.level)
			assert.is_not_nil(first.time)
			assert.is_not_nil(first.id)
		end)
	end)

		describe("multiple producers single consumer", function()
		it("handles concurrent logging from multiple logger", function()
			local app = termichatter()
			local received = {}

			local consumerTask = coop.spawn(function()
				for _ = 1, 9 do
					local msg = app.output:pop()
					table.insert(received, msg)
				end
			end)

			local modA = app:child("A")
			local modB = app:child("B")
			local modC = app:child("C")

			for _ = 1, 3 do
				modA:info("from A")
				modB:info("from B")
				modC:info("from C")
			end

			consumerTask:await(300, 10)

			assert.are.equal(9, #received)

			local source_count = {}
			for _, msg in ipairs(received) do
				local s = msg.source
				source_count[s] = (source_count[s] or 0) + 1
			end

			assert.are.equal(3, source_count["A"])
			assert.are.equal(3, source_count["B"])
			assert.are.equal(3, source_count["C"])
		end)
	end)

	describe("fanout to multiple output", function()
		it("writes to multiple destination", function()
			local inputQ = MpscQueue.new()

			local buffer1 = {}
			local buffer2 = {}

			local mock1 = {
				write = function(_, msg)
					table.insert(buffer1, msg)
				end,
			}
			local mock2 = {
				write = function(_, msg)
					table.insert(buffer2, msg)
				end,
			}

			local fan = outputter.fanout({
				outputter = { mock1, mock2 },
				queue = inputQ,
			})

			local task = fan:start_async()

			inputQ:push({ message = "broadcast 1" })
			inputQ:push({ message = "broadcast 2" })

			vim.wait(100, function()
				return #buffer1 >= 2 and #buffer2 >= 2
			end, 10)

			fan:stop(200, 10)
			assert.is_table(task)

			assert.are.equal(2, #buffer1)
			assert.are.equal(2, #buffer2)
			assert.are.equal("broadcast 1", buffer1[1].message)
			assert.are.equal("broadcast 2", buffer2[2].message)
		end)
	end)

	describe("lattice resolver end-to-end", function()
		it("resolves and executes injected segment", function()
			local reg = termichatter.registry

			reg:register("enricher", {
				wants = {},
				emits = { "enriched" },
				handler = function(run)
					run.input.enriched = true
					return run.input
				end,
			})
			reg:register("validator", {
				wants = { "time" },
				emits = { "validated" },
				handler = function(run)
					run.input.validated = true
					return run.input
				end,
			})
			reg:register("final_output", {
				wants = { "enriched", "validated" },
				emits = {},
				handler = function(run)
					run.input.final = true
					return run.input
				end,
			})

			local Pipe = require("termichatter.pipe")
			local app = termichatter()
			app.pipe = Pipe({ "timestamper", "lattice_resolver", "final_output" })

			app:log({ message = "resolve me" })

			local received = nil
			local task = coop.spawn(function()
				received = app.output:pop()
			end)
			task:await(100, 10)

			assert.is_not_nil(received)
			assert.is_true(received.enriched)
			assert.is_true(received.validated)
			assert.is_true(received.final)
			assert.is_not_nil(received.time)
		end)
	end)
end)
