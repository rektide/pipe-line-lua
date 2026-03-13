local common = require("pipe-line.segment.define.common")

local function build_segment(define, spec, transport)
	local segment = common.copy_spec(spec)

	local user_ensure_prepared = segment.ensure_prepared
	local user_ensure_stopped = segment.ensure_stopped
	local runtime = {
		wrapped_handler = define.wrap_handler(segment, segment.handler),
		handler_generator = segment.handler_generator,
		transport_type = transport.type,
	}

	segment.ensure_prepared = function(self, context)
		local awaited = {}
		if type(user_ensure_prepared) == "function" then
			common.append_awaitable(awaited, user_ensure_prepared(self, context))
		end

		if type(transport.ensure_prepared) == "function" then
			common.append_awaitable(awaited, transport.ensure_prepared(self, context, runtime))
		end

		return common.compact_awaitables(awaited)
	end

	segment.handler = function(run)
		if type(transport.handler) == "function" then
			return transport.handler(segment, run, runtime)
		end

		return runtime.wrapped_handler(run)
	end

	segment.ensure_stopped = function(self, context)
		local awaited = {}
		if type(user_ensure_stopped) == "function" then
			common.append_awaitable(awaited, user_ensure_stopped(self, context))
		end

		if type(transport.ensure_stopped) == "function" then
			common.append_awaitable(awaited, transport.ensure_stopped(self, context, runtime))
		end

		return common.compact_awaitables(awaited)
	end

	return segment
end

return function(define, transport)
	transport = transport or {}
	return function(spec)
		return build_segment(define, spec, transport)
	end
end
