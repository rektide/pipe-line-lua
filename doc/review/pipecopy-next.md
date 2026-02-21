# Pipecopy Review & Lattice Resolver Path

> Review of [`implementations/pipecopy/`](/implementations/pipecopy/) on its own merits, plus analysis of how [`lattice-pipe-resolver.md`](/implementations/pipeflow/lattice-pipe-resolver.md) maps onto pipecopy.

---

## Pipecopy Review: On Its Own Merits

### Strengths

1. **Clean decomposition.** Separating [`line.lua`](/implementations/pipecopy/lua/termichatter/line.lua), [`run.lua`](/implementations/pipecopy/lua/termichatter/run.lua), [`registry.lua`](/implementations/pipecopy/lua/termichatter/registry.lua), [`pipe.lua`](/implementations/pipecopy/lua/termichatter/pipe.lua), [`inherit.lua`](/implementations/pipecopy/lua/termichatter/inherit.lua) into distinct modules is a real improvement over the baseline's monolithic init.lua. Each file has a clear single concern.

2. **`inherit.lua` is solid.** `derive`, `walk_field`, `walk_predicate`, `get_parent` — small, useful, well-tested primitives. `derive_multi` for multiple-parent lookup is a nice addition.

3. **`splice` on both `line` and `run`** with pos-adjustment in `run:splice` is well thought out. The run copy-on-write (shallow copy of `pipe` at `Run.new`) is the right approach.

4. **Registry inheritance via `derive()`** — sub-registries that fall through to parent is a clean pattern for extensibility.

5. **The `run` as self pattern** — pipes receive the run as their sole argument and read `run.input`, `run.source`, etc. This is ergonomically clean and avoids parameter-soup.

### Weaknesses / Concerns

1. **Method copying instead of metatables in `Run.new`.** [`run.lua` lines 285-289](/implementations/pipecopy/lua/termichatter/run.lua) copy every function from `M` onto each run instance. This defeats the purpose of metatables (which `inherit.derive` already sets up on line 266). The `for k, v in pairs(M)` loop should be removed — methods should resolve via `__index`.

2. **`push()` saves/restores pos** ([`run.lua` lines 209-218](/implementations/pipecopy/lua/termichatter/run.lua)) to recursively execute the next sync pipe, which is clever but fragile. If a pipe calls `push` multiple times (the design doc mentions this as a goal), you get nested pos-juggling. The recursive call also means deep sync chains could blow the Lua stack.

3. **`module_filter` returns `nil` to signal filtering**, but `execute()` only checks `result == false` ([`run.lua` line 235](/implementations/pipecopy/lua/termichatter/run.lua)) to abort. A filtered `nil` result falls through to `if result ~= nil` on line 238, which just means `self.input` isn't updated — the message **still continues through the pipeline**. This is a bug: filtering doesn't actually stop the message.

4. **Missing `pipeStep` tracking.** The baseline sets `msg.pipeStep` so consumers know where to resume. Pipecopy's consumer ([`consumer.lua` lines 28-30](/implementations/pipecopy/lua/termichatter/consumer.lua)) manually sets `run.pos` and `run.current`, which works but loses the diagnostic "where am I" info on the message itself.

5. **No completion/shutdown protocol.** The baseline has `completion.hello`/`completion.done` for graceful lifecycle. Consumer just loops `queue:pop()` and breaks on `nil`. There's no way to signal "flush and close."

6. **`line:splice` mpsc reindexing** ([`line.lua` lines 44-52](/implementations/pipecopy/lua/termichatter/line.lua)) looks correct but is a sparse-table operation that could silently lose queues if indices collide after shift.

---

## Lattice Resolver for Pipecopy

The lattice-resolver concept maps naturally onto pipecopy. Here's how it would fit.

### Registry Enhancement: Pipe Metadata

Add `wants`/`emits` metadata to registered pipe:

```lua
registry:register("validator", {
    handler = pipe.validator,
    wants = { "time" },
    emits = { "validated" },
})
```

