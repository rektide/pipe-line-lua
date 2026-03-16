local helper = require("tests.test_helper")

describe("pipe-line.errors", function()
	local errors

	before_each(function()
		helper.setup_vim()
		helper.reset_pipeline_modules()
		errors = require("pipe-line.errors")
	end)

	it("adds structured errors to table payload", function()
		local payload = { message = "x" }
		local out = errors.add(payload, { code = "c1", message = "m1" })
		assert.are.equal(payload, out)
		assert.is_true(errors.has(out))
		assert.are.equal(1, #errors.list(out))
		assert.are.equal("c1", errors.list(out)[1].code)
	end)

	it("wraps non-table payloads when adding errors", function()
		local out = errors.add("hello", { code = "x", message = "bad" })
		assert.is_table(out)
		assert.are.equal("hello", out.value)
		assert.is_true(errors.has(out))
	end)

	it("guard bypasses handler when errors already exist", function()
		local called = false
		local guarded = errors.guard(function(run)
			called = true
			return run.input
		end)
		local run = { input = errors.add({}, { code = "e", message = "x" }) }
		local out = guarded(run)
		assert.is_false(called)
		assert.are.equal(run.input, out)
	end)

	it("guard executes handler when payload is clean", function()
		local guarded = errors.guard(function(run)
			run.input.ok = true
			return run.input
		end)
		local run = { input = {} }
		local out = guarded(run)
		assert.is_true(out.ok)
	end)
end)
