# EFFECT-WALK-MERGED: Lattice Pipeline with Dependency Resolution

> Universal pipeline where stages declare `wants` and `emits`, executing when dependencies are satisfied

## Core Concept: Dependency-Driven Execution

Stages don't run in fixed order. They run **when their dependencies are available**.

```typescript
// A stage declares what it needs and what it produces
interface Stage {
  name: string
  wants: string[]   // Facts required before this can run
  emits: string[]   // Facts this stage produces
  run: (ctx: Context) => Effect<Facts>
}
```

### Example: Project Analysis Pipeline

```typescript
const stages: Stage[] = [
  {
    name: "dirent",
    wants: [],                          // No dependencies - runs first
    emits: ["dirent", "path"],
    run: (ctx) => readDirectory(ctx.path)
  },
  {
    name: "git-worktree",
    wants: ["path"],                    // Needs path
    emits: ["git-worktree", "git-root"],
    run: (ctx) => findGitRoot(ctx.path)
  },
  {
    name: "git-origin",
    wants: ["git-root"],                // Needs git-root from git-worktree
    emits: ["git-origin"],
    run: (ctx) => gitRemoteUrl(ctx["git-root"])
  },
  {
    name: "git-branch",
    wants: ["git-root"],                // Also needs git-root (parallel with git-origin)
    emits: ["git-branch"],
    run: (ctx) => gitCurrentBranch(ctx["git-root"])
  },
  {
    name: "package-json",
    wants: ["path", "dirent"],          // Needs directory listing
    emits: ["npm-package", "npm-version"],
    run: (ctx) => parsePackageJson(ctx.path, ctx.dirent)
  },
  {
    name: "cargo-toml",
    wants: ["path", "dirent"],
    emits: ["cargo-package", "cargo-version"],
    run: (ctx) => parseCargoToml(ctx.path, ctx.dirent)
  },
  {
    name: "project-type",
    wants: ["dirent"],
    emits: ["project-type"],            // "npm" | "cargo" | "mixed" | "unknown"
    run: (ctx) => detectProjectType(ctx.dirent)
  },
  {
    name: "last-commit",
    wants: ["git-root", "git-branch"],  // Needs both git facts
    emits: ["git-last-commit", "git-last-commit-date"],
    run: (ctx) => gitLastCommit(ctx["git-root"])
  }
]
```

### Dependency Graph Visualization

```
                    ┌─────────────────────────────────────────┐
                    │              (start)                     │
                    │           path provided                  │
                    └─────────────┬───────────────────────────┘
                                  │
                    ┌─────────────▼───────────────┐
                    │          dirent             │
                    │   wants: []                 │
                    │   emits: [dirent, path]     │
                    └─────────────┬───────────────┘
                                  │
          ┌───────────────────────┼───────────────────────┐
          │                       │                       │
          ▼                       ▼                       ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  git-worktree   │    │  package-json   │    │   cargo-toml    │
│ wants: [path]   │    │ wants: [path,   │    │ wants: [path,   │
│ emits: [git-    │    │        dirent]  │    │        dirent]  │
│   worktree,     │    │ emits: [npm-*]  │    │ emits: [cargo-*]│
│   git-root]     │    └─────────────────┘    └─────────────────┘
└────────┬────────┘
         │
         ├────────────────────────┐
         │                        │
         ▼                        ▼
┌─────────────────┐    ┌─────────────────┐
│   git-origin    │    │   git-branch    │
│ wants: [git-    │    │ wants: [git-    │
│         root]   │    │         root]   │
│ emits: [git-    │    │ emits: [git-    │
│       origin]   │    │       branch]   │
└─────────────────┘    └────────┬────────┘
                                │
                    ┌───────────┴───────────┐
                    │                       │
                    ▼                       │
         ┌─────────────────┐                │
         │   last-commit   │◄───────────────┘
         │ wants: [git-    │
         │   root, git-    │
         │   branch]       │
         │ emits: [git-    │
         │   last-commit]  │
         └─────────────────┘
```