Existing pipe that are plain functions (no metadata) continue to work — they simply have no `wants`/`emits` and skip satisfiability checking.

### `lattice_resolver` as a Pipe

A pipe registered in the registry that, when executed in a run:

1. Scans downstream pipe for all `wants`
2. Subtracts facts already in `run.facts`
3. Queries the registry's emits index for provider pipe
4. Runs Kahn's topological sort to compute satisfiable order
5. Calls `run:splice()` to insert resolved pipe after itself

This works directly because pipecopy already has `run:splice` with pos-adjustment.

### Key Addition Needed

| Addition | Where | Description |
|----------|-------|-------------|
| **Emits index** | `registry.lua` | `registry.emits_index: { [fact] = { pipe_name, ... } }`, updated on `register()` |
| **`facts` set on run** | `run.lua` | Track accumulated fact as pipe execute; `run:execute()` adds `pipe.emits` to `run.facts` after each step |
| **Resolver pipe** | `pipe.lua` or new `resolver.lua` | ~40 line of Lua implementing Kahn's sort from the spec |
| **`wants` checking** | `run.lua` `execute()` | Optionally error if a pipe's `wants` aren't satisfied in `run.facts` |

### Why This Is Additive

The design requires no breaking change to existing pipecopy code:

- Pipe without `wants`/`emits` metadata skip satisfiability checks
- The resolver is just another pipe in the `line`
- `run.facts` is a new field, defaulting to empty set, that existing pipe ignore
- Registry gains an index but existing `resolve()` / `register()` calls still work

### Sketch: Resolver Pipe

```lua
function M.lattice_resolver(run)
    -- 1. collect downstream wants
    local all_wants = {}
    for i = run.pos + 1, #run.pipe do
        local p = run:resolve(run.pipe[i])
        if type(p) == "table" and p.wants then
            for _, w in ipairs(p.wants) do
                all_wants[w] = true
            end
        end
    end

    -- 2. subtract available facts
    local unsatisfied = {}
    for w in pairs(all_wants) do
        if not run.facts[w] then
            table.insert(unsatisfied, w)
        end
    end
    if #unsatisfied == 0 then
        return run.input
    end

    -- 3. find provider pipe from registry
    local registry = run.registry or run.line.registry
    local candidate = registry:find_provider(unsatisfied)

    -- 4. topological sort (Kahn's)
    local sorted = kahn_sort(candidate, run.facts)

    -- 5. splice into run
    local name = {}
    for _, p in ipairs(sorted) do
        table.insert(name, p.name or p)
    end
    run:splice(run.pos + 1, 0, unpack(name))

    return run.input
end
```

---

## Multi-Element Scope Problem

> The pipecopy design was written assuming one element flows through one line. In reality, pipe can emit arbitrary element into the next pipe, and a line receives many input over its lifetime. This fundamentally changes the design.

### The Problem

Pipecopy's `run` models a single cursor walking a single element through the pipeline. But real usage is N:M:

- A line receives many input over time
- A pipe can produce 0, 1, or many output element from a single input
- Multiple element may be in-flight at different positions simultaneously

This means:

| Assumption in pipecopy | Reality |
|------------------------|---------|
| One `run` per element | Many element in-flight concurrently |
| `run.input` is *the* element | A pipe may need to emit 3 element to the next pipe |
| `run.pos` is a single cursor | Multiple element may be at different positions |
| `run:splice()` affects one traversal | Splice affects all in-flight element and future element |
| Shallow copy of `pipe` at Run.new | Every fan-out needs its own traversal state |

### Why This Makes Copy Complex

If pipe A emits 3 element, and each needs to traverse pipe B → C → D:

- **With Run:** Do we create 3 Run instance? Each with its own `pipe` copy, `pos`, `facts`? That's a lot of allocation per fan-out.
- **Without Run (implicit flow):** Sync pipe just call `next(element)` multiple times. Async pipe push multiple element into the mpsc. No per-element cursor object needed.

