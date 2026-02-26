local build_transport = require("termichatter.segment.define.transport")
local task_transport = require("termichatter.segment.define.transport.task")

return function(define)
	return build_transport(define, task_transport.new("unsafe"))
end