**Key point**: `git-origin` and `git-branch` run in **parallel** because both only need `git-root`. `last-commit` waits for **both** to complete.

---

## Two Execution Modes

### Mode 1: Accumulation (walk/fexec)

Single element builds up context as stages complete.

```typescript
// One project, accumulate all facts
const projectCtx = await runAccumulate(stages, { path: "~/src/myproject" })
// Result: { path, dirent, git-root, git-origin, git-branch, npm-package, ... }
```

**Use case**: Analyze one thing deeply.

### Mode 2: Flow (termichatter)

Multiple elements flow through, each getting processed.

```typescript
// Many log messages, each transformed
const outputs = await runFlow(stages, [msg1, msg2, msg3])
// Result: [transformed1, transformed2, transformed3]
```

**Use case**: Process stream of items.

### Mode 3: Recursive Spawn

Parent pipeline spawns child accumulations.

```typescript
const topLevel: Stage[] = [
  {
    name: "find-projects",
    wants: ["path"],
    emits: ["projects"],                // Array of project paths
    run: (ctx) => findProjectDirs(ctx.path)
  },
  {
    name: "analyze-each",
    wants: ["projects"],
    emits: ["project-contexts"],        // Array of accumulated contexts
    run: (ctx) => 
      Effect.forEach(
        ctx.projects,
        (projectPath) => runAccumulate(projectStages, { path: projectPath }),
        { concurrency: 4 }
      )
  }
]

// Run on ~/src, spawns sub-analysis for each project found
const results = await runAccumulate(topLevel, { path: "~/src" })
// Result: { projects: [...], project-contexts: [ctx1, ctx2, ctx3, ...] }
```

---

## Lattice Scheduler

The scheduler tracks available facts and runs stages when ready.

```typescript
interface Scheduler {
  /** Facts currently available */
  available: Set<string>
  
  /** Stages waiting for dependencies */
  pending: Stage[]
  
  /** Stages currently running */
  running: Set<Stage>
  
  /** Check which stages can run now */
  ready(): Stage[]
  
  /** Mark facts as available, trigger ready stages */
  provide(facts: string[]): void
}
```

### Scheduling Algorithm

```typescript
const runLattice = (stages: Stage[], initial: Context) =>
  Effect.gen(function* () {
    const ctx = yield* SynchronizedRef.make(initial)
    const available = yield* Ref.make(new Set(Object.keys(initial)))
    const completed = yield* Ref.make(new Set<string>())
    const allDone = yield* Deferred.make<Context>()
    
    const checkReady = Effect.gen(function* () {
      const have = yield* Ref.get(available)
      const done = yield* Ref.get(completed)
      
      const ready = stages.filter((stage) =>
        !done.has(stage.name) &&
        stage.wants.every((want) => have.has(want))
      )
      
      // Run all ready stages in parallel
      yield* Effect.forEach(
        ready,
        (stage) => runStage(stage, ctx, available, completed),
        { concurrency: "unbounded" }
      )
      
      // Check if all stages complete
      const nowDone = yield* Ref.get(completed)
      if (nowDone.size === stages.length) {
        const finalCtx = yield* SynchronizedRef.get(ctx)
        yield* Deferred.succeed(allDone, finalCtx)
      }
    })
    
    const runStage = (stage, ctx, available, completed) =>
      Effect.gen(function* () {
        const currentCtx = yield* SynchronizedRef.get(ctx)
        const facts = yield* stage.run(currentCtx)
        
        // Add new facts to context
        yield* SynchronizedRef.update(ctx, (c) => ({ ...c, ...facts }))
        
        // Mark stage complete and facts available
        yield* Ref.update(completed, (s) => s.add(stage.name))
        yield* Ref.update(available, (s) => {
          stage.emits.forEach((e) => s.add(e))
          return s
        })
        
        // Trigger next ready stages
        yield* checkReady
      })
    
    // Start with initially ready stages
    yield* checkReady
    
    // Wait for completion
    return yield* Deferred.await(allDone)
  })
```