The pipecopy.md's "CRITICAL INSIGHT" was circling this: making a separate object for every element flowing through the system is expensive when pipe fan out. The original system worked because sync pipe just invoked the next pipe directly (call stack *is* the cursor), and async pipe pushed into queues (queue position *is* the cursor).

### Design Direction

Two viable path:

**A. Run becomes lightweight / pooled.** Strip Run down to just `{ input, pos, facts }` — no method, no pipe copy. Method live on the line or a shared prototype. Only copy `pipe` on splice (true copy-on-write). This makes fan-out cheap: spawning a run is just allocating a small table.

**B. Drop Run entirely for the common case.** Sync pipe call `next(element)` to push element forward — the call stack is the cursor. Async pipe push into mpsc — the queue is the cursor. `Run` only materializes when a pipe needs to introspect or splice the pipeline (the resolver case). This matches how the original termichatter worked and avoids per-element allocation.

Option B aligns with the pipecopy.md's own instinct. The line *is* the pipeline. Element flow through it. A cursor object only appears when something needs to rewrite the pipeline mid-flight.

### Impact on Lattice Resolver

The resolver doesn't need per-element state — it inspects the line's structure (downstream `wants`), not the element. So the resolver works fine with either approach:

- It reads the line's `pipe` array to find downstream wants
- It calls `line:splice()` (not `run:splice()`) to insert resolved pipe
- This happens once (or once per `rev` change), not per-element

The `facts` accumulation is trickier in multi-element mode. Facts describe what the *pipeline* can produce, not what a single element has accumulated. So `facts` belongs on the line (or is computed statically from pipe metadata), not tracked per-element at runtime.

### Sketch: Implicit Flow with `next`

```lua
-- pipe receives: element, context (the line or a lightweight view of it)
-- pipe calls next() to emit element downstream
function my_splitter(element, ctx)
    -- fan out: emit multiple element
    for _, part in ipairs(element.parts) do
        ctx.next(part)
    end
    -- returning nil means "I already pushed, don't auto-forward"
end

function my_transformer(element, ctx)
    element.transformed = true
    return element  -- single return = auto-forward to next
end
```

The line executor:

```lua
function line:send(element, start_pos)
    start_pos = start_pos or 1
    for i = start_pos, #self.pipe do
        local handler = self:resolve_pipe(self.pipe[i])
        local queue = self.mpsc[i]
        if queue then
            queue:push(element)
            return  -- async handoff, consumer picks up
        end
        local ctx = {
            line = self,
            pos = i,
            next = function(el)
                self:send(el, i + 1)
            end,
        }
        local result = handler(element, ctx)
        if result == nil then
            return  -- pipe handled forwarding itself (fan-out)
        end
        if result == false then
            return  -- filtered
        end
        element = result
    end
    -- past end of pipe: push to output
    if self.output then
        self.output:push(element)
    end
end
```

This is ~20 line, no Run object, supports fan-out natively, and `ctx.next` is the escape hatch for multi-emit pipe. The recursive `self:send` call for fan-out does mean stack depth scales with (fan-out × remaining pipe), which is the same tradeoff as the current `push()` approach but more explicit.

### The Run as Accumulated Context

The lattice resolver's design assumes the run is where context is built. Pipe execute, facts accumulate, and the resolver reads those facts to decide what to splice. The run isn't just a cursor — it's the evolving state of "what has been established so far."

This reframes the problem. Dropping Run entirely (option B above) loses the accumulation site. The `line:send` sketch has no place to track that pipe 1 established `time` and pipe 2 established `enriched`, which the resolver at pipe 3 needs to know.

But fan-out means cloning this context, and the run already feels significant to create:

- `pipe` array (shallow copy)
- `pos`, `posName`, `current`
- `facts` (the accumulated context)
- metatable chain to line
- all the method copied onto it (the bug from the review — but even with metatables, the table itself has fields)

