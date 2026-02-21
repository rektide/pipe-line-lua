--- Lattice resolver: dependency injection via pipeline self-rewriting
--- A segment that inspects downstream wants, finds provider segment
--- in the registry, computes satisfiable order, and splices them in.
local M = {}

--- Collect all wants from segment in a pipe, starting from a position
---@param pipe table The pipe array
---@param from_pos number Start scanning from this position
---@param registry table The registry to resolve segment metadata
---@return table wants Set of wanted fact name (name → true)
local function collect_downstream_want(pipe, from_pos, registry)
	local want = {}
	for i = from_pos, #pipe do
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

--- Resolve segment metadata (wants/emits)
--- Handles string name (registry lookup) and table with metadata
---@param seg string|function|table Segment identifier
---@param registry table The registry
---@return table|nil meta Table with wants/emits or nil
function resolve_meta(seg, registry)
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

--- Walk the full registry to find segment that emit any of the wanted fact
---@param want table Set of wanted fact (name → true)
---@param registry table The registry to search
---@return table[] candidate Array of segment metadata table
local function find_provider(want, registry)
	local candidate = {}
	local seen = {}
	for name, seg in pairs(registry.segment) do
		local meta = resolve_meta(seg, registry)
		if not meta and type(seg) == "function" then
			-- plain function, no metadata
			goto continue
		end
		if meta and meta.emits then
			for _, e in ipairs(meta.emits) do
				if want[e] and not seen[name] then
					seen[name] = true
					local entry = {
						name = name,
						wants = meta.wants or {},
						emits = meta.emits or {},
						handler = seg,
					}
					table.insert(candidate, entry)
					break
				end
			end
		end
		::continue::
	end
	return candidate
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
--- Inspects downstream wants, finds provider, sorts, splices, removes self
---@param run table The run context
---@return any input Pass-through
function M.lattice_resolver(run)
	local registry = run.registry or (run.line and run.line.registry)
	if not registry then
		return run.input
	end

	local pipe = run.pipe
	local pos = run.pos

	-- 1. collect downstream wants
	local want = collect_downstream_want(pipe, pos + 1, registry)

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
	for w in pairs(want) do
		if not available[w] then
			table.insert(unsatisfied, w)
		end
	end

	if #unsatisfied == 0 then
		-- all satisfied, remove self and continue
		run:own("pipe")
		run.pipe:splice(pos, 1)
		-- pos now points to what was after us
		run.pos = pos  -- stay at same index (splice shifted everything down)
		return run.input
	end

	-- 4. find provider segment from registry
	local want_set = {}
	for _, w in ipairs(unsatisfied) do
		want_set[w] = true
	end
	local candidate = find_provider(want_set, registry)

	-- 5. topological sort
	local sorted = M.kahn_sort(candidate, available)
	if not sorted then
		-- unsatisfiable: remove self and continue anyway
		run:own("pipe")
		run.pipe:splice(pos, 1)
		run.pos = pos
		return run.input
	end

	-- 6. splice: replace self with sorted segment
	run:own("pipe")
	local name_list = {}
	for _, c in ipairs(sorted) do
		table.insert(name_list, c.name)
	end
	run.pipe:splice(pos, 1, unpack(name_list))
	-- pos now points at first injected segment
	run.pos = pos

	return run.input
end

--- Apply lattice resolution to a line without running the pipeline
--- Static analysis mode: modifies the line's pipe directly
---@param target_line table The line to resolve
---@return table[]|nil sorted The resolved segment, or nil if unsatisfiable
function M.resolve_line(target_line)
	local registry = target_line.registry
	if not registry then
		return nil
	end

	local pipe = target_line.pipe

	-- find the resolver position (if present), or analyze the full pipe
	local resolver_pos = nil
	for i = 1, #pipe do
		if pipe[i] == "lattice_resolver" then
			resolver_pos = i
			break
		end
	end

	local scan_from = resolver_pos and (resolver_pos + 1) or 1
	local want = collect_downstream_want(pipe, scan_from, registry)
	local available = collect_available_fact(pipe, scan_from, registry, target_line.fact)

	local unsatisfied_set = {}
	for w in pairs(want) do
		if not available[w] then
			unsatisfied_set[w] = true
		end
	end

	if not next(unsatisfied_set) then
		-- remove resolver if present
		if resolver_pos then
			pipe:splice(resolver_pos, 1)
		end
		return {}
	end

	local candidate = find_provider(unsatisfied_set, registry)
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
		-- insert at position 1 by default
		pipe:splice(1, 0, unpack(name_list))
	end

	return sorted
end

return M
