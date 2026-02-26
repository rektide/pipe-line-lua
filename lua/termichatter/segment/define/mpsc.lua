local build_transport = require("termichatter.segment.define.transport")
local mpsc_transport = require("termichatter.segment.define.transport.mpsc")

return function(define)
	return build_transport(define, mpsc_transport.new())
end
