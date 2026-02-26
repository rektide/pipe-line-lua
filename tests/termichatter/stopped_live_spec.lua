describe("termichatter.stopped_live", function()
	local Line, registry, done

	before_each(function()
		package.loaded["termichatter.line"] = nil
		package.loaded["termichatter.registry"] = nil
		package.loaded["termichatter.segment"] = nil
		package.loaded["termichatter.done"] = nil
		Line = require("termichatter.line")
		registry = require("termichatter.registry")
		done = require("termichatter.done")
	end)

	it("awaits matching segment stopped handles including newly added segments", function()
		local d1 = done.create_deferred()
		local d2 = done.create_deferred()

		local line = Line({ registry = registry, pipe = {} })
		line:addSegment({
			type = "probe",
			init = function() return d1 end,
			handler = function(run) return run.input end,
		})

		local live = line:stopped_live("probe")
		line:addSegment({
			type = "probe",
			init = function() return d2 end,
			handler = function(run) return run.input end,
		})

		d1:resolve(true)
		d2:resolve(true)
		line:ensure_stopped()

		local resolved = live:await(400, 10)
		assert.is_not_nil(resolved)
		assert.is_true(resolved.stopped)
	end)

	it("sees matching stopped handles added after start", function()
		local d = done.create_deferred()
		local line = Line({ registry = registry, pipe = {} })

		local live = line:stopped_live("probe")

		vim.defer_fn(function()
			line:addSegment({
				type = "probe",
				init = function() return d end,
				handler = function(run) return run.input end,
			})
			d:resolve(true)
			line:ensure_stopped()
		end, 10)

		local resolved = live:await(400, 10)
		assert.is_not_nil(resolved)
		assert.is_true(resolved.stopped)
	end)

	it("deduplicates identical awaitables across matching segments", function()
		local shared = done.create_deferred()
		local line = Line({ registry = registry, pipe = {} })

		line:addSegment({
			type = "probe",
			init = function() return shared end,
			handler = function(run) return run.input end,
		})
		line:addSegment({
			type = "probe",
			init = function() return shared end,
			handler = function(run) return run.input end,
		})

		local live = line:stopped_live("probe")
		vim.defer_fn(function() shared:resolve(true) end, 20)
		vim.defer_fn(function() line:ensure_stopped() end, 25)

		local resolved = live:await(400, 10)
		assert.is_not_nil(resolved)
		assert.is_true(resolved.stopped)
	end)
end)
