# lattice-pipe-resolver: Dynamic Pipeline with Satisfiability Resolution

> TypeScript Effect implementation where a resolver pipe dynamically splices dependency-satisfying pipes into the running pipeline

## Core Concept

A `lattice-resolver` pipe inspects what facts are **wanted** downstream, queries a registry for pipes that **emit** those facts, computes a satisfiable execution order, and **splices** those pipes directly into the current run.

```
Before lattice-resolver runs:
  [timestamper] → [lattice-resolver] → [output]
                        │
                        │ (resolver inspects: output wants ["validated", "enriched"])
                        │ (resolver finds: validator emits ["validated"], enricher emits ["enriched"])
                        │ (resolver computes order, splices)
                        ▼
After lattice-resolver runs:
  [timestamper] → [enricher] → [validator] → [output]
```

The pipeline **rewrites itself** at runtime based on dependency analysis.

---

## Type Definitions

### Pipe with Dependency Metadata

```typescript
import { Effect, Option, Ref, Data } from "effect"

/**
 * A pipe declares what it needs and what it produces.
 */
interface Pipe<In = unknown, Out = unknown, E = never, R = never> {
  readonly name: string
  
  /** Facts this pipe requires to run */
  readonly wants: ReadonlyArray<string>
  
  /** Facts this pipe produces */
  readonly emits: ReadonlyArray<string>
  
  /** The computation */
  readonly run: (input: In, ctx: RunContext) => Effect.Effect<Out, E, R>
}

/**
 * Context available during a run.
 */
interface RunContext {
  /** Current accumulated facts */
  readonly facts: ReadonlySet<string>
  
  /** Splice pipes after current position */
  readonly splice: (pipes: Pipe[]) => Effect.Effect<void>
  
  /** Current position in pipeline */
  readonly pos: number
  
  /** Access to pipe registry */
  readonly registry: Registry
}
```

### Registry

```typescript
/**
 * Registry of available pipes, indexed by what they emit.
 */
interface Registry {
  /** All registered pipes */
  readonly pipes: ReadonlyMap<string, Pipe>
  
  /** Index: fact name → pipes that emit it */
  readonly emitsIndex: ReadonlyMap<string, ReadonlyArray<Pipe>>
  
  /** Find pipes that can provide given facts */
  readonly findProviders: (facts: ReadonlyArray<string>) => ReadonlyArray<Pipe>
  
  /** Register a pipe */
  readonly register: (pipe: Pipe) => Effect.Effect<void>
}
```

### Run (Cursor)

```typescript
/**
 * A Run walks through the pipeline, executing pipes.
 * Pipes can splice new pipes into the run dynamically.
 */
interface Run<In, Out> {
  /** The pipeline (mutable during execution) */
  pipe: Pipe[]
  
  /** Current position */
  pos: number
  
  /** Accumulated facts so far */
  facts: Set<string>
  
  /** The input being processed */
  input: In
  
  /** Execute from current position */
  execute: () => Effect.Effect<Out>
  
  /** Splice pipes after current position */
  splice: (pipes: Pipe[]) => void
}
```

---

## The lattice-resolver Pipe

### Algorithm Overview

1. **Collect wants**: Scan downstream pipes for all `wants`
2. **Subtract available**: Remove facts already in `ctx.facts`
3. **Find providers**: Query registry for pipes that `emit` needed facts
4. **Compute order**: Topological sort based on inter-pipe dependencies
5. **Splice**: Insert sorted pipes after resolver's position

### Implementation

```typescript
const latticeResolver: Pipe = {
  name: "lattice-resolver",
  wants: [],  // No dependencies - can run anytime
  emits: [],  // Produces no facts itself (but splices pipes that do)
  
  run: (input, ctx) =>
    Effect.gen(function* () {
      // 1. Collect all wants from downstream pipes
      const downstream = getDownstreamPipes(ctx)
      const allWants = collectWants(downstream)
      
      // 2. Subtract facts already available
      const unsatisfied = allWants.filter((want) => !ctx.facts.has(want))
      
      if (unsatisfied.length === 0) {
        // All dependencies satisfied, nothing to splice
        return input
      }
      
      // 3. Find pipes that can provide unsatisfied facts
      const candidates = ctx.registry.findProviders(unsatisfied)
      
      // 4. Compute satisfiable order (topological sort)
      const sorted = yield* computeSatisfiableOrder(candidates, ctx.facts)
      
      if (Option.isNone(sorted)) {
        return yield* Effect.fail(new UnsatisfiableError({ 
          wanted: unsatisfied,
          available: Array.from(ctx.facts)
        }))
      }
      
      // 5. Splice resolved pipes into run
      yield* ctx.splice(sorted.value)
      
      return input
    })
}
```

