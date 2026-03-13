local build_transport = require("pipe-line.segment.define.transport")
local task_transport = require("pipe-line.segment.define.transport.task")

return function(define)
	return build_transport(define, task_transport.new("unsafe"))
end
