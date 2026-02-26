--- Busted tests for termichatter logging helpers and line log API
local coop = require("coop")

describe("termichatter.log", function()
	local termichatter
	local logutil

	before_each(function()
		package.loaded["termichatter"] = nil
		package.loaded["termichatter.init"] = nil
		package.loaded["termichatter.line"] = nil
		package.loaded["termichatter.run"] = nil
		package.loaded["termichatter.pipe"] = nil
		package.loaded["termichatter.segment"] = nil
		package.loaded["termichatter.registry"] = nil
		package.loaded["termichatter.consumer"] = nil
		package.loaded["termichatter.log"] = nil

		termichatter = require("termichatter")
		logutil = require("termichatter.log")
		logutil.set_default_level("debug")
	end)

	describe("level normalization", function()
		it("resolves named levels to multiples of 10", function()
			assert.are.equal(10, logutil.resolve_level("error"))
			assert.are.equal(20, logutil.resolve_level("warn"))
			assert.are.equal(30, logutil.resolve_level("info"))
			assert.are.equal(40, logutil.resolve_level("log"))
			assert.are.equal(50, logutil.resolve_level("debug"))
			assert.are.equal(60, logutil.resolve_level("trace"))
		end)

		it("rejects non-multiple numeric levels", function()
			assert.has_error(function()
				logutil.resolve_level(33)
			end)
		end)

		it("supports global default level configuration", function()
			assert.are.equal(50, logutil.get_default_level())
			logutil.set_default_level("info")
			assert.are.equal(30, logutil.get_default_level())
			logutil.set_default_level(60)
			assert.are.equal(60, logutil.get_default_level())
		end)
	end)

	describe("source composition", function()
		it("computes full source from thin child chain", function()
			local root = termichatter({ source = "app" })
			local auth = root:child("auth")
			local jwt = auth:child("jwt")

			assert.are.equal("app", root.source)
			assert.are.equal("auth", auth.source)
			assert.are.equal("jwt", jwt.source)
			assert.are.equal("app", root:full_source())
			assert.are.equal("app:auth", auth:full_source())
			assert.are.equal("app:auth:jwt", jwt:full_source())
		end)
	end)

	describe("line logging behavior", function()
		it("defaults source and level for string message", function()
			local app = termichatter({ source = "svc" })
			app.pipe = termichatter.Pipe({ "ingester" })

			app:log("boot")

			local received = coop.spawn(function()
				return app.output:pop()
			end):await(100, 10)

			assert.are.equal("boot", received.message)
			assert.are.equal(50, received.level)
			assert.are.equal("svc", received.source)
		end)

		it("supports attrs-only payload", function()
			local app = termichatter({ source = "svc" })
			app.pipe = termichatter.Pipe({ "ingester" })

			app:log({ event = "heartbeat" })

			local received = coop.spawn(function()
				return app.output:pop()
			end):await(100, 10)

			assert.is_nil(received.message)
			assert.are.equal("heartbeat", received.event)
			assert.are.equal(50, received.level)
		end)

		it("lets message argument override attrs.message", function()
			local app = termichatter({ source = "svc" })
			app.pipe = termichatter.Pipe({ "ingester" })

			app:log("from-arg", { message = "from-attrs" })

			local received = coop.spawn(function()
				return app.output:pop()
			end):await(100, 10)

			assert.are.equal("from-arg", received.message)
		end)

		it("resolves string attrs.level", function()
			local app = termichatter({ source = "svc" })
			app.pipe = termichatter.Pipe({ "ingester" })

			app:log("warn-me", { level = "warn" })

			local received = coop.spawn(function()
				return app.output:pop()
			end):await(100, 10)

			assert.are.equal(20, received.level)
		end)

		it("applies level helpers", function()
			local app = termichatter({ source = "svc" })
			app.pipe = termichatter.Pipe({ "ingester" })

			app:error("err")
			app:info("inf")
			app:trace("trc")

			local a = coop.spawn(function() return app.output:pop() end):await(100, 10)
			local b = coop.spawn(function() return app.output:pop() end):await(100, 10)
			local c = coop.spawn(function() return app.output:pop() end):await(100, 10)

			assert.are.equal(10, a.level)
			assert.are.equal(30, b.level)
			assert.are.equal(60, c.level)
		end)

		it("prefers payload source over line source", function()
			local app = termichatter({ source = "svc" })
			app.pipe = termichatter.Pipe({ "ingester", "cloudevent" })

			app:info("custom source", { source = "explicit:source" })

			local received = coop.spawn(function()
				return app.output:pop()
			end):await(100, 10)

			assert.are.equal("explicit:source", received.source)
		end)

		it("uses sourcer override when payload source is absent", function()
			local app = termichatter({ source = "svc" })
			app.sourcer = function(line)
				return "sourcer:" .. tostring(line.source)
			end
			app.pipe = termichatter.Pipe({ "ingester" })

			app:debug("custom")

			local received = coop.spawn(function()
				return app.output:pop()
			end):await(100, 10)

			assert.are.equal("sourcer:svc", received.source)
		end)

		it("works with nested children and default composed source", function()
			local app = termichatter({ source = "app" })
			local auth = app:child("auth")
			local jwt = auth:child("jwt")
			jwt.pipe = termichatter.Pipe({ "ingester" })

			jwt:info("validated")

			local received = coop.spawn(function()
				return app.output:pop()
			end):await(100, 10)

			assert.are.equal("app:auth:jwt", received.source)
			assert.are.equal(30, received.level)
		end)

		it("rejects invalid log message type", function()
			local app = termichatter({ source = "svc" })
			assert.has_error(function()
				app:log(123)
			end)
		end)

		it("rejects invalid attrs type", function()
			local app = termichatter({ source = "svc" })
			assert.has_error(function()
				app:log("msg", "not-table")
			end)
		end)

		it("rejects unknown string level", function()
			local app = termichatter({ source = "svc" })
			assert.has_error(function()
				app:log("msg", { level = "nope" })
			end)
		end)
	end)

	describe("level filter compatibility", function()
		it("filters by numeric level using string max_level config", function()
			local app = termichatter({
				source = "svc",
				pipe = { "level_filter", "ingester" },
				max_level = "debug",
			})

			app:trace("drop me")
			app:info("keep me")

			local received = coop.spawn(function()
				return app.output:pop()
			end):await(100, 10)

			assert.are.equal("keep me", received.message)
			assert.are.equal(30, received.level)
		end)
	end)
end)
