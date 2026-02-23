--- Outputter: destination for processed message
local M = {}

--- Buffer outputter: write to nvim buffer
---@param config table { bufnr?: number, name?: string, format?: function }
---@return table outputter
function M.buffer(config)
	config = config or {}
	local bufnr = config.bufnr
	local format = config.format or function(msg)
		if type(msg) == "string" then
			return msg
		end
		return vim.inspect(msg)
	end

	local inst = {
		type = "outputter",
		name = "buffer",
		queue = config.queue,
		write = function(self, msg)
			if not bufnr then
				bufnr = vim.api.nvim_create_buf(false, true)
				if config.name then
					vim.api.nvim_buf_set_name(bufnr, config.name)
				end
			end
			local text = format(msg)
			local text_array
			if type(text) == "table" then
				text_array = text
			else
				text_array = vim.split(tostring(text), "\n", { plain = true })
			end
			vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, text_array)
		end,
		bufnr = function(self)
			return bufnr
		end,
		start = function(self)
			if not self.queue then return end
			while true do
				local msg = self.queue:pop()
				if not msg then break end
				if type(msg) == "table" and (msg.type == "termichatter.shutdown" or msg.type == "termichatter.completion.done") then
					break
				end
				self:write(msg)
			end
		end,
	}

	return inst
end

--- File outputter: append to file
---@param config table { filename: string, format?: function }
---@return table outputter
function M.file(config)
	local filename = config.filename
	local format = config.format or function(msg)
		if type(msg) == "string" then
			return msg
		end
		return vim.inspect(msg)
	end

	return {
		type = "outputter",
		name = "file",
		write = function(self, msg)
			local line = format(msg)
			local file = io.open(filename, "a")
			if file then
				file:write(line .. "\n")
				file:close()
			end
		end,
	}
end

--- JSONL outputter: write JSON Line
---@param config table { filename: string }
---@return table outputter
function M.jsonl(config)
	local filename = config.filename

	return {
		type = "outputter",
		name = "jsonl",
		write = function(self, msg)
			local ok, json = pcall(vim.json.encode, msg)
			if not ok then
				json = vim.inspect(msg)
			end
			local file = io.open(filename, "a")
			if file then
				file:write(json .. "\n")
				file:close()
			end
		end,
	}
end

--- Fanout outputter: forward to multiple outputter
---@param config table { outputter: table[] }
---@return table outputter
function M.fanout(config)
	local outputter = config.outputter or {}

	return {
		type = "outputter",
		name = "fanout",
		outputter = outputter,
		queue = config.queue,
		write = function(self, msg)
			for _, out in ipairs(self.outputter) do
				if out.write then
					out:write(msg)
				end
			end
		end,
		add = function(self, out)
			table.insert(self.outputter, out)
		end,
		start = function(self)
			if not self.queue then return end
			while true do
				local msg = self.queue:pop()
				if not msg then break end
				if type(msg) == "table" and (msg.type == "termichatter.shutdown" or msg.type == "termichatter.completion.done") then
					break
				end
				self:write(msg)
			end
		end,
	}
end

return M