**The weight question:** How much of the run's context is *shared* vs *per-element*?

| Context | Shared or per-element | Notes |
|---------|----------------------|-------|
| `pipe` array | Shared until splice | Copy-on-write: only clone on splice |
| `registry` | Shared | Lives on line, inherited |
| `facts` accumulated upstream | Shared | All fan-out children start with same upstream facts |
| `facts` accumulated downstream | Per-element | Different element may take different path |
| `pos` | Per-element | Each element has its own position |
| `input` | Per-element | The element itself |
| `rev` | Shared | Line-level |

Most of the weight is shared. The per-element state is really just `{ input, pos, facts_ref }`. If we separate these:

**Structural context (on line, built once or on splice):**
- The `pipe` array
- The registry
- The resolved pipeline (lattice resolver output)
- The static facts graph (what the pipeline *can* produce)

**Element context (per-element, lightweight):**
- The element itself
- Current position
- Reference to (or fork of) the facts set

This suggests a two-tier approach: the line holds the resolved structure, and the "run" shrinks to a tiny per-element envelope. Fan-out clones the envelope, not the structure.

```lua
-- element context: the lightweight per-element state
-- NOT the full Run with methods and pipe copies
local function make_element_ctx(line, element, pos, fact)
    return {
        input = element,
        pos = pos,
        fact = fact,  -- shared ref until fork needed
        line = line,  -- structural context
    }
end

-- fan-out: cheap clone
local function fork_ctx(ctx, new_element)
    return {
        input = new_element,
        pos = ctx.pos,
        fact = ctx.fact,  -- share upstream fact (copy-on-write if needed)
        line = ctx.line,
    }
end
```

The lattice resolver operates on `ctx.line` (structural), reading downstream pipe metadata and splicing the line. It reads `ctx.fact` to know what's been established. But it doesn't need the full Run apparatus.

**Open question:** Do downstream facts actually diverge per-element? If pipe B fans out 3 element and they all flow through pipe C → D, they all accumulate the same facts (because facts describe "pipe C ran" not "element X has property Y"). If facts are structural — "this pipe position has executed" — then facts don't need to fork at all. They're a property of the pipeline's progress, not the element's state.

If facts ARE per-element (e.g., a conditional pipe that only emits a fact for some element), then forking is necessary but still cheap — it's just a set copy.

---

## Splice-Position Synchronization

When the line is spliced (by the resolver, by user code, by another pipe), in-flight run positions go stale. A run at `pos=3` might now be pointing at a different pipe than the one it was about to execute. This is a must-have capability to solve.

### The Problem Concretely

```
Line before splice:  [A, B, C, D]
Run α at pos=3 (C), Run β at pos=1 (A)

Splice at 2: insert [X, Y] after B
Line after splice:   [A, B, X, Y, C, D]

Run α still has pos=3 → now points at X, not C
Run β still has pos=1 → still points at A (correct by luck)
```

Run α is now executing the wrong pipe. If it's between exec steps, it'll skip C entirely and run X instead.

### Strategy 1: Immutable Line (Snapshot Isolation)

Each splice produces a new line. Run hold a reference to the line they were born from and execute against that snapshot. New element get the new line.

```lua
function line:splice(startIndex, deleteCount, ...)
    -- create new line with the splice applied
    local new_line = self:clone()
    -- apply splice to new_line.pipe ...
    new_line.rev = self.rev + 1
    return new_line  -- caller replaces their reference
end
```

**Pros:**
- Simple mental model: a run's pipeline never changes under it
- No synchronization needed
- Naturally safe for concurrent element

**Cons:**
- Resolver splicing doesn't affect in-flight element — they finish on the old pipeline, only new element see the resolved pipeline
- If the *point* of splicing is to affect the current run (resolver inserting pipe ahead of downstream), this doesn't work without the run itself holding the new line
- Multiple live line version if many splice happen while element are in-flight