---

## Satisfiability Algorithm

### Problem Statement

Given:
- `available`: Set of facts currently available
- `wanted`: Set of facts needed
- `candidates`: Pipes that might provide wanted facts

Find: Ordered list of pipes such that each pipe's `wants` are satisfied by `available ∪ emits(prior pipes)`

### Algorithm: Incremental Kahn's Topological Sort

```typescript
/**
 * Compute a satisfiable execution order using Kahn's algorithm.
 * Returns None if no valid order exists (cyclic or missing dependencies).
 */
const computeSatisfiableOrder = (
  candidates: Pipe[],
  initialFacts: Set<string>
): Effect.Effect<Option.Option<Pipe[]>> =>
  Effect.sync(() => {
    // Track what facts will be available as we schedule
    const available = new Set(initialFacts)
    
    // Track which pipes are scheduled
    const scheduled: Pipe[] = []
    const remaining = new Set(candidates)
    
    // Keep iterating until no progress
    let progress = true
    while (progress && remaining.size > 0) {
      progress = false
      
      for (const pipe of remaining) {
        // Check if all wants are satisfied
        const satisfied = pipe.wants.every((want) => available.has(want))
        
        if (satisfied) {
          // Schedule this pipe
          scheduled.push(pipe)
          remaining.delete(pipe)
          
          // Add its emits to available facts
          pipe.emits.forEach((emit) => available.add(emit))
          
          progress = true
        }
      }
    }
    
    // Check if all candidates were scheduled
    if (remaining.size > 0) {
      // Some pipes couldn't be satisfied - check why
      const unsatisfiable = Array.from(remaining).map((pipe) => ({
        pipe: pipe.name,
        missing: pipe.wants.filter((w) => !available.has(w))
      }))
      
      console.warn("Unsatisfiable pipes:", unsatisfiable)
      return Option.none()
    }
    
    return Option.some(scheduled)
  })
```

### Complexity

- **Time**: O(P × F) where P = number of pipes, F = total facts
- **Space**: O(P + F) for tracking sets

### Handling Cycles

If the algorithm terminates with `remaining.size > 0`, there's either:
1. **Missing provider**: A wanted fact has no pipe that emits it
2. **Cycle**: Pipe A wants what B emits, B wants what A emits

```typescript
class UnsatisfiableError extends Data.TaggedError("UnsatisfiableError")<{
  readonly wanted: string[]
  readonly available: string[]
  readonly cycles?: Array<{ pipe: string; missing: string[] }>
}> {}
```

---

## ForkJoin Pipe

### Concept

`forkJoin` runs multiple pipes in **parallel**, waits for all to complete, and **merges** their outputs.

```
            ┌──► [pipeA] ──┐
            │              │
input ──────┼──► [pipeB] ──┼──► merged output
            │              │
            └──► [pipeC] ──┘
```

### Implementation

```typescript
/**
 * Create a forkJoin pipe that runs children in parallel.
 */
const forkJoin = <In, Out>(
  children: Pipe<In, Partial<Out>>[],
  merge: (results: Partial<Out>[]) => Out = Object.assign.bind(null, {})
): Pipe<In, Out> => ({
  name: `forkJoin(${children.map((c) => c.name).join(", ")})`,
  
  // Wants = union of all children's wants
  wants: Array.from(new Set(children.flatMap((c) => c.wants))),
  
  // Emits = union of all children's emits
  emits: Array.from(new Set(children.flatMap((c) => c.emits))),
  
  run: (input, ctx) =>
    Effect.forEach(
      children,
      (child) => child.run(input, ctx),
      { concurrency: "unbounded" }
    ).pipe(
      Effect.map((results) => merge(results as Partial<Out>[]))
    )
})

// Usage
const gitFacts = forkJoin([
  gitOriginPipe,    // emits: ["git-origin"]
  gitBranchPipe,    // emits: ["git-branch"]  
  gitWorktreePipe,  // emits: ["git-worktree"]
])
// Combined: wants: ["git-root"], emits: ["git-origin", "git-branch", "git-worktree"]
```

### ForkJoin with Dependency Ordering

When children have inter-dependencies, forkJoin uses the lattice algorithm internally:

```typescript
const forkJoinOrdered = <In, Out>(
  children: Pipe<In, Partial<Out>>[]
): Pipe<In, Out> => ({
  name: `forkJoinOrdered(${children.map((c) => c.name).join(", ")})`,
  wants: computeExternalWants(children),  // Wants not satisfied by siblings
  emits: Array.from(new Set(children.flatMap((c) => c.emits))),
  
  run: (input, ctx) =>
    Effect.gen(function* () {
      // Group children by dependency level
      const levels = yield* computeDependencyLevels(children, ctx.facts)
      
      // Execute level by level, parallel within each level
      let accumulated = input
      for (const level of levels) {
        const results = yield* Effect.forEach(
          level,
          (pipe) => pipe.run(accumulated, ctx),
          { concurrency: "unbounded" }
        )
        accumulated = Object.assign({}, accumulated, ...results)
      }
      
      return accumulated as Out
    })
})
```

**Dependency levels** group pipes that can run in parallel:

```
Level 0: [git-worktree]           wants: [path]
Level 1: [git-origin, git-branch] wants: [git-root] (provided by level 0)
Level 2: [last-commit]            wants: [git-root, git-branch] (provided by levels 0,1)
```

---

## Run Implementation

### Splice Mechanism

```typescript
const createRun = <In, Out>(
  pipeline: Pipe[],
  input: In,
  registry: Registry
): Run<In, Out> => {
  const run: Run<In, Out> = {
    pipe: [...pipeline],
    pos: 0,
    facts: new Set<string>(),
    input,
    
    splice: (pipes: Pipe[]) => {
      // Insert pipes after current position
      run.pipe.splice(run.pos + 1, 0, ...pipes)
    },
    
    execute: () =>
      Effect.gen(function* () {
        let current: unknown = run.input
        
        while (run.pos < run.pipe.length) {
          const pipe = run.pipe[run.pos]
          
          // Check wants are satisfied
          const missing = pipe.wants.filter((w) => !run.facts.has(w))
          if (missing.length > 0) {
            return yield* Effect.fail(new MissingFactsError({
              pipe: pipe.name,
              missing,
              available: Array.from(run.facts)
            }))
          }
          
          // Create context for this pipe
          const ctx: RunContext = {
            facts: run.facts,
            splice: (pipes) => Effect.sync(() => run.splice(pipes)),
            pos: run.pos,
            registry,
          }
          
          // Execute pipe
          current = yield* pipe.run(current, ctx)
          
          // Add emitted facts
          pipe.emits.forEach((e) => run.facts.add(e))
          
          // Advance position
          run.pos++
        }
        
        return current as Out
      }),
  }
  
  return run
}
```

### Example Execution Trace

```typescript
// Initial pipeline
const pipeline = [
  timestamper,      // wants: [], emits: ["time"]
  latticeResolver,  // wants: [], emits: [] (but splices!)
  output,           // wants: ["time", "validated", "enriched"], emits: []
]

// Registry has:
// - validator: wants: ["time"], emits: ["validated"]
// - enricher: wants: [], emits: ["enriched"]

// Execution:
// pos=0: timestamper runs, facts = {"time"}
// pos=1: latticeResolver runs
//        - scans downstream: output wants ["time", "validated", "enriched"]
//        - subtracts available: needs ["validated", "enriched"]
//        - finds providers: validator, enricher
//        - computes order: [enricher, validator] (enricher has no deps)
//        - splices after pos=1
//        - pipeline now: [timestamper, latticeResolver, enricher, validator, output]
// pos=2: enricher runs, facts = {"time", "enriched"}
// pos=3: validator runs, facts = {"time", "enriched", "validated"}
// pos=4: output runs, all wants satisfied ✓
```

---

## Advanced: Conditional Resolution

### Lazy Resolution

Only resolve what's actually needed based on runtime conditions:

```typescript
const conditionalResolver: Pipe = {
  name: "conditional-resolver",
  wants: [],
  emits: [],
  
  run: (input, ctx) =>
    Effect.gen(function* () {
      // Check runtime condition
      const needsValidation = input.requiresValidation ?? true
      
      // Build wants based on condition
      const conditionalWants = needsValidation 
        ? ["validated"] 
        : []
      
      const downstream = getDownstreamPipes(ctx)
      const baseWants = collectWants(downstream)
      const allWants = [...baseWants, ...conditionalWants]
      
      // ... proceed with resolution
    })
}
```

### Incremental Resolution

Multiple resolvers can run at different points:

