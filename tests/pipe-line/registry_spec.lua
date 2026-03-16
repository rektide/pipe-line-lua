local helper = require("tests.test_helper")

describe("pipe-line.registry", function()
	local registry

	before_each(function()
		helper.setup_vim()
		helper.reset_pipeline_modules()
		registry = require("pipe-line.registry")
	end)

	it("registers and resolves named segments", function()
		registry:register("sample", function(run)
			return run.input
		end)
		assert.is_function(registry:resolve("sample"))
	end)

	it("registers and resolves gaters", function()
		registry:register_gater("g_test", { role = "gater", handle = function(self, run)
			return run:dispatch()
		end })
		local resolved = registry:resolve_gater("g_test")
		assert.is_table(resolved)
		assert.are.equal("gater", resolved.role)
	end)

	it("registers and resolves executors", function()
		registry:register_executor("e_test", { role = "executor", handle = function(self, run)
			return run:settle({ status = "ok", value = run.input })
		end })
		local resolved = registry:resolve_executor("e_test")
		assert.is_table(resolved)
		assert.are.equal("executor", resolved.role)
	end)

	it("inherits gater and executor across derive", function()
		registry:register_gater("parent_gate", { role = "gater", handle = function(self, run)
			return run:dispatch()
		end })
		registry:register_executor("parent_exec", { role = "executor", handle = function(self, run)
			return run:settle({ status = "ok" })
		end })

		local child = registry:derive()
		assert.is_not_nil(child:resolve_gater("parent_gate"))
		assert.is_not_nil(child:resolve_executor("parent_exec"))
	end)
end)