**Verdict:** Good default for "line evolves over time" (config changes, plugin registration). Not sufficient alone for resolver-style "splice into my own execution."

### Strategy 2: Versioned Splice Journal

The line's `rev` (already exists) becomes a synchronization point. Record each splice as a journal entry. Run check their `rev` against the line's `rev` and replay splice delta to adjust `pos`.

```lua
-- on the line
line.rev = 0
line.splice_journal = {}  -- { { rev=1, start=2, deleted=0, inserted=2 }, ... }

function line:splice(startIndex, deleteCount, ...)
    local new = { ... }
    -- apply splice to self.pipe ...
    self.rev = self.rev + 1
    table.insert(self.splice_journal, {
        rev = self.rev,
        start = startIndex,
        deleted = deleteCount,
        inserted = #new,
    })
    return deleted
end
```

```lua
-- on the run / element context, before each step
function ctx:sync()
    if self.rev == self.line.rev then
        return  -- up to date
    end
    -- replay journal entries we haven't seen
    for _, entry in ipairs(self.line.splice_journal) do
        if entry.rev > self.rev then
            -- adjust pos based on splice
            if self.pos >= entry.start + entry.deleted then
                -- past the splice zone: shift by net change
                self.pos = self.pos - entry.deleted + entry.inserted
            elseif self.pos >= entry.start then
                -- inside the deleted zone: snap to splice point
                self.pos = entry.start
            end
            -- before the splice zone: no change
        end
    end
    self.rev = self.line.rev
    self.pipe = self.line.pipe  -- re-share the line's pipe array
end
```

**Pros:**
- Run can catch up at any time — between steps, after yielding from async, etc.
- Splice journal is small (one entry per splice, not per-pipe)
- Works for resolver splicing: resolver splices the line, run syncs before next step and sees the new pipe
- `rev` check is O(1) in the common case (no splice happened)

**Cons:**
- Journal grows unbounded unless trimmed (trim when all run have caught up, or use a ring buffer)
- "Inside the deleted zone" case is inherently lossy — if the pipe you were about to execute got deleted, there's no perfect recovery
- Run need to call `sync()` — a missed sync means stale pos

