--- Logging helpers: level normalization and source composition.
local M = {}

M.level = {
	error = 10,
	warn = 20,
	info = 30,
	log = 40,
	debug = 50,
	trace = 60,
}

local default_level = M.level.debug

local function validate_numeric_level(level, context)
	if type(level) ~= "number" then
		error(context .. " must be a number", 0)
	end
	if level % 10 ~= 0 then
		error(context .. " must be a multiple of 10", 0)
	end
	return level
end

---@param value? string|number
---@param fallback? number
---@param context? string
---@return number|nil level
function M.resolve_level(value, fallback, context)
	context = context or "level"

	if value == nil then
		return fallback
	end

	if type(value) == "string" then
		local resolved = M.level[value]
		if not resolved then
			error("invalid " .. context .. ": " .. tostring(value), 0)
		end
		return resolved
	end

	if type(value) == "number" then
		return validate_numeric_level(value, context)
	end

	error("invalid " .. context .. " type: " .. type(value), 0)
end

---@return number level
function M.get_default_level()
	return default_level
end

---@param value string|number
---@return number level
function M.set_default_level(value)
	default_level = M.resolve_level(value, nil, "default level")
	return default_level
end

---@param line? table
---@return string|nil source
function M.full_source(line)
	if type(line) ~= "table" then
		return nil
	end

	local source_parts = {}
	local cursor = line
	while cursor do
		local local_source = rawget(cursor, "source")
		if local_source ~= nil then
			table.insert(source_parts, 1, local_source)
		end
		cursor = rawget(cursor, "parent")
	end

	if #source_parts == 0 then
		return nil
	end

	return table.concat(source_parts, ":")
end

---@param line table
---@param message? string|table
---@param attrs? table
---@param level_override? string|number
---@return table payload
function M.normalize(line, message, attrs, level_override)
	if type(message) == "table" then
		if attrs ~= nil then
			error("log attrs must be nil when message is a table", 0)
		end
		attrs = message
		message = nil
	end

	if message ~= nil and type(message) ~= "string" then
		error("log message must be a string, table, or nil", 0)
	end

	if attrs ~= nil and type(attrs) ~= "table" then
		error("log attrs must be a table or nil", 0)
	end

	local payload = {}
	for k, v in pairs(attrs or {}) do
		payload[k] = v
	end

	if message ~= nil then
		payload.message = message
	end

	payload.level = M.resolve_level(level_override or payload.level, default_level, "log level")

	if payload.source == nil then
		local sourcer = line and line.sourcer or M.full_source
		local source = sourcer(line)
		if source ~= nil then
			payload.source = source
		end
	end

	return payload
end

return M
