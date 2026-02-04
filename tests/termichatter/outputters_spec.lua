--- Busted tests for termichatter outputters
local coop = require("coop")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("termichatter.outputters", function()
	local outputters

	before_each(function()
		package.loaded["termichatter.outputters"] = nil
		outputters = require("termichatter.outputters")
	end)

	describe("buffer", function()
		local bufnr

		before_each(function()
			bufnr = vim.api.nvim_create_buf(false, true)
		end)

		after_each(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				vim.api.nvim_buf_delete(bufnr, { force = true })
			end
		end)

		it("creates outputter with queue", function()
			local out = outputters.buffer({ n = bufnr })
			assert.is_not_nil(out.queue)
			assert.is_function(out.write)
			assert.is_function(out.start)
		end)

		it("writes formatted message to buffer", function()
			local out = outputters.buffer({ n = bufnr })

			out:write({
				time = 1234567890000000000,
				priority = "info",
				source = "test:module",
				message = "Hello world",
			})

			-- Wait for vim.schedule
			vim.wait(50, function()
				return #vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) > 1
			end, 10)

			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			assert.is_true(#lines >= 1)

			local found = false
			for _, line in ipairs(lines) do
				if line:match("Hello world") then
					found = true
					break
				end
			end
			assert.is_true(found)
		end)

		it("uses custom format function", function()
			local out = outputters.buffer({
				n = bufnr,
				format = function(msg)
					return "CUSTOM: " .. (msg.message or "")
				end,
			})

			out:write({ message = "test" })

			vim.wait(50, function()
				local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
				for _, line in ipairs(lines) do
					if line:match("CUSTOM: test") then
						return true
					end
				end
				return false
			end, 10)

			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			local found = false
			for _, line in ipairs(lines) do
				if line:match("CUSTOM: test") then
					found = true
				end
			end
			assert.is_true(found)
		end)

		it("consumes from queue async", function()
			local inputQ = MpscQueue.new()
			local out = outputters.buffer({ n = bufnr, queue = inputQ })

			local consumer = coop.spawn(function()
				out:start()
			end)

			inputQ:push({ message = "async message" })
			inputQ:push({ type = "termichatter.completion.done" })

			consumer:await(100, 10)

			vim.wait(50, function()
				local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
				for _, line in ipairs(lines) do
					if line:match("async message") then
						return true
					end
				end
				return false
			end, 10)

			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			local found = false
			for _, line in ipairs(lines) do
				if line:match("async message") then
					found = true
				end
			end
			assert.is_true(found)
		end)
	end)

	describe("file", function()
		local testFile
		local testDir

		before_each(function()
			testDir = vim.fn.getcwd() .. "/.test-agent"
			vim.fn.mkdir(testDir, "p")
			testFile = testDir .. "/test-output-" .. os.time() .. ".log"
		end)

		after_each(function()
			os.remove(testFile)
		end)

		it("creates outputter with queue", function()
			local out = outputters.file({ filename = testFile })
			assert.is_not_nil(out.queue)
			assert.is_function(out.write)
			assert.is_function(out.close)
		end)

		it("writes to file", function()
			local out = outputters.file({ filename = testFile })

			out:write({ message = "file test" })
			out:close()

			local f = io.open(testFile, "r")
			assert.is_not_nil(f)
			local content = f:read("*a")
			f:close()

			assert.is_truthy(content:match("file test"))
		end)

		it("extracts dir from filename path", function()
			local subdir = testDir .. "/subdir"
			vim.fn.mkdir(subdir, "p")
			local subFile = subdir .. "/nested.log"

			local out = outputters.file({ filename = subFile })
			out:write({ message = "nested" })
			out:close()

			local f = io.open(subFile, "r")
			assert.is_not_nil(f)
			local content = f:read("*a")
			f:close()

			assert.is_truthy(content:match("nested"))

			os.remove(subFile)
			os.remove(subdir)
		end)
	end)

	describe("fanout", function()
		it("creates outputter with queue", function()
			local out = outputters.fanout({ outputters = {} })
			assert.is_not_nil(out.queue)
			assert.is_function(out.write)
			assert.is_function(out.add)
		end)

		it("forwards to multiple outputters", function()
			local received1 = {}
			local received2 = {}

			local mock1 = {
				queue = MpscQueue.new(),
				write = function(_, msg)
					table.insert(received1, msg)
				end,
			}
			local mock2 = {
				queue = MpscQueue.new(),
				write = function(_, msg)
					table.insert(received2, msg)
				end,
			}

			local fan = outputters.fanout({ outputters = { mock1, mock2 } })

			fan:write({ message = "broadcast" })

			assert.are.equal(1, #received1)
			assert.are.equal(1, #received2)
			assert.are.equal("broadcast", received1[1].message)
			assert.are.equal("broadcast", received2[1].message)
		end)

		it("adds outputters dynamically", function()
			local received = {}
			local mock = {
				queue = MpscQueue.new(),
				write = function(_, msg)
					table.insert(received, msg)
				end,
			}

			local fan = outputters.fanout({ outputters = {} })
			fan:add(mock)
			fan:write({ message = "added" })

			assert.are.equal(1, #received)
		end)

		it("forwards done to children", function()
			local doneReceived1 = false
			local doneReceived2 = false

			local mock1 = {
				queue = MpscQueue.new(),
				write = function() end,
			}
			local mock2 = {
				queue = MpscQueue.new(),
				write = function() end,
			}

			local inputQ = MpscQueue.new()
			local fan = outputters.fanout({
				outputters = { mock1, mock2 },
				queue = inputQ,
			})

			-- Check child queues for done message
			local checker1 = coop.spawn(function()
				local msg = mock1.queue:pop()
				if msg.type == "termichatter.completion.done" then
					doneReceived1 = true
				end
			end)
			local checker2 = coop.spawn(function()
				local msg = mock2.queue:pop()
				if msg.type == "termichatter.completion.done" then
					doneReceived2 = true
				end
			end)

			local consumer = coop.spawn(function()
				fan:start()
			end)

			inputQ:push({ type = "termichatter.completion.done" })

			consumer:await(100, 10)
			checker1:await(100, 10)
			checker2:await(100, 10)

			assert.is_true(doneReceived1)
			assert.is_true(doneReceived2)
		end)
	end)

	describe("jsonl", function()
		local testFile

		before_each(function()
			local testDir = vim.fn.getcwd() .. "/.test-agent"
			vim.fn.mkdir(testDir, "p")
			testFile = testDir .. "/test-output-" .. os.time() .. ".jsonl"
		end)

		after_each(function()
			os.remove(testFile)
		end)

		it("writes JSON lines", function()
			local out = outputters.jsonl({ filename = testFile })

			out:write({ message = "json test", value = 42 })
			out:close()

			local f = io.open(testFile, "r")
			assert.is_not_nil(f)
			local line = f:read("*l")
			f:close()

			local decoded = vim.json.decode(line)
			assert.are.equal("json test", decoded.message)
			assert.are.equal(42, decoded.value)
		end)

		it("writes multiple messages as separate lines", function()
			local out = outputters.jsonl({ filename = testFile })

			out:write({ n = 1 })
			out:write({ n = 2 })
			out:write({ n = 3 })
			out:close()

			local f = io.open(testFile, "r")
			local lines = {}
			for line in f:lines() do
				table.insert(lines, vim.json.decode(line))
			end
			f:close()

			assert.are.equal(3, #lines)
			assert.are.equal(1, lines[1].n)
			assert.are.equal(2, lines[2].n)
			assert.are.equal(3, lines[3].n)
		end)
	end)
end)