---

## Merging with termichatter Flow

### Unified Stage Definition

```typescript
interface Stage<In = unknown, Out = unknown, E = never, R = never> {
  readonly name: string
  
  /** Facts/fields required (lattice dependency) */
  readonly wants: ReadonlyArray<string>
  
  /** Facts/fields produced */
  readonly emits: ReadonlyArray<string>
  
  /** Execution mode */
  readonly mode: "sync" | "async" | "stream"
  
  /** The compute function */
  readonly run: (input: In, ctx: Context) => Effect<Out, E, R>
}
```

### Flow Mode: Elements Pass Through

In flow mode, `wants` and `emits` describe **per-element** transformation:

```typescript
const flowStages: Stage[] = [
  {
    name: "timestamper",
    wants: [],                    // No dependencies
    emits: ["time"],              // Adds time field
    mode: "sync",
    run: (msg) => Effect.succeed({ ...msg, time: Date.now() })
  },
  {
    name: "enricher",
    wants: ["time"],              // Needs timestamp first
    emits: ["source", "id"],
    mode: "sync",
    run: (msg) => Effect.succeed({ ...msg, source: "app", id: uuid() })
  },
  {
    name: "validator",
    wants: ["source"],            // Needs source
    emits: ["validated"],
    mode: "async",
    run: (msg) => validateAsync(msg).pipe(Effect.map((v) => ({ ...msg, validated: v })))
  }
]

// Each message flows through, stages run when element has required fields
stream.pipe(
  Stream.mapEffect((msg) => runLattice(flowStages, msg))
)
```

### Accumulate Mode: Context Builds Up

In accumulate mode, `wants` and `emits` describe **context-level** dependencies:

```typescript
const accumulateStages: Stage[] = [
  // ... (project analysis stages from above)
]

// Single context accumulates all facts
const projectInfo = await runLattice(accumulateStages, { path: projectPath })
```

---

## Recursive Spawn Pattern

### Parent-Child Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Top-Level Exec                               │
│  Line: [find-projects, spawn-analyzers, collect-results]        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   { path: "~/src" }                                             │
│         │                                                        │
│         ▼                                                        │
│   ┌─────────────────┐                                           │
│   │  find-projects  │                                           │
│   │  emits: projects│──────┐                                    │
│   └─────────────────┘      │                                    │
│                            │                                     │
│                            ▼                                     │
│   ┌─────────────────────────────────────────────┐               │
│   │             spawn-analyzers                  │               │
│   │  wants: [projects]                          │               │
│   │  emits: [project-contexts]                  │               │
│   │                                              │               │
│   │  ┌────────────┐ ┌────────────┐ ┌──────────┐ │               │
│   │  │ Child Exec │ │ Child Exec │ │ Child    │ │               │
│   │  │ project-a  │ │ project-b  │ │ Exec ... │ │               │
│   │  │ (lattice)  │ │ (lattice)  │ │          │ │               │
│   │  └─────┬──────┘ └─────┬──────┘ └────┬─────┘ │               │
│   │        │              │             │       │               │
│   │        ▼              ▼             ▼       │               │
│   │    ctx-a          ctx-b         ctx-c       │               │
│   └─────────────────────────────────────────────┘               │
│                            │                                     │
│                            ▼                                     │
│   ┌─────────────────┐                                           │
│   │ collect-results │                                           │
│   │ wants: [project-│                                           │
│   │   contexts]     │                                           │
│   └─────────────────┘                                           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Spawn Stage Implementation

```typescript
const spawnAnalyzers: Stage = {
  name: "spawn-analyzers",
  wants: ["projects"],
  emits: ["project-contexts"],
  mode: "async",
  run: (_, ctx) =>
    Effect.forEach(
      ctx.projects,
      (projectPath) =>
        // Each project gets its own lattice execution
        runLattice(projectAnalysisStages, { path: projectPath }),
      { concurrency: 8 }  // Analyze 8 projects in parallel
    ).pipe(
      Effect.map((contexts) => ({ "project-contexts": contexts }))
    )
}
```

