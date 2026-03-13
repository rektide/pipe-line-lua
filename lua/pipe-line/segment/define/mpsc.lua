local build_transport = require("pipe-line.segment.define.transport")
local mpsc_transport = require("pipe-line.segment.define.transport.mpsc")

return function(define)
	return build_transport(define, mpsc_transport.new())
end
