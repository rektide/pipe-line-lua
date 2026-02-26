local task_core = require("termichatter.segment.define.task-core")

return function(define)
	return task_core(define, "safe")
end
