# Fresh README Outline (`pipe-line`)

This note proposes a fresh structure for [`/README.md`](/README.md), centered on current contracts and ADR decisions.

## Goals

- Make README short, current, and contract-first.
- Explain core runtime model in one pass (Line / Pipe / Segment / Run).
- Make async behavior explicit without overloading beginners.
- Link to deep docs instead of duplicating full internals.

## Proposed README Structure

1. **Title + one-line value statement**
   - What `pipe-line` is and what it is not.
2. **Core runtime model**
   - Line, Pipe, Segment, Run in a compact diagram or bullet list.
3. **Quick start**
   - minimal setup
   - minimal log/example call path
4. **Segment contract**
   - `handler(run)` as the per-message entrypoint
   - lifecycle hooks: `init`, `ensure_prepared`, `ensure_stopped`
5. **Continuation handoff model**
   - boundary handlers typically hand off then return `false`
   - continuation resumes later via `continuation:next(...)`
   - run-owned continuation tracking via `run.continuation`
6. **Async boundaries**
   - `mpsc_handoff` and queue boundaries
   - when to use boundary segments
7. **Stop behavior**
   - `stop_type`
   - `stop_drain` (default) vs `stop_immediate`
8. **Completion protocol**
   - control runs and completion settlement model
9. **Authoring and extension links**
   - segment authoring, instancing, lifecycle, ADRs
10. **Project status and references**
   - testing command
   - canonical docs index

## Suggested Section-Level Citations

Use these as direct references from README sections:

- Segment contract: [`/doc/segment-authoring.md`](/doc/segment-authoring.md)
- Continuation semantics: [`/doc/segment-authoring.md`](/doc/segment-authoring.md)
- Async handoff usage: [`/doc/async-handoff.md`](/doc/async-handoff.md)
- Lifecycle and stop orchestration: [`/doc/lifecycle.md`](/doc/lifecycle.md)
- Completion semantics: [`/doc/completion-protocol.md`](/doc/completion-protocol.md)
- Segment instancing model: [`/doc/segment-instancing.md`](/doc/segment-instancing.md)
- ADR index: [`/doc/adr/README.md`](/doc/adr/README.md)
- Transport policy decision: [`/doc/adr/adr-transport-policy-interface.md`](/doc/adr/adr-transport-policy-interface.md)
- Stop strategy decision: [`/doc/adr/adr-stop-drain-and-cancel-signal.md`](/doc/adr/adr-stop-drain-and-cancel-signal.md)

## Tone and Scope Guidance

- Keep README explanatory, not exhaustive.
- Prefer stable terms from current contract (`handler(run)`, `run.continuation`, `stop_type`).
- Avoid superseded terms in primary API explanation (`dispatch`, `handler_async`, `configure_segment`).
- Keep discovery/archive materials out of README citations unless explicitly marked historical.

## Example README "Docs Map" Block

```md
## Docs Map

- Segment Contract: [`/doc/segment-authoring.md`](/doc/segment-authoring.md)
- Async Boundary Handler Contract: [`/doc/segment-authoring.md`](/doc/segment-authoring.md)
- Async Boundary Usage: [`/doc/async-handoff.md`](/doc/async-handoff.md)
- Lifecycle + Stop Strategy: [`/doc/lifecycle.md`](/doc/lifecycle.md)
- Completion Protocol: [`/doc/completion-protocol.md`](/doc/completion-protocol.md)
- ADR Index: [`/doc/adr/README.md`](/doc/adr/README.md)
```

## Rewrite Checklist

- Verify code snippets import current module names consistently.
- Verify all file links resolve to current paths.
- Ensure quick start uses the same vocabulary as segment docs.
- Ensure async section references async boundary handler contract explicitly.
- Ensure stop section references `stop_type` strategy terms exactly.