---

## Effect Integration

### Key Effect Features Used

| Concept | Effect Feature | Application |
|---------|---------------|-------------|
| Lattice scheduling | `Ref` + `Deferred` | Track available facts, signal completion |
| Parallel stages | `Effect.forEach` + concurrency | Run independent stages together |
| Context accumulation | `SynchronizedRef` | Thread-safe fact addition |
| Resource-safe stages | `Effect.acquireRelease` | File handles, subprocesses |
| Fact caching | `Effect.cachedFunction` | Memoize expensive lookups |
| Recursive spawn | `Effect.forEach` | Child exec per discovered item |
| Completion signal | `Deferred` | Know when all facts collected |
| Stage gating | `Latch` | Pause stages during shutdown |
| Error handling | `Effect.catchTag` | Per-stage error recovery |
| Observability | `Effect.withSpan` | Trace stage execution |

### Scheduler with Effect

```typescript
const LatticeScheduler = Effect.gen(function* () {
  const available = yield* Ref.make<Set<string>>(new Set())
  const running = yield* Ref.make<Set<string>>(new Set())
  const completed = yield* Ref.make<Set<string>>(new Set())
  const ctx = yield* SynchronizedRef.make<Context>({})
  const done = yield* Deferred.make<Context>()
  
  return {
    provide: (facts: Record<string, unknown>) =>
      SynchronizedRef.update(ctx, (c) => ({ ...c, ...facts })).pipe(
        Effect.tap(() => 
          Ref.update(available, (s) => {
            Object.keys(facts).forEach((k) => s.add(k))
            return s
          })
        )
      ),
    
    ready: (stages: Stage[]) =>
      Effect.gen(function* () {
        const have = yield* Ref.get(available)
        const inProgress = yield* Ref.get(running)
        const finished = yield* Ref.get(completed)
        
        return stages.filter((s) =>
          !finished.has(s.name) &&
          !inProgress.has(s.name) &&
          s.wants.every((w) => have.has(w))
        )
      }),
    
    markRunning: (stage: Stage) =>
      Ref.update(running, (s) => s.add(stage.name)),
    
    markComplete: (stage: Stage, facts: Record<string, unknown>) =>
      Effect.all([
        Ref.update(running, (s) => { s.delete(stage.name); return s }),
        Ref.update(completed, (s) => s.add(stage.name)),
        SynchronizedRef.update(ctx, (c) => ({ ...c, ...facts })),
        Ref.update(available, (s) => {
          stage.emits.forEach((e) => s.add(e))
          return s
        }),
      ]),
    
    isDone: (stages: Stage[]) =>
      Ref.get(completed).pipe(
        Effect.map((c) => c.size === stages.length)
      ),
    
    getContext: () => SynchronizedRef.get(ctx),
    
    awaitDone: () => Deferred.await(done),
    signalDone: () => SynchronizedRef.get(ctx).pipe(Effect.flatMap((c) => Deferred.succeed(done, c))),
  }
})
```

---

## Summary

| Aspect | termichatter | walk | Merged |
|--------|-------------|------|--------|
| Elements | Many flow through | One accumulates | Both modes supported |
| Stage order | Linear pipeline | Dependency lattice | Lattice with `wants`/`emits` |
| Dependencies | Implicit (position) | Explicit (`wants`) | Explicit (`wants`/`emits`) |
| Parallelism | Per async stage | Per independent fact | Automatic from graph |
| Spawning | N/A | N/A | Stage can spawn child exec |
| Output | Stream of results | Single context | Configurable per line |

### When to Use Each Mode

**Flow mode** (termichatter):
- Logs, events, messages
- Independent items
- Transform and emit

**Accumulate mode** (walk):
- Project analysis
- Single entity with many facts
- Build up context

**Recursive spawn**:
- Directory of projects
- Multi-repo analysis
- Hierarchical fact gathering
