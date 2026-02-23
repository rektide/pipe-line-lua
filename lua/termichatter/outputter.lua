--- Outputter: destination for processed message
local protocol = require("termichatter.protocol")
local util = require("termichatter.util")

local M = {}

--- Buffer outputter: write to nvim buffer
---@param config table { bufnr?: number, n?: number, name?: string, format?: function, inspect?: function, queue?: table }
---@return table outputter
function M.buffer(config)
	config = config or {}
	local bufnr = config.bufnr or config.n
	local queue = config.queue
	local inspect_fn = config.inspect or util.inspect
	local format = config.format or function(msg)
		if type(msg) == "string" then
			return msg
		end
		return inspect_fn(msg)
	end

	local out = {
		type = "outputter",
		name = "buffer",
		write = function(self, msg)
			if not bufnr then
				bufnr = vim.api.nvim_create_buf(false, true)
				if config.name then
					vim.api.nvim_buf_set_name(bufnr, config.name)
				end
			end
			local line = format(msg)
			local line_array = type(line) == "table" and line or { line }
			vim.schedule(function()
				vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, line_array)
			end)
		end,
		bufnr = function(self)
			return bufnr
		end,
	}

	if queue then
		function out:start()
			while true do
				local msg = queue:pop()
				if not msg then
					break
				end
				if protocol.isCompletion(msg) then
					break
				end
				self:write(msg)
			end
		end
	end

	return out
end

--- File outputter: append to file
---@param config table { filename: string, format?: function, inspect?: function }
---@return table outputter
function M.file(config)
	local filename = config.filename
	local inspect_fn = config.inspect or util.inspect
	local format = config.format or function(msg)
		if type(msg) == "string" then
			return msg
		end
		return inspect_fn(msg)
	end

	return {
		type = "outputter",
		name = "file",
		write = function(self, msg)
			local line = format(msg)
			local f = io.open(filename, "a")
			if f then
				f:write(line .. "\n")
				f:close()
			end
		end,
	}
end

--- JSONL outputter: write JSON Line
---@param config table { filename: string, inspect?: function }
---@return table outputter
function M.jsonl(config)
	local filename = config.filename
	local inspect_fn = config.inspect or util.inspect

	return {
		type = "outputter",
		name = "jsonl",
		write = function(self, msg)
			local ok, json = pcall(vim.json.encode, msg)
			if not ok then
				json = inspect_fn(msg)
			end
			local f = io.open(filename, "a")
			if f then
				f:write(json .. "\n")
				f:close()
			end
		end,
	}
end

--- Fanout outputter: forward to multiple outputter
---@param config table { outputter: table[], queue?: table }
---@return table outputter
function M.fanout(config)
	local outputter_list = config.outputter or {}
	local queue = config.queue

	local out = {
		type = "outputter",
		name = "fanout",
		outputter = outputter_list,
		write = function(self, msg)
			for _, o in ipairs(self.outputter) do
				if o.write then
					o:write(msg)
				end
			end
		end,
		add = function(self, o)
			table.insert(self.outputter, o)
		end,
	}

	if queue then
		function out:start()
			while true do
				local msg = queue:pop()
				if not msg then
					break
				end
				if protocol.isShutdown(msg) then
					break
				end
				if not protocol.isCompletion(msg) then
					self:write(msg)
				end
			end
		end
	end

	return out
end

return M
