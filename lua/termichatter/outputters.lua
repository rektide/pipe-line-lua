--- Outputters consume messages from queues and write them somewhere
local M = {}

local coop = require("coop")
local MpscQueue = require("coop.mpsc-queue").MpscQueue

--- Format a message for text output
---@param msg table the message
---@return string formatted the formatted string
local function formatMessage(msg)
	local parts = {}

	if msg.time then
		local time_str
		if type(msg.time) == "number" then
			-- hrtime is in nanoseconds, convert to readable format
			time_str = string.format("%.6f", msg.time / 1e9)
		else
			time_str = tostring(msg.time)
		end
		table.insert(parts, "[" .. time_str .. "]")
	end

	if msg.priority then
		table.insert(parts, string.upper(msg.priority))
	end

	if msg.source then
		table.insert(parts, msg.source)
	elseif msg.module then
		table.insert(parts, msg.module)
	end

	if msg.message then
		table.insert(parts, msg.message)
	elseif msg.data then
		table.insert(parts, vim.inspect(msg.data))
	end

	return table.concat(parts, " ")
end

--- Buffer outputter - appends messages to a neovim buffer
---@param config table { n?: number, format?: function }
---@return table outputter
M.buffer = function(config)
	config = config or {}
	local bufnr = config.n
	local format = config.format or formatMessage

	return {
		queue = config.queue or MpscQueue.new(),

		--- Write a single message to the buffer
		---@param msg table the message
		write = function(self, msg)
			if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end
			local line = format(msg)
			local lines = vim.split(line, "\n")
			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(bufnr) then
					vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
				end
			end)
		end,

		--- Start consuming from queue
		---@async
		start = function(self)
			while true do
				local msg = self.queue:pop()
				if msg.type == "termichatter.completion.done" then
					break
				end
				self:write(msg)
			end
		end,

		--- Set the buffer number
		---@param n number buffer number
		setBuffer = function(self, n)
			bufnr = n
		end,
	}
end

--- File outputter - appends messages to a file
---@param config table { filename: string, dir?: string, format?: function }
---@return table outputter
M.file = function(config)
	config = config or {}
	local filename = config.filename
	local dir = config.dir or vim.fn.getcwd()
	local format = config.format or formatMessage

	-- Extract dir from filename if it's a path
	if filename and filename:match("/") then
		local parts = vim.split(filename, "/")
		filename = table.remove(parts)
		if #parts > 0 then
			local pathDir = table.concat(parts, "/")
			if pathDir:sub(1, 1) == "/" then
				dir = pathDir
			else
				dir = dir .. "/" .. pathDir
			end
		end
	end

	local filepath = dir .. "/" .. filename
	local fd = nil

	return {
		queue = config.queue or MpscQueue.new(),

		--- Write a single message to the file
		---@param msg table the message
		write = function(self, msg)
			if not fd then
				fd = io.open(filepath, "a")
			end
			if fd then
				local line = format(msg)
				fd:write(line .. "\n")
				fd:flush()
			end
		end,

		--- Start consuming from queue
		---@async
		start = function(self)
			while true do
				local msg = self.queue:pop()
				if msg.type == "termichatter.completion.done" then
					break
				end
				self:write(msg)
			end
		end,

		--- Close the file handle
		close = function(self)
			if fd then
				fd:close()
				fd = nil
			end
		end,
	}
end

--- Fan-out outputter - forwards to multiple outputters
---@param config table { outputters: table[] }
---@return table outputter
M.fanout = function(config)
	config = config or {}
	local outputters = config.outputters or {}

	return {
		queue = config.queue or MpscQueue.new(),

		--- Write a single message to all outputters
		---@param msg table the message
		write = function(self, msg)
			for _, out in ipairs(outputters) do
				out:write(msg)
			end
		end,

		--- Start consuming from queue and forwarding
		---@async
		start = function(self)
			while true do
				local msg = self.queue:pop()
				if msg.type == "termichatter.completion.done" then
					-- Forward done to all child outputters
					for _, out in ipairs(outputters) do
						out.queue:push(msg)
					end
					break
				end
				self:write(msg)
			end
		end,

		--- Add an outputter
		---@param outputter table the outputter to add
		add = function(self, outputter)
			table.insert(outputters, outputter)
		end,
	}
end

--- JSON outputter - writes messages as JSON lines
---@param config table { filename?: string, fd?: file, format?: function }
---@return table outputter
M.jsonl = function(config)
	config = config or {}
	local filename = config.filename
	local fd = config.fd

	if filename and not fd then
		fd = io.open(filename, "a")
	end

	return {
		queue = config.queue or MpscQueue.new(),

		--- Write a single message as JSON
		---@param msg table the message
		write = function(self, msg)
			if fd then
				local json = vim.json.encode(msg)
				fd:write(json .. "\n")
				fd:flush()
			end
		end,

		--- Start consuming from queue
		---@async
		start = function(self)
			while true do
				local msg = self.queue:pop()
				if msg.type == "termichatter.completion.done" then
					break
				end
				self:write(msg)
			end
		end,

		--- Close the file handle
		close = function(self)
			if fd then
				fd:close()
				fd = nil
			end
		end,
	}
end

return M