**Verdict:** Best fit for the resolver use case. The resolver splices the line, the current run syncs immediately (it's the one that triggered the splice), and other in-flight run sync on their next step.

### Strategy 3: Position by Identity, Not Index

Run don't track `pos` as an integer. They track "I am at pipe C" by name or identity reference. After any splice, they search for their anchor in the (possibly modified) pipe array.

```lua
function ctx:find_pos()
    if self.rev == self.line.rev then
        return self.pos  -- cached
    end
    for i, p in ipairs(self.line.pipe) do
        if p == self.anchor or (type(p) == "string" and p == self.anchor_name) then
            self.pos = i
            self.rev = self.line.rev
            return i
        end
    end
    -- anchor pipe was removed
    return nil
end
```

**Pros:**
- Always correct if the pipe still exists — no delta arithmetic
- Works even after complex multi-splice sequences
- Simple to reason about

**Cons:**
- O(N) scan per sync (N = pipe count), vs O(journal_length) for strategy 2
- Fails if the same pipe name appears multiple times in the line
- Requires pipe to have stable identity (name or table reference)
- If a pipe is deleted, there's no "nearby" recovery without heuristics

**Verdict:** Good as a fallback / validation layer. Expensive as the primary mechanism if pipe count grows, but pipeline are typically short (5-15 pipe), making O(N) negligible.

### Strategy 4: Hybrid — Journal + Identity Anchor

Combine strategies 2 and 3. Use the journal for fast delta adjustment, but also record an identity anchor for validation:

```lua
function ctx:sync()
    if self.rev == self.line.rev then
        return
    end
    -- fast path: replay journal
    for _, entry in ipairs(self.line.splice_journal) do
        if entry.rev > self.rev then
            -- adjust pos ...
        end
    end
    self.rev = self.line.rev

    -- validate: is the pipe at our adjusted pos the one we expect?
    local current = self.line.pipe[self.pos]
    if current ~= self.anchor and current ~= self.anchor_name then
        -- journal adjustment landed wrong, fall back to scan
        self:find_pos()
    end
end
```

**Pros:**
- Journal handles the common case fast
- Identity scan catches edge cases (pipe reordered, duplicates, complex multi-splice)
- Self-correcting

**Cons:**
- Slightly more complex
- Still needs the "pipe deleted" fallback

### Recommendation

**Strategy 2 (versioned splice journal)** as the primary mechanism, with the `rev` fast-path check already natural from pipecopy's existing `rev` field. The journal is tiny, sync is cheap, and it handles the resolver's "splice into the live pipeline" case directly.

Add the identity anchor from strategy 3 as a debug/validation assertion, not as the primary pos-tracking mechanism. In debug mode, verify that `self.pipe[self.pos]` matches expectations after sync.

Strategy 1 (immutable snapshot) remains available as `line:clone()` for the case where you genuinely want isolation — a long-running consumer that shouldn't see mid-flight changes.

### Journal Lifecycle

The splice journal needs trimming. Two option:

1. **Watermark:** Track the minimum `rev` across all active run. Trim journal entries below the watermark. Requires run to register/deregister (or use weak reference).

2. **Bounded ring:** Keep last N splice entries (e.g., 16). If a run is so far behind that it's missed entries, fall back to identity scan. Pipeline rarely splice more than a few times per lifetime, so N=16 is generous.

Option 2 is simpler and sufficient — if a run has missed 16+ splice, it's likely stale enough that a full re-scan is appropriate.

---

## Run Independence & Forking

> The run starts as a thin overlay on the line. It reads through to the line for everything — pipe, fact, registry, output. But it needs tools to *sever* these connections and carry context on its own. This is the construction kit for cloning, fan-out, and pipeline rewriting.

### Principle: Lazy Materialization

By default, the run owns nothing. It reads through metatables to `self.line`. Only when it needs to diverge does it allocate its own copy. This makes the common case (one element, no fan-out, no splice) nearly zero-cost.

The act of taking ownership of a field — snapshotting it locally so the run no longer depends on the line's version — we call **`own`**.

### `pipe` as a First-Class Object

The pipe array carries its own `rev`, `splice()`, and `clone()`. This makes swapping atomic: when a run owns its pipe, it gets an independent object with its own revision history.

```lua
local function make_pipe(entry)
    local p = {}
    for i, e in ipairs(entry) do
        p[i] = e
    end
    p.rev = 0
    p.splice_journal = {}

    function p:splice(startIndex, deleteCount, ...)
        local new = { ... }
        local deleted = {}
        for i = 1, deleteCount do
            local idx = startIndex + i - 1
            if self[idx] then
                table.insert(deleted, self[idx])
            end
        end
        for _ = 1, deleteCount do
            table.remove(self, startIndex)
        end
        for i, pipe in ipairs(new) do
            table.insert(self, startIndex + i - 1, pipe)
        end
        self.rev = self.rev + 1
        table.insert(self.splice_journal, {
            rev = self.rev,
            start = startIndex,
            deleted = deleteCount,
            inserted = #new,
        })
        return deleted
    end

    function p:clone()
        local c = make_pipe(self)
        c.rev = self.rev  -- start from parent's revision
        return c
    end

    return p
end
```

The pipe is both an array (integer keys hold pipe name/handler) and an object (hash keys hold `rev`, `splice`, `clone`, `splice_journal`). Standard Lua pattern.

### `fact` with Lazy Copy-on-Write

`fact` is a set (table of `name → true`). The run's fact reads through to `self.line.fact` via the run's metatable until the run writes its own first fact. At that point, a local fact table is created with `__index` pointing to `self.line.fact`, so reads still fall through for fact the run hasn't overridden.

```lua
-- On run creation: fact is NOT set on the run.
-- Reading run.fact falls through __index to line.fact.
-- This is free.

-- To write a fact, use set_fact:
function Run:set_fact(name, value)
    if value == nil then value = true end
    local own = rawget(self, "fact")
    if not own then
        -- first write: create local fact with read-through to line
        own = setmetatable({}, { __index = self.line.fact })
        rawset(self, "fact", own)
    end
    own[name] = value
end

-- Reading: run.fact[name] works naturally.
-- Before first write: run.fact IS line.fact (shared reference).
-- After first write: run.fact is local table with __index to line.fact.
```

This means:
- 0 element flowing through → no fact table allocated per run
- Element that establish fact → one small table, reads still fall through for line-level fact
- Forked element share upstream fact without copying

### `own()`: Severing a Single Dependency

```lua
--- Take ownership of a field, breaking read-through to line
--- After own(), this field is local to the run and independent
---@param field string Field name to own ("pipe", "fact", "output", ...)
function Run:own(field)
    if rawget(self, field) ~= nil then
        -- already owned, but may need deep copy for some fields
        if field == "pipe" then
            local current = rawget(self, field)
            if current == self.line.pipe then
                rawset(self, "pipe", current:clone())
            end
        elseif field == "fact" then
            -- already have local fact table, snapshot it fully
            local current = rawget(self, field)
            local snapshot = {}
            -- walk the metatable chain to capture everything
            for k, v in pairs(self.line.fact or {}) do
                snapshot[k] = v
            end
            -- overlay with own fact
            for k, v in pairs(current) do
                snapshot[k] = v
            end
            rawset(self, "fact", snapshot)  -- no more __index
        end
        return
    end

    -- field not owned yet: snapshot from line
    local current = self[field]  -- reads through metatable
    if current == nil then return end

    if field == "pipe" then
        rawset(self, "pipe", current:clone())
    elseif field == "fact" then
        -- snapshot all fact into independent table
        local snapshot = {}
        for k, v in pairs(current) do
            snapshot[k] = v
        end
        rawset(self, "fact", snapshot)
    else
        -- generic field: just set directly (shares reference)
        rawset(self, field, current)
    end
end
```

### `clone()`: Lightweight Fan-Out

Default clone shares everything. Only `input` and `pos` are per-element.

```lua
--- Clone this run for fan-out. Maximally lightweight.
--- Shares pipe, fact, line, registry, output with parent.
---@param new_input any The new element for the clone
---@return table run New run context
function Run:clone(new_input)
    local child = inherit.derive(self.line, {
        type = "run",
        line = self.line,
        input = new_input,
        pos = self.pos,
    })
    -- methods come from Run prototype via metatable, not copied
    setmetatable(child, { __index = function(t, k)
        -- check Run methods first
        local method = Run[k]
        if method ~= nil then return method end
        -- then check the parent run (for owned fields like fact)
        local from_self = rawget(self, k)  -- NOT self[k], avoid infinite chain
        if from_self ~= nil then return from_self end
        -- then fall through to line
        return self.line[k]
    end })
    return child
end
```

The clone reads through to the parent run first (so it sees the parent's owned fact, owned pipe), then to the line. It costs one table with 4 fields.

### `fork()`: Full Independence

For when a run needs to completely detach — carry everything locally, survive line changes.

```lua
--- Fork: clone + own everything. Fully independent run.
---@param new_input any The element for the fork
---@return table run Independent run context
function Run:fork(new_input)
    local forked = self:clone(new_input or self.input)
    forked:own("pipe")
    forked:own("fact")
    return forked
end
```

### `next()`: The Run Advances Itself

The run IS the context. Calling `next()` advances and executes. For fan-out, clone then next.

```lua
--- Advance to next pipe and continue execution
---@param element? any Optional new input (for fan-out push)
function Run:next(element)
    if element ~= nil then
        self.input = element
    end
    self.pos = self.pos + 1
    if self.pos <= #self.pipe then
        self:execute()
    else
        -- past end: push to output
        local output = rawget(self, "output") or self.line.output
        if output then
            output:push(self.input)
        end
    end
end
```

Fan-out example:

```lua
-- a pipe that splits an element into parts
function splitter(run)
    for _, part in ipairs(run.input.part) do
        local child = run:clone(part)
        child:next()
    end
    -- return nil: we handled forwarding
end
```

Each `clone()` costs ~one small table. Each `next()` walks the shared pipe array. No copying unless a child needs to diverge.

### Independence Spectrum

| Operation | Cost | What's owned | Use case |
|-----------|------|-------------|----------|
| Just advance (`next()`) | 0 alloc | Nothing new | Normal single-element flow |
| `clone(el)` | 1 small table | input, pos | Fan-out, lightweight |
| `clone(el)` + `set_fact()` | 2 small table | input, pos, fact overlay | Element that establish per-element fact |
| `clone(el)` + `own("pipe")` | 1 small + pipe clone | input, pos, pipe | Element that may splice its own path |
| `fork(el)` | Everything cloned | All field | Full detach, survives line mutation |

### Rev Sync with Owned Pipe

When a run shares the line's pipe (default), it also shares the rev. It needs to sync. When a run owns its pipe (after `own("pipe")` or `fork()`), it has its own rev — it's independent and doesn't need to sync.

```lua
--- Sync position with line's pipe if we're sharing it
function Run:sync()
    local own_pipe = rawget(self, "pipe")
    if own_pipe then
        -- we own our pipe, no sync needed
        return
    end
    -- sharing line's pipe: check rev
    local line_pipe = self.line.pipe
    if self._rev == line_pipe.rev then
        return
    end
    -- replay journal...
    for _, entry in ipairs(line_pipe.splice_journal) do
        if entry.rev > (self._rev or 0) then
            if self.pos >= entry.start + entry.deleted then
                self.pos = self.pos - entry.deleted + entry.inserted
            elseif self.pos >= entry.start then
                self.pos = entry.start
            end
        end
    end
    self._rev = line_pipe.rev
end
```

The `sync()` call goes at the top of `execute()`, before each step. When the run shares the line's pipe, it's O(1) in the common case (rev matches). When the run owns its pipe, the check is a single `rawget`.

### Open Design Question

**Should `clone` inherit from the parent run or from the line?**

If clone inherits from the parent run, we get a chain: `clone → parent_run → line`. The clone sees the parent's owned fact (good for "continue with same accumulated context"). But deep fan-out creates long metatable chains.

If clone inherits from the line directly, we get: `clone → line`. Simpler, but the clone loses any per-element fact the parent accumulated. The parent would need to `own("fact")` first and the clone would need explicit access.

Recommendation: inherit from the parent run. The chain depth equals the fan-out depth, which is bounded in practice. And it gives the right semantics — a cloned element sees everything the parent saw.

### Sketch: Kahn's Sort in Lua

```lua
local function kahn_sort(candidate, initial_fact)
    local available = {}
    for k in pairs(initial_fact) do
        available[k] = true
    end

    local scheduled = {}
    local remaining = {}
    for _, c in ipairs(candidate) do
        remaining[c] = true
    end

    local progress = true
    while progress and next(remaining) do
        progress = false
        for pipe in pairs(remaining) do
            local satisfied = true
            if pipe.wants then
                for _, w in ipairs(pipe.wants) do
                    if not available[w] then
                        satisfied = false
                        break
                    end
                end
            end
            if satisfied then
                table.insert(scheduled, pipe)
                remaining[pipe] = nil
                if pipe.emits then
                    for _, e in ipairs(pipe.emits) do
                        available[e] = true
                    end
                end
                progress = true
            end
        end
    end

    if next(remaining) then
        return nil -- unsatisfiable
    end
    return scheduled
end
```
