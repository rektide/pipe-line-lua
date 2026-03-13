--- Busted tests for pipe-line outputter queue semantics
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("pipe-line.outputter", function()
	local outputter

	before_each(function()
		package.loaded["pipe-line.outputter"] = nil
		outputter = require("pipe-line.outputter")
	end)

	describe("buffer outputter", function()
		it("writes queued messages via normalized async lifecycle", function()
			local queue = MpscQueue.new()
			local bufnr = vim.api.nvim_create_buf(false, true)

			local out = outputter.buffer({
				n = bufnr,
				queue = queue,
				format = function(msg)
					return msg.message
				end,
			})

			local task = out:start_async()

			queue:push({ message = "one" })
			queue:push({ message = "two" })

			vim.wait(100, function()
				local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
				return #lines >= 2
			end, 10)

			out:stop()
			assert.is_true(out:await_stopped(200, 10))
			assert.is_table(task)

			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			assert.are.equal("one", lines[#lines - 1])
			assert.are.equal("two", lines[#lines])

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)
	end)
end)
