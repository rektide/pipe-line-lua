local common = require("termichatter.segment.define.common")

local M = {}

local function build_segment(define, spec, transport)
	local segment = common.copy_spec(spec)

	if type(transport.configure_segment) == "function" then
		transport.configure_segment(segment)
	end

	segment.strategy = segment.strategy or "self"

	local user_ensure_prepared = segment.ensure_prepared
	local user_ensure_stopped = segment.ensure_stopped
	local runtime = {
		wrapped_handler = define.wrap_handler(segment, segment.handler),
		handler_generator = segment.handler_generator,
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
		local continuation, should_dispatch = common.prepare_continuation(segment, run, runtime.wrapped_handler)
		if not should_dispatch then
			return false
		end

		if type(transport.dispatch) == "function" then
			transport.dispatch(segment, run, continuation, runtime)
		end

		return common.stop_result_or_false(segment)
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
