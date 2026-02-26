--- Busted tests for termichatter outputter queue semantics
local coop = require("coop")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("termichatter.outputter", function()
	local outputter

	before_each(function()
		package.loaded["termichatter.outputter"] = nil
		outputter = require("termichatter.outputter")
	end)

	describe("buffer outputter", function()
		it("writes queued messages until consumer task is canceled", function()
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

			queue:push({ message = "one" })
			queue:push({ message = "two" })

			vim.wait(100, function()
				local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
				return #lines >= 2
			end, 10)

			task:cancel()
			local ok, err = pcall(function()
				task:await(200, 10)
			end)
			if not ok and not tostring(err):match("cancelled") then
				error(err, 0)
			end

			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			assert.are.equal("one", lines[#lines - 1])
			assert.are.equal("two", lines[#lines])

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)
	end)
end)
