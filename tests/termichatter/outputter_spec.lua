--- Busted tests for termichatter outputter queue semantics
local coop = require("coop")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("termichatter.outputter", function()
	local outputter, protocol

	before_each(function()
		package.loaded["termichatter.outputter"] = nil
		package.loaded["termichatter.protocol"] = nil
		outputter = require("termichatter.outputter")
		protocol = require("termichatter.protocol")
	end)

	describe("buffer outputter", function()
		it("ignores hello/done and stops only on shutdown", function()
			local queue = MpscQueue.new()
			local bufnr = vim.api.nvim_create_buf(false, true)

			local out = outputter.buffer({
				n = bufnr,
				queue = queue,
				format = function(msg)
					return msg.message
				end,
			})

			local task = coop.spawn(function()
				out:start()
			end)

			queue:push(vim.deepcopy(protocol.hello))
			queue:push({ message = "one" })
			queue:push(vim.deepcopy(protocol.done))
			queue:push({ message = "two" })
			queue:push(vim.deepcopy(protocol.shutdown))

			task:await(200, 10)

			vim.wait(100, function()
				local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
				return #lines >= 3
			end, 10)

			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			assert.are.equal("one", lines[#lines - 1])
			assert.are.equal("two", lines[#lines])

			local content = table.concat(lines, "\n")
			assert.is_falsy(content:match("termichatter%.completion"))

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)
	end)
end)
