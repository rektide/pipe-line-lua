# ADR: Async Queueing via Boundary Segments

- Status: Accepted
- Date: 2026-02-25
- Decision makers: termichatter maintainers

## Decision

Termichatter will model async queue handoff as explicit boundary segments in the pipe (for example `mpsc_handoff`), not as implicit per-position segment capability.

We keep the project vocabulary on **segment** (not "stage").

## Context

Current implementation supports async handoff by position (`line.mpsc[pos]`) and consumers keyed by position. This was recently improved for lifecycle idempotence, but the underlying model remains position-coupled.

Relevant implementation files:

- [`/lua/termichatter/run.lua`](/lua/termichatter/run.lua)
- [`/lua/termichatter/consumer.lua`](/lua/termichatter/consumer.lua)
- [`/lua/termichatter/line.lua`](/lua/termichatter/line.lua)

Design discussion highlighted that runs are self-iterating cursors, and async behavior is an execution detail. We want queue boundaries to be visible and stable under pipe mutation.

## Problem

Position-based async has structural fragility:

- Splice/reorder before an async position can silently retarget queueing.
- Multiple identical segment names can be ambiguous if async policy is keyed only by name.
- Pipe definition does not fully describe execution boundaries; behavior is partly out-of-band.
- Debugging and review are harder because queue handoff points are implicit.

## Options considered

### Option A: Segment capability (implicit mapping)

Examples:

- `line.queue[segment_id] = queue`
- `line.mpsc[pos] = queue` (current)
- optional `run.queue` override

Pros:

- Late-binding operational control.
- Global policy by segment type without rewriting pipes.
- Convenient for experiments and toggles.

Cons:

- Hidden behavior; reduced pipeline readability.
- Ambiguity with duplicate segment entries.
- Extra reconciliation complexity when pipes mutate.

### Option B: Explicit boundary segment (chosen)

Example conceptual pipe:

`[timestamper, ingester, mpsc_handoff, cloudevent, module_filter]`

Pros:

- Pipe is truthful: execution boundaries are first-class and inspectable.
- Stable semantics under splice/clone/reorder (boundary travels with the pipe entry).
- Easier tracing, test assertions, and documentation.

Cons:

- Slightly more verbose pipeline definitions.
- Operational toggles may require pipe mutation (or resolver rewrites).

### Option C: Hybrid

Keep capability mapping plus boundary segments, with precedence rules.

Pros:

- Maximum flexibility.

Cons:

- More cognitive load and policy overlap.
- Harder to explain defaults and conflict resolution.

## Rationale

We choose Option B because explicitness and structural stability are stronger design goals for termichatter at this stage than dynamic policy convenience.

This aligns with existing architecture direction where pipe entries and rewrites are central. If queue boundaries are semantically meaningful, they should be represented directly in the pipe.

## Consequences

Positive:

- Queue boundaries are visible in config, docs, and traces.
- Fewer hidden couplings to positional metadata.
- Simpler reasoning during resolver and fan-out behavior reviews.

Tradeoffs:

- Users may need helper APIs for ergonomic insertion/removal of boundary segments.
- Position-based async APIs (`ensure_mpsc(pos)`, positional maps) are removed, not deprecated.

## Implementation direction

1. Introduce an explicit handoff segment (`mpsc_handoff` name may be finalized).
2. Route consumer lifecycle through boundary segment identity rather than raw positional maps.
3. Remove old per-position async capability and compatibility helpers entirely.
4. Add regression tests for:
   - splice before/after handoff boundary,
   - clone/fork behavior around handoff boundaries,
   - duplicate segment names with distinct handoff boundaries.

## Deferred / not decided

- Whether resolver can auto-insert handoff boundaries based on configuration.
- Final naming and metadata shape for boundary segment configuration.

## Related notes

- Current review notes: [`/doc/discovery/status.md`](/doc/discovery/status.md)
- Earlier pipe architecture exploration: [`/doc/review/pipecopy-next.md`](/doc/review/pipecopy-next.md)
- Project overview: [`/README.md`](/README.md)
