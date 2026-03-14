# Documentation Index

## Normative — Contracts and Guides

These define the current architecture. Read these to understand pipe-line.

| Document | Created | Description |
|----------|---------|-------------|
| [`segment-authoring.md`](/doc/segment-authoring.md) | 2026-02-26 | Segment contract: `handler(run)`, lifecycle hooks, return semantics, protocol pass-through via `define()` |
| [`segment-instancing.md`](/doc/segment-instancing.md) | 2026-02-26 | How registry prototypes become per-line runtime instances; `auto_fork`/`auto_instance`/`auto_id`; continuation ownership |
| [`selecting.md`](/doc/selecting.md) | 2026-02-26 | `line:select_segments()` and `line:stopped_live()` for runtime segment queries |
| [`lifecycle.md`](/doc/lifecycle.md) | 2026-02-26 | Line lifecycle orchestration: `ensure_prepared`, `ensure_stopped`, `close`, hook context shape, strategy-specific stop |
| [`async-handoff.md`](/doc/async-handoff.md) | 2026-02-26 | Explicit async boundaries via `mpsc_handoff`; custom handoff; manual continuation mode |
| [`completion-protocol.md`](/doc/completion-protocol.md) | 2026-02-26 | Completion control runs, state accounting, completion segment stop behavior |
| [`metatables.md`](/doc/metatables.md) | 2026-03-13 | All metatable chains: line→parent, run→line, clone→parent run, segment instances, registry derivation, fact overlays, ownership semantics |

## Architecture Decision Records

| Document | Created | Description |
|----------|---------|-------------|
| [`adr/README.md`](/doc/adr/README.md) | 2026-02-26 | ADR index |
| [`adr/adr-transport-policy-interface.md`](/doc/adr/adr-transport-policy-interface.md) | 2026-02-26 | Transport wrappers compose on core `handler(run)` contract; removes `handler_async`/`configure_segment` |
| [`adr/adr-stop-drain-and-cancel-signal.md`](/doc/adr/adr-stop-drain-and-cancel-signal.md) | 2026-02-26 | Strategy-specific stop futures and verbs (`stop_drain`, `stop_immediate`). Proposed; not yet fully implemented. |

## Discovery — Active Explorations

Working notes for in-progress design and audit work. May inform future normative docs.

| Document | Created | Description |
|----------|---------|-------------|
| [`discovery/doc-fixes.md`](/doc/discovery/doc-fixes.md) | 2026-03-13 | Audit of all doc files against current code; tracked discrepancies and recommendations |
| [`discovery/readme-pipe-line.md`](/doc/discovery/readme-pipe-line.md) | 2026-03-13 | Guide used for README rewrite: source material, content goals, contract language |
| [`discovery/adr-async-boundary-segments.md`](/doc/discovery/adr-async-boundary-segments.md) | 2026-02-25 | Exploratory notes on async boundary segment decomposition |

## Archive — Superseded

Historical documents. These reflect earlier designs and are preserved for rationale context only.

| Document | Created | Description |
|----------|---------|-------------|
| [`archive/consumer.md`](/doc/archive/consumer.md) | 2026-02-07 | Old consumer API (`create`, `createPipeline`, `withDriver`); fully superseded by run-centric handoff model |
| [`archive/mpsc-decomposition.md`](/doc/archive/mpsc-decomposition.md) | 2026-02-26 | mpsc decomposition design exploration |
| [`archive/mpsc-decomp-tasks.md`](/doc/archive/mpsc-decomp-tasks.md) | 2026-02-26 | Task breakdown for mpsc decomposition |
| [`archive/coop2.md`](/doc/archive/coop2.md) | 2026-02-26 | coop.nvim integration notes |
| [`archive/coop-tools.md`](/doc/archive/coop-tools.md) | 2026-02-04 | coop utility exploration |
| [`archive/requirements.md`](/doc/archive/requirements.md) | 2026-02-04 | Early requirements |
| [`archive/pipecopy.md`](/doc/archive/pipecopy.md) | 2026-02-14 | Pipe copy design iteration |
| [`archive/pipecopy-next.md`](/doc/archive/pipecopy-next.md) | 2026-02-20 | Pipe copy design iteration (follow-up) |
| [`archive/pipenext-status.md`](/doc/archive/pipenext-status.md) | 2026-02-21 | Pipe-next status snapshot |
| [`archive/status.md`](/doc/archive/status.md) | 2026-02-23 | Historical status snapshot |
| [`archive/status2.md`](/doc/archive/status2.md) | 2026-02-26 | Historical status snapshot |
| [`archive/self-ify.md`](/doc/archive/self-ify.md) | 2026-02-12 | Self-ification refactor notes |
| [`archive/re-async.md`](/doc/archive/re-async.md) | 2026-02-26 | Async model re-examination notes |
| [`archive/rename.md`](/doc/archive/rename.md) | 2026-03-13 | Naming and rename considerations |
| [`archive/pipeflow/`](/doc/archive/pipeflow/) | 2026-02-14 | Earlier pipeflow design artifacts (Effect-based explorations, lattice resolver) |

## Other

| Document | Created | Description |
|----------|---------|-------------|
| [`termichatter.txt`](/doc/termichatter.txt) | 2026-02-04 | Neovim help file (vimdoc) |