```typescript
const pipeline = [
  earlyResolver,    // Resolve basic facts
  basicProcessing,
  lateResolver,     // Resolve additional facts based on intermediate results
  finalProcessing,
  output,
]
```

---

## Registry Implementation

```typescript
const createRegistry = (): Effect.Effect<Registry, never, Scope> =>
  Effect.gen(function* () {
    const pipes = yield* Ref.make<Map<string, Pipe>>(new Map())
    const emitsIndex = yield* Ref.make<Map<string, Pipe[]>>(new Map())
    
    return {
      get pipes() {
        return Effect.runSync(Ref.get(pipes))
      },
      
      get emitsIndex() {
        return Effect.runSync(Ref.get(emitsIndex))
      },
      
      findProviders: (facts: string[]) =>
        Effect.runSync(
          Ref.get(emitsIndex).pipe(
            Effect.map((index) => {
              const providers = new Set<Pipe>()
              for (const fact of facts) {
                const emitters = index.get(fact) ?? []
                emitters.forEach((p) => providers.add(p))
              }
              return Array.from(providers)
            })
          )
        ),
      
      register: (pipe: Pipe) =>
        Effect.gen(function* () {
          // Add to pipes map
          yield* Ref.update(pipes, (m) => m.set(pipe.name, pipe))
          
          // Update emits index
          yield* Ref.update(emitsIndex, (m) => {
            for (const emit of pipe.emits) {
              const existing = m.get(emit) ?? []
              m.set(emit, [...existing, pipe])
            }
            return m
          })
        }),
    }
  })
```

---

## Complete Example

```typescript
import { Effect, Ref, Option } from "effect"

// Define pipes
const timestamper: Pipe = {
  name: "timestamper",
  wants: [],
  emits: ["time"],
  run: (input) => Effect.succeed({ ...input, time: Date.now() })
}

const enricher: Pipe = {
  name: "enricher", 
  wants: [],
  emits: ["enriched", "source"],
  run: (input) => Effect.succeed({ ...input, enriched: true, source: "app" })
}

const validator: Pipe = {
  name: "validator",
  wants: ["time"],
  emits: ["validated"],
  run: (input) => Effect.succeed({ ...input, validated: true })
}

const formatter: Pipe = {
  name: "formatter",
  wants: ["validated", "enriched"],
  emits: ["formatted"],
  run: (input) => Effect.succeed({ ...input, formatted: JSON.stringify(input) })
}

const output: Pipe = {
  name: "output",
  wants: ["formatted"],
  emits: [],
  run: (input, ctx) => Effect.sync(() => { console.log(input); return input })
}

// Register all pipes
const setupRegistry = Effect.gen(function* () {
  const registry = yield* createRegistry()
  yield* registry.register(timestamper)
  yield* registry.register(enricher)
  yield* registry.register(validator)
  yield* registry.register(formatter)
  yield* registry.register(output)
  return registry
})

// Minimal pipeline with resolver
const program = Effect.gen(function* () {
  const registry = yield* setupRegistry
  
  // Pipeline only has timestamper, resolver, and output
  // Resolver will splice in enricher, validator, formatter
  const pipeline = [timestamper, latticeResolver, output]
  
  const run = createRun(pipeline, { message: "hello" }, registry)
  const result = yield* run.execute()
  
  console.log("Final result:", result)
  console.log("Pipeline after resolution:", run.pipe.map((p) => p.name))
})

Effect.runPromise(program)
// Output:
// { message: "hello", time: 1234567890, enriched: true, source: "app", validated: true, formatted: "..." }
// Final result: { ... }
// Pipeline after resolution: ["timestamper", "lattice-resolver", "enricher", "validator", "formatter", "output"]
```

---

## Summary

| Component | Purpose |
|-----------|---------|
| **Pipe** | Unit of computation with `wants`/`emits` |
| **Registry** | Index of pipes by what they emit |
| **Run** | Cursor walking pipeline, supports `splice` |
| **lattice-resolver** | Dynamically splices dependency-satisfying pipes |
| **Satisfiability** | Kahn's algorithm for topological ordering |
| **forkJoin** | Parallel execution with result merging |
| **forkJoinOrdered** | Parallel by dependency level |

### Key Innovation

The pipeline **rewrites itself** at runtime. A minimal "seed" pipeline with a resolver expands into a full execution plan based on what the output stage actually needs. This enables:

- **Lazy computation**: Only resolve what's needed
- **Dynamic pipelines**: Different inputs may resolve differently
- **Plugin architecture**: Register new pipes without changing pipeline definition
