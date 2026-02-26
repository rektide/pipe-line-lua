describe("termichatter.stopped_live", function()
	local Line, registry, Future

	before_each(function()
		package.loaded["termichatter.line"] = nil
		package.loaded["termichatter.registry"] = nil
		package.loaded["termichatter.segment"] = nil
		package.loaded["coop.future"] = nil
		Line = require("termichatter.line")
		registry = require("termichatter.registry")
		Future = require("coop.future").Future
	end)

	it("awaits matching segment stopped handles including newly added segments", function()
		local d1 = Future.new()
		local d2 = Future.new()

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

		d1:complete(true)
		d2:complete(true)
		line:ensure_stopped()

		local resolved = live:await(400, 10)
		assert.is_not_nil(resolved)
		assert.is_true(resolved.stopped)
	end)

	it("sees matching stopped handles added after start", function()
		local d = Future.new()
		local line = Line({ registry = registry, pipe = {} })

		local live = line:stopped_live("probe")

		vim.defer_fn(function()
			line:addSegment({
				type = "probe",
				init = function() return d end,
				handler = function(run) return run.input end,
			})
			d:complete(true)
			line:ensure_stopped()
		end, 10)

		local resolved = live:await(400, 10)
		assert.is_not_nil(resolved)
		assert.is_true(resolved.stopped)
	end)

	it("deduplicates identical awaitables across matching segments", function()
		local shared = Future.new()
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
		vim.defer_fn(function() shared:complete(true) end, 20)
		vim.defer_fn(function() line:ensure_stopped() end, 25)

		local resolved = live:await(400, 10)
		assert.is_not_nil(resolved)
		assert.is_true(resolved.stopped)
	end)
end)
