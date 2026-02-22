--- Busted tests for termichatter lattice resolver
local MpscQueue = require("coop.mpsc-queue").MpscQueue

describe("termichatter.resolver", function()
	local resolver, registry, Pipe, line, Run

	before_each(function()
		package.loaded["termichatter.resolver"] = nil
		package.loaded["termichatter.registry"] = nil
		package.loaded["termichatter.pipe"] = nil
		package.loaded["termichatter.line"] = nil
		package.loaded["termichatter.run"] = nil
		resolver = require("termichatter.resolver")
		registry = require("termichatter.registry")
		Pipe = require("termichatter.pipe")
		line = require("termichatter.line")
		Run = require("termichatter.run")
	end)

	local function make_line(segment_list, extra)
		extra = extra or {}
		local l = line:clone({
			pipe = Pipe.new(segment_list),
			registry = registry,
			output = MpscQueue.new(),
		})
		for k, v in pairs(extra) do
			l[k] = v
		end
		return l
	end

	describe("kahn_sort", function()
		it("sorts independent segment", function()
			local candidate = {
				{ name = "a", wants = {}, emits = { "x" } },
				{ name = "b", wants = {}, emits = { "y" } },
			}
			local sorted = resolver.kahn_sort(candidate, {})
			assert.is_not_nil(sorted)
			assert.are.equal(2, #sorted)
		end)

		it("respects dependency order", function()
			local candidate = {
				{ name = "b", wants = { "x" }, emits = { "y" } },
				{ name = "a", wants = {}, emits = { "x" } },
			}
			local sorted = resolver.kahn_sort(candidate, {})
			assert.is_not_nil(sorted)
			assert.are.equal("a", sorted[1].name)
			assert.are.equal("b", sorted[2].name)
		end)

		it("returns nil for cyclic dependency", function()
			local candidate = {
				{ name = "a", wants = { "y" }, emits = { "x" } },
				{ name = "b", wants = { "x" }, emits = { "y" } },
			}
			local sorted = resolver.kahn_sort(candidate, {})
			assert.is_nil(sorted)
		end)

		it("uses initial fact to satisfy dependency", function()
			local candidate = {
				{ name = "a", wants = { "pre" }, emits = { "x" } },
			}
			local sorted = resolver.kahn_sort(candidate, { pre = true })
			assert.is_not_nil(sorted)
			assert.are.equal(1, #sorted)
		end)

		it("returns nil when dependency not available", function()
			local candidate = {
				{ name = "a", wants = { "missing" }, emits = { "x" } },
			}
			local sorted = resolver.kahn_sort(candidate, {})
			assert.is_nil(sorted)
		end)
	end)

	describe("build_emits_index", function()
		it("indexes segment by emitted fact", function()
			registry:register("time_seg", {
				wants = {},
				emits = { "time" },
				handler = function() end,
			})
			registry:register("id_seg", {
				wants = {},
				emits = { "id", "source" },
				handler = function() end,
			})

			local index = resolver.build_emits_index(registry)
			assert.is_not_nil(index.time)
			assert.are.equal(1, #index.time)
			assert.are.equal("time_seg", index.time[1].name)

			assert.is_not_nil(index.id)
			assert.is_not_nil(index.source)
		end)

		it("skips plain function segment", function()
			registry:register("plain", function() end)
			local index = resolver.build_emits_index(registry)
			-- plain function has no emits, not indexed
			local count = 0
			for _ in pairs(index) do count = count + 1 end
			assert.are.equal(0, count)
		end)
	end)

	describe("lattice_resolver segment", function()
		it("splices dependency and removes self", function()
			registry:register("enricher", {
				wants = {},
				emits = { "enriched" },
				handler = function(run)
					run.input.enriched = true
					return run.input
				end,
			})
			registry:register("output_seg", {
				wants = { "enriched" },
				emits = {},
				handler = function(run) return run.input end,
			})

			local l = make_line({ "lattice_resolver", "output_seg" })
			local r = Run.new(l, { input = { message = "test" } })

			-- resolver should have spliced enricher in and removed self
			-- pipe should be: enricher, output_seg
			assert.are.equal(2, #r.pipe)
			assert.are.equal("enricher", r.pipe[1])
			assert.are.equal("output_seg", r.pipe[2])
			assert.is_true(r.input.enriched)
		end)

		it("handles already satisfied wants", function()
			registry:register("producer", {
				wants = {},
				emits = { "fact_a" },
				handler = function(run) return run.input end,
			})
			registry:register("consumer_seg", {
				wants = { "fact_a" },
				emits = {},
				handler = function(run) return run.input end,
			})

			-- producer already in pipe before resolver
			local l = make_line({ "producer", "lattice_resolver", "consumer_seg" })
			local r = Run.new(l, { input = {} })

			-- resolver should remove self, no splicing needed
			assert.are.equal(2, #r.pipe)
			assert.are.equal("producer", r.pipe[1])
			assert.are.equal("consumer_seg", r.pipe[2])
		end)

		it("respects resolver_keep option", function()
			registry:register("enricher2", {
				wants = {},
				emits = { "enriched" },
				handler = function(run)
					run.input.enriched = true
					return run.input
				end,
			})
			registry:register("out2", {
				wants = { "enriched" },
				emits = {},
				handler = function(run) return run.input end,
			})

			local l = make_line({ "lattice_resolver", "out2" })
			l.resolver_keep = true
			local r = Run.new(l, { input = {} })

			-- resolver should stay, enricher inserted after it
			local found_resolver = false
			for _, s in ipairs(r.pipe) do
				if s == "lattice_resolver" then
					found_resolver = true
				end
			end
			assert.is_true(found_resolver)
		end)

		it("respects resolver_lookahead option", function()
			registry:register("near_dep", {
				wants = {},
				emits = { "near" },
				handler = function(run) return run.input end,
			})
			registry:register("far_dep", {
				wants = {},
				emits = { "far" },
				handler = function(run) return run.input end,
			})
			registry:register("near_consumer", {
				wants = { "near" },
				emits = {},
				handler = function(run) return run.input end,
			})
			registry:register("far_consumer", {
				wants = { "far" },
				emits = {},
				handler = function(run) return run.input end,
			})

			local l = make_line({ "lattice_resolver", "near_consumer", "far_consumer" })
			l.resolver_lookahead = 1 -- only scan 1 downstream
			local r = Run.new(l, { input = {} })

			-- should only resolve near_consumer's wants, not far_consumer's
			local has_near = false
			local has_far = false
			for _, s in ipairs(r.pipe) do
				if s == "near_dep" then has_near = true end
				if s == "far_dep" then has_far = true end
			end
			assert.is_true(has_near)
			assert.is_false(has_far)
		end)

		it("accepts resolver_emits_index", function()
			registry:register("custom_dep", {
				wants = {},
				emits = { "custom" },
				handler = function(run) return run.input end,
			})
			registry:register("needs_custom", {
				wants = { "custom" },
				emits = {},
				handler = function(run) return run.input end,
			})

			local index = resolver.build_emits_index(registry)

			local l = make_line({ "lattice_resolver", "needs_custom" })
			l.resolver_emits_index = index
			local r = Run.new(l, { input = {} })

			local has_custom = false
			for _, s in ipairs(r.pipe) do
				if s == "custom_dep" then has_custom = true end
			end
			assert.is_true(has_custom)
		end)
	end)

	describe("resolve_line (static)", function()
		it("resolves dependency without running", function()
			registry:register("provider", {
				wants = {},
				emits = { "provided" },
				handler = function(run) return run.input end,
			})
			registry:register("needs_it", {
				wants = { "provided" },
				emits = {},
				handler = function(run) return run.input end,
			})

			local l = make_line({ "lattice_resolver", "needs_it" })
			local sorted = resolver.resolve_line(l)

			assert.is_not_nil(sorted)
			assert.are.equal(1, #sorted)
			-- pipe should have resolver replaced with provider
			assert.are.equal("provider", l.pipe[1])
			assert.are.equal("needs_it", l.pipe[2])
		end)

		it("returns empty when all satisfied", function()
			registry:register("producer2", {
				wants = {},
				emits = { "fact" },
				handler = function() end,
			})
			registry:register("consumer2", {
				wants = { "fact" },
				emits = {},
				handler = function() end,
			})

			local l = make_line({ "producer2", "lattice_resolver", "consumer2" })
			local sorted = resolver.resolve_line(l)

			assert.is_not_nil(sorted)
			assert.are.equal(0, #sorted)
			-- resolver removed, pipe is just producer2, consumer2
			assert.are.equal(2, #l.pipe)
		end)
	end)

	describe("create factory", function()
		it("creates segment with baked-in options", function()
			local seg = resolver.create({ keep = true, lookahead = 2 })
			assert.is_not_nil(seg.handler)
			assert.is_table(seg.wants)
			assert.is_table(seg.emits)
		end)
	end)
end)
