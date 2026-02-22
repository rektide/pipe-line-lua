--- Lattice resolver: dependency injection via pipeline self-rewriting
--- A segment that inspects downstream wants, finds provider segment
--- in the registry, computes satisfiable order, and splices them in.
local M = {}

--- Resolve segment metadata (wants/emits)
--- Handles string name (registry lookup) and table with metadata
---@param seg string|function|table Segment identifier
---@param registry table The registry
---@return table|nil meta Table with wants/emits or nil
local function resolve_meta(seg, registry)
	if type(seg) == "table" then
		if seg.wants or seg.emits then
			return seg
		end
		return nil
	end
	if type(seg) == "string" and registry then
		local resolved = registry:resolve(seg)
		if type(resolved) == "table" and (resolved.wants or resolved.emits) then
			return resolved
		end
	end
	return nil
end
M.resolve_meta = resolve_meta

--- Collect all wants from segment in a pipe, from a position, up to a limit
---@param pipe table The pipe array
---@param from_pos number Start scanning from this position
---@param registry table The registry to resolve segment metadata
---@param lookahead? number Max number of segment to scan (nil = all)
---@return table want Set of wanted fact name (name → true)
local function collect_downstream_want(pipe, from_pos, registry, lookahead)
	local want = {}
	local end_pos = lookahead and math.min(from_pos + lookahead - 1, #pipe) or #pipe
	for i = from_pos, end_pos do
		local seg = pipe[i]
		local meta = resolve_meta(seg, registry)
		if meta and meta.wants then
			for _, w in ipairs(meta.wants) do
				want[w] = true
			end
		end
	end
	return want
end

--- Build an emits index from a registry: fact_name → { segment_entry, ... }
--- Walks the full registry once. Reuse the result to avoid repeated scans.
---@param registry table The registry to index
---@return table emits_index Map of fact name → array of { name, wants, emits, handler }
function M.build_emits_index(registry)
	local index = {}
	for name, seg in pairs(registry.segment) do
		local meta = resolve_meta(seg, registry)
		if meta and meta.emits then
			local entry = {
				name = name,
				wants = meta.wants or {},
				emits = meta.emits,
				handler = seg,
			}
			for _, e in ipairs(meta.emits) do
				if not index[e] then
					index[e] = {}
				end
				table.insert(index[e], entry)
			end
		end
	end
	return index
end

--- Find provider segment for a set of wanted fact, using an emits index
---@param want table Set of wanted fact (name → true)
---@param emits_index table The emits index (from build_emits_index)
---@return table[] candidate Array of unique segment entry
local function find_provider_indexed(want, emits_index)
	local candidate = {}
	local seen = {}
	for w in pairs(want) do
		local provider = emits_index[w]
		if provider then
			for _, entry in ipairs(provider) do
				if not seen[entry.name] then
					seen[entry.name] = true
					table.insert(candidate, entry)
				end
			end
		end
	end
	return candidate
end
M.find_provider_indexed = find_provider_indexed

--- Walk the full registry to find segment that emit any of the wanted fact
--- Convenience wrapper when no emits_index is available (builds one internally)
---@param want table Set of wanted fact (name → true)
---@param registry table The registry to search
---@return table[] candidate Array of segment entry
local function find_provider(want, registry)
	local index = M.build_emits_index(registry)
	return find_provider_indexed(want, index)
end
M.find_provider = find_provider

--- Kahn's topological sort: compute satisfiable execution order
--- Returns ordered array of candidate, or nil if unsatisfiable
---@param candidate table[] Array of { name, wants, emits }
---@param initial_fact table Set of already available fact (name → true)
---@return table[]|nil sorted Ordered candidate, or nil if cycle/missing dep
function M.kahn_sort(candidate, initial_fact)
	local available = {}
	for k, v in pairs(initial_fact or {}) do
		if v then
			available[k] = true
		end
	end

	local scheduled = {}
	local remaining = {}
	for _, c in ipairs(candidate) do
		remaining[c] = true
	end

	local progress = true
	while progress and next(remaining) do
		progress = false
		for c in pairs(remaining) do
			local satisfied = true
			for _, w in ipairs(c.wants) do
				if not available[w] then
					satisfied = false
					break
				end
			end
			if satisfied then
				table.insert(scheduled, c)
				remaining[c] = nil
				for _, e in ipairs(c.emits) do
					available[e] = true
				end
				progress = true
			end
		end
	end

	if next(remaining) then
		return nil
	end
	return scheduled
end

--- Collect fact that are already established by segment before a position
---@param pipe table The pipe array
---@param up_to_pos number Collect fact from segment before this position
---@param registry table The registry
---@param line_fact? table Line-level fact
---@return table fact Set of available fact (name → true)
local function collect_available_fact(pipe, up_to_pos, registry, line_fact)
	local fact = {}
	if line_fact then
		for k, v in pairs(line_fact) do
			if v then
				fact[k] = true
			end
		end
	end
	for i = 1, up_to_pos - 1 do
		local meta = resolve_meta(pipe[i], registry)
		if meta and meta.emits then
			for _, e in ipairs(meta.emits) do
				fact[e] = true
			end
		end
	end
	return fact
end

--- The lattice resolver segment
--- Inspects downstream wants, finds provider, sorts, splices into pipe
---
--- Options (read from run, inheritable from line):
---   resolver_keep     - if true, don't remove self after resolving (default: false)
---   resolver_lookahead - max number of downstream segment to scan (default: all)
---   resolver_emits_index - pre-built emits index table (default: built on the fly)
---
---@param run table The run context
---@return any input Pass-through
function M.lattice_resolver(run)
	local registry = run.registry or (run.line and run.line.registry)
	if not registry then
		return run.input
	end

	local pipe = run.pipe
	local pos = run.pos
	local keep = run.resolver_keep or false
	local lookahead = run.resolver_lookahead
	local emits_index = run.resolver_emits_index

	-- 1. collect downstream wants
	local want = collect_downstream_want(pipe, pos + 1, registry, lookahead)

	-- 2. collect already available fact
	local line_fact = run.line and run.line.fact or {}
	local available = collect_available_fact(pipe, pos, registry, line_fact)
	-- include run-level fact
	local run_fact = rawget(run, "fact")
	if run_fact then
		for k, v in pairs(run_fact) do
			if v then
				available[k] = true
			end
		end
	end

	-- 3. subtract available from wanted
	local unsatisfied = {}
	local unsatisfied_set = {}
	for w in pairs(want) do
		if not available[w] then
			table.insert(unsatisfied, w)
			unsatisfied_set[w] = true
		end
	end

	if #unsatisfied == 0 then
		if not keep then
			run:own("pipe")
			run.pipe:splice(pos, 1)
			-- pos-1 so execute()'s pos++ lands at pos (first remaining segment)
			run.pos = pos - 1
		end
		return run.input
	end

	-- 4. find provider segment (iteratively expand for transitive dependency)
	if not emits_index then
		emits_index = M.build_emits_index(registry)
	end
	local candidate_set = {}
	local candidate = {}
	local search_want = unsatisfied_set
	while next(search_want) do
		local found = find_provider_indexed(search_want, emits_index)
		local next_want = {}
		for _, entry in ipairs(found) do
			if not candidate_set[entry.name] then
				candidate_set[entry.name] = true
				table.insert(candidate, entry)
				-- check if this candidate has unsatisfied wants
				for _, w in ipairs(entry.wants) do
					if not available[w] and not unsatisfied_set[w] then
						next_want[w] = true
						unsatisfied_set[w] = true
					end
				end
			end
		end
		if not next(next_want) then
			break
		end
		search_want = next_want
	end

	-- 5. topological sort
	local sorted = M.kahn_sort(candidate, available)
	if not sorted then
		if not keep then
			run:own("pipe")
			run.pipe:splice(pos, 1)
			run.pos = pos - 1
		end
		return run.input
	end

	-- 6. splice resolved segment into pipe
	run:own("pipe")
	local name_list = {}
	for _, c in ipairs(sorted) do
		table.insert(name_list, c.name)
	end

	if keep then
		-- insert after self, keep self in pipe
		run.pipe:splice(pos + 1, 0, unpack(name_list))
		-- pos stays: execute() will ++ past resolver to first injected
	else
		-- replace self with resolved segment
		run.pipe:splice(pos, 1, unpack(name_list))
		-- pos-1 so execute()'s pos++ lands at pos (first injected segment)
		run.pos = pos - 1
	end

	return run.input
end

--- Create a configured lattice resolver segment
--- Returns a segment table with resolver options baked in
---@param opt? table { keep?: boolean, lookahead?: number, emits_index?: table }
---@return table segment A resolver segment with options
function M.create(opt)
	opt = opt or {}
	return {
		wants = {},
		emits = {},
		handler = function(run)
			-- apply options to run for this invocation
			if opt.keep ~= nil and not rawget(run, "resolver_keep") then
				run.resolver_keep = opt.keep
			end
			if opt.lookahead and not rawget(run, "resolver_lookahead") then
				run.resolver_lookahead = opt.lookahead
			end
			if opt.emits_index and not rawget(run, "resolver_emits_index") then
				run.resolver_emits_index = opt.emits_index
			end
			return M.lattice_resolver(run)
		end,
	}
end

--- Apply lattice resolution to a line without running the pipeline
--- Static analysis mode: modifies the line's pipe directly
---@param target_line table The line to resolve
---@param opt? table { emits_index?: table, lookahead?: number }
---@return table[]|nil sorted The resolved segment, or nil if unsatisfiable
function M.resolve_line(target_line, opt)
	opt = opt or {}
	local registry = target_line.registry
	if not registry then
		return nil
	end

	local pipe = target_line.pipe
	local emits_index = opt.emits_index or M.build_emits_index(registry)

	-- find the resolver position (if present), or analyze the full pipe
	local resolver_pos = nil
	for i = 1, #pipe do
		if pipe[i] == "lattice_resolver" then
			resolver_pos = i
			break
		end
	end

	local scan_from = resolver_pos and (resolver_pos + 1) or 1
	local want = collect_downstream_want(pipe, scan_from, registry, opt.lookahead)
	local available = collect_available_fact(pipe, scan_from, registry, target_line.fact)

	local unsatisfied_set = {}
	for w in pairs(want) do
		if not available[w] then
			unsatisfied_set[w] = true
		end
	end

	if not next(unsatisfied_set) then
		if resolver_pos then
			pipe:splice(resolver_pos, 1)
		end
		return {}
	end

	-- iteratively expand for transitive dependency
	local candidate_set = {}
	local candidate = {}
	local search_want = unsatisfied_set
	while next(search_want) do
		local found = find_provider_indexed(search_want, emits_index)
		local next_want = {}
		for _, entry in ipairs(found) do
			if not candidate_set[entry.name] then
				candidate_set[entry.name] = true
				table.insert(candidate, entry)
				for _, w in ipairs(entry.wants) do
					if not available[w] and not unsatisfied_set[w] then
						next_want[w] = true
						unsatisfied_set[w] = true
					end
				end
			end
		end
		if not next(next_want) then
			break
		end
		search_want = next_want
	end

	local sorted = M.kahn_sort(candidate, available)
	if not sorted then
		return nil
	end

	local name_list = {}
	for _, c in ipairs(sorted) do
		table.insert(name_list, c.name)
	end

	if resolver_pos then
		pipe:splice(resolver_pos, 1, unpack(name_list))
	else
		pipe:splice(1, 0, unpack(name_list))
	end

	return sorted
end

return M
