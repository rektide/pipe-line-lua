# WALK-EFFECT: Fact-Gathering Walker with Effect

> Architectural approaches for recursive fact collection pipelines

## Problem Domain

From [rekon/doc/walk.md](/home/rektide/src/rekon/doc/walk.md):

- **Walk** directories/archives recursively
- **Facters** collect facts from candidates (files, dirents)
- **Candidates** accumulate facts as they're discovered
- **Wants/Provides** drive intelligent scheduling
- **Early termination** when facts satisfied

This differs from pipeflow:
- **Tree traversal** vs linear pipeline
- **Accumulation** vs transformation
- **Demand-driven** (wants) vs supply-driven (push)
- **Multi-facter** fan-out per candidate

## Architecture Options

---

### Option A: Stream + Accumulator

**Core idea**: Candidates flow through Stream, facters are `flatMap` stages that enrich.

```
Stream<Dirent>
  → flatMap(expandDir)           // Dirent → Stream<Candidate>
  → flatMap(runFacters)          // Candidate → Stream<EnrichedCandidate>
  → takeUntil(allFactsSatisfied)
  → runCollect
```

**Candidate as Ref**: Each candidate carries a `Ref<Facts>` that facters update.

```typescript
interface Candidate {
  path: string
  level: LogLevel
  ctx: Ref.Ref<Facts>  // Mutable accumulator
}

const runFacters = (candidate: Candidate) =>
  Stream.fromIterable(applicableFacters(candidate)).pipe(
    Stream.mapEffect((facter) => 
      facter.run(candidate).pipe(
        Effect.tap((fact) => Ref.update(candidate.ctx, Facts.add(fact)))
      )
    ),
    Stream.drain,
    Stream.as(candidate)
  )
```

**Pros**: Natural streaming, backpressure, simple mental model
**Cons**: Accumulator mutation feels awkward in Effect

---

### Option B: Recursive Effect with PubSub

**Core idea**: fexec is an Effect that recursively spawns work, facters subscribe to candidate PubSub.

```
                    ┌─────────────────┐
                    │     fexec       │
                    │  (coordinator)  │
                    └────────┬────────┘
                             │
              PubSub.publish(candidate)
                             │
         ┌───────────────────┼───────────────────┐
         ▼                   ▼                   ▼
   ┌──────────┐        ┌──────────┐        ┌──────────┐
   │ facter:  │        │ facter:  │        │ facter:  │
   │ dirent   │        │ git-*    │        │ npm-*    │
   └────┬─────┘        └────┬─────┘        └────┬─────┘
        │                   │                   │
        └───────────────────┴───────────────────┘
                             │
                   Queue.offer(fact)
                             │
                    ┌────────▼────────┐
                    │   accumulator   │
                    │  (SyncronizedRef)│
                    └─────────────────┘
```

**Facters as Fibers**: Each facter subscribes to candidates, filters by wants, emits facts.

```typescript
const facterFiber = (facter: Facter, candidates: PubSub<Candidate>, facts: Queue<Fact>) =>
  Stream.fromPubSub(candidates).pipe(
    Stream.filter((c) => facter.matches(c)),
    Stream.mapEffect((c) => facter.run(c)),
    Stream.flatMap(Stream.fromIterable),
    Stream.runForEach((fact) => Queue.offer(facts, fact))
  )
```

**Pros**: Parallel facter execution, dynamic facter registration
**Cons**: Complex coordination, harder to reason about completion

---

### Option C: Request-Based Demand Pull

**Core idea**: Facts are `Request`s. Facters are `RequestResolver`s. Demand drives execution.

```typescript
// Define fact requests
interface GitOriginRequest extends Request.Request<string, FacterError> {
  _tag: "GitOriginRequest"
  path: string
}

// Facter as resolver
const GitOriginResolver = RequestResolver.fromEffect((req: GitOriginRequest) =>
  runGitCommand(req.path, ["remote", "get-url", "origin"])
)

// Candidate requests facts it wants
const collectFacts = (candidate: Candidate, wanted: FactType[]) =>
  Effect.all(
    wanted.map((type) => {
      switch (type) {
        case "git-origin": return Effect.request(GitOriginRequest({ path: candidate.path }), GitOriginResolver)
        case "npm-package": return Effect.request(NpmPackageRequest({ path: candidate.path }), NpmResolver)
        // ...
      }
    }),
    { concurrency: "unbounded" }
  )
```

**Automatic batching**: Multiple candidates wanting same fact → batched resolver call.

**Pros**: Demand-driven (only compute what's needed), automatic deduplication, elegant
**Cons**: Less natural for "discover all facts", better for "get specific facts"

---

### Option D: Layer-per-Facter with Scope

**Core idea**: Each facter is a `Layer`. fexec composes them. Scope manages lifecycle.

```typescript
// Facter as service
class DirentFacter extends Context.Tag("DirentFacter")<
  DirentFacter,
  { walk: (path: string) => Stream.Stream<Candidate> }
>() {}

class GitFacter extends Context.Tag("GitFacter")<
  GitFacter,
  { facts: (candidate: Candidate) => Effect.Effect<GitFacts> }
>() {}

// Compose facters
const FacterLayer = Layer.mergeAll(
  DirentFacterLive,
  GitFacterLive,
  NpmFacterLive,
  CargoFacterLive,
)

// fexec uses all facters
const fexec = (starting: string[]) =>
  Effect.gen(function* () {
    const dirent = yield* DirentFacter
    const git = yield* GitFacter
    const npm = yield* NpmFacter
    
    yield* Stream.fromIterable(starting).pipe(
      Stream.flatMap(dirent.walk),
      Stream.mapEffect((c) => 
        Effect.all({ git: git.facts(c), npm: npm.facts(c) })
      ),
      Stream.runCollect
    )
  }).pipe(Effect.provide(FacterLayer))
```

**Pros**: Clean DI, testable (swap Layer), resource management
**Cons**: Static facter set, verbose

---

### Option E: Fiber Supervision Tree

**Core idea**: fexec is a supervisor. Each facter runs as supervised fiber. Candidates flow via Queue.

```
                    ┌─────────────────┐
                    │   Supervisor    │
                    │    (fexec)      │
                    └────────┬────────┘
                             │
         ┌───────────────────┼───────────────────┐
         │                   │                   │
    ┌────▼────┐         ┌────▼────┐         ┌────▼────┐
    │ Fiber:  │         │ Fiber:  │         │ Fiber:  │
    │ dirent  │         │  git    │         │  npm    │
    └────┬────┘         └────┬────┘         └────┬────┘
         │                   │                   │
         └───────► Queue<Candidate> ◄────────────┘
                         │
                   SynchronizedRef<Facts>
```

**Supervisor for monitoring**: Track facter health, restart on failure, observe completion.

```typescript
const fexec = Effect.gen(function* () {
  const supervisor = yield* Supervisor.track
  const candidates = yield* Queue.unbounded<Candidate>()
  const facts = yield* SynchronizedRef.make(Facts.empty)
  
  // Spawn facters under supervision
  yield* Effect.forkIn(direntFacter(candidates), supervisor)
  yield* Effect.forkIn(gitFacter(candidates, facts), supervisor)
  yield* Effect.forkIn(npmFacter(candidates, facts), supervisor)
  
  // Seed starting directories
  yield* Effect.forEach(starting, (dir) => Queue.offer(candidates, Candidate.from(dir)))
  
  // Wait for completion
  yield* Supervisor.value(supervisor).pipe(
    Effect.flatMap(Fiber.joinAll)
  )
  
  return yield* SynchronizedRef.get(facts)
})
```

**Pros**: Resilient, observable, dynamic fiber management
**Cons**: Complex completion semantics

---

## Comparison Matrix

| Aspect | A: Stream | B: PubSub | C: Request | D: Layer | E: Supervisor |
|--------|-----------|-----------|------------|----------|---------------|
| **Mental model** | Linear flow | Broadcast | Demand-pull | Services | Fiber tree |
| **Parallelism** | Per-stage | Per-facter | Automatic | Explicit | Per-fiber |
| **Completion** | Stream end | Manual | Automatic | Effect end | Supervisor |
| **Dynamic facters** | No | Yes | No | No | Yes |
| **Accumulation** | Ref per candidate | Shared Ref | Return values | Return values | SynchronizedRef |
| **Backpressure** | Built-in | Per-subscriber | N/A | N/A | Queue-based |
| **Testability** | Mock Stream | Mock PubSub | Mock Resolver | Swap Layer | Fork test fibers |

## Recommendation

### Primary: Option A (Stream) + Option C (Request) Hybrid

Use **Stream** for candidate traversal, **Request** for fact resolution:

```typescript
const walk = (starting: string[]) =>
  Stream.fromIterable(starting).pipe(
    // Expand directories (Stream)
    Stream.flatMap(expandDirectory),
    
    // For each candidate, request facts (Request)
    Stream.mapEffect((candidate) =>
      Effect.request(
        FactsRequest({ path: candidate.path, wanted: candidate.wants }),
        FacterResolver  // Batched resolver
      ).pipe(
        Effect.map((facts) => ({ ...candidate, facts }))
      )
    ),
    
    // Early termination when satisfied
    Stream.takeUntil(allFactsSatisfied),
  )
```

**Why this hybrid**:
- Stream handles traversal + backpressure naturally
- Request handles demand-driven fact resolution
- Request batching optimizes repeated lookups
- Clean separation: traversal vs resolution

### Secondary: Option E (Supervisor) for Production

Add Supervisor layer for:
- Facter health monitoring
- Restart failed facters
- Metrics on facter throughput
- Graceful shutdown

---

## Key Differences from pipeflow

| pipeflow | walk-effect |
|----------|-------------|
| Linear stages | Tree traversal |
| Transform elements | Accumulate facts |
| Push-driven | Demand-driven (wants) |
| Single path | Fan-out to facters |
| Pipeline = Stream | Traversal = Stream, Resolution = Request |
| Stage = Pipe | Facter = RequestResolver |

---

## Additional Effect Concepts for Walk

### Deferred: Completion Signaling

`Deferred<A, E>` is a one-time variable—perfect for signaling when fact collection is complete.

**Walk application**:
- Signal when all facts for a candidate are collected
- Coordinate "all facters done" completion
- Pass results between facter fibers

```typescript
// Candidate completion signal
interface Candidate {
  path: string
  facts: SynchronizedRef<Facts>
  complete: Deferred<Facts, never>  // Resolves when all facts collected
}

// Facter signals completion
const facter = (candidate: Candidate) =>
  collectFact(candidate).pipe(
    Effect.tap((fact) => SynchronizedRef.update(candidate.facts, Facts.add(fact))),
    Effect.tap(() => checkAllFactsCollected(candidate)),
  )

// Wait for candidate completion
yield* Deferred.await(candidate.complete)
```

**When useful**: Coordinating multiple facters working on same candidate.

---

### Caching: Memoize Fact Lookups

`Effect.cachedFunction` memoizes results—avoid re-computing same fact.

**Walk application**:
- Cache git-origin for all files in same repo
- Cache package.json parse for all files in npm project
- Invalidate cache when walking new repo

```typescript
// Memoized git lookup
const cachedGitOrigin = yield* Effect.cachedFunction(
  (repoRoot: string) => runGitCommand(repoRoot, ["remote", "get-url", "origin"])
)

// All candidates in same repo hit cache
const gitFacter = (candidate: Candidate) =>
  findGitRoot(candidate.path).pipe(
    Effect.flatMap(cachedGitOrigin),  // Cached!
    Effect.map((origin) => ({ "git-origin": origin }))
  )
```

**Also**: `Effect.cachedWithTTL` for time-bounded caches, `Effect.cachedInvalidateWithTTL` for manual invalidation.

---

### Stream.acquireRelease: Resource-Safe Facters

Facters that open files, spawn processes, or hold connections need cleanup.

**Walk application**:
- File handle management for content facters
- Git subprocess lifecycle
- HTML parser state

```typescript
// File-reading facter with safe cleanup
const fileFacter = (path: string) =>
  Stream.acquireRelease(
    openFile(path),           // Acquire
    (handle) => handle.close  // Release
  ).pipe(
    Stream.flatMap((handle) => handle.readLines()),
    Stream.map(parseFacts)
  )

// Git subprocess
const gitFacter = (repoRoot: string) =>
  Stream.acquireRelease(
    spawnGitProcess(repoRoot),
    (proc) => Effect.sync(() => proc.kill())
  ).pipe(
    Stream.flatMap((proc) => Stream.fromReadableStream(proc.stdout)),
    Stream.map(parseGitOutput)
  )
```

---

### Latch: Gate Facter Execution

`Latch` blocks fibers until opened—ideal for staged execution.

**Walk application**:
- Wait for directory scan to complete before running facters
- Gate expensive facters until cheap ones finish
- Pause all facters during shutdown

```typescript
const walk = Effect.gen(function* () {
  const scanComplete = yield* Effect.makeLatch(false)  // Starts closed
  
  // Facters wait for scan to complete
  const gitFacter = scanComplete.whenOpen.pipe(
    Effect.andThen(runGitFacter)
  )
  
  // Directory scan
  yield* scanDirectories(starting)
  yield* scanComplete.open  // Release all waiting facters
  
  // Facters now proceed
  yield* Fiber.joinAll(facterFibers)
})
```

**Shutdown pattern**:
```typescript
const shutdownLatch = yield* Effect.makeLatch(true)  // Starts open

// Facters check before each iteration
const facterLoop = Effect.forever(
  shutdownLatch.whenOpen.pipe(
    Effect.andThen(processNextCandidate)
  )
)

// Graceful shutdown
yield* shutdownLatch.close  // Facters block on next iteration
```

---

## Revised Architecture with New Concepts

```
┌─────────────────────────────────────────────────────────────┐
│                        fexec                                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────┐                                            │
│  │ Directory   │ ──Stream<Dirent>──┐                        │
│  │ Walker      │                   │                        │
│  │ (acquireRel)│                   ▼                        │
│  └─────────────┘            ┌─────────────┐                 │
│                             │  Candidate  │                 │
│  scanComplete.open ────────►│   Stream    │                 │
│  (Latch)                    └──────┬──────┘                 │
│                                    │                        │
│         ┌──────────────────────────┼──────────────────────┐ │
│         │                          │                      │ │
│         ▼                          ▼                      ▼ │
│  ┌─────────────┐           ┌─────────────┐        ┌─────────┐
│  │ git-facter  │           │ npm-facter  │        │ dirent  │
│  │ (cached)    │           │ (cached)    │        │ facter  │
│  └──────┬──────┘           └──────┬──────┘        └────┬────┘
│         │                         │                    │    │
│         └─────────────────────────┴────────────────────┘    │
│                                   │                         │
│                                   ▼                         │
│                       ┌───────────────────┐                 │
│                       │ SynchronizedRef   │                 │
│                       │ <Facts>           │                 │
│                       └─────────┬─────────┘                 │
│                                 │                           │
│                    Deferred.succeed(facts)                  │
│                                 │                           │
│                                 ▼                           │
│                         ┌─────────────┐                     │
│                         │   Output    │                     │
│                         └─────────────┘                     │
└─────────────────────────────────────────────────────────────┘
```

**Key patterns**:
- `Stream.acquireRelease` for file/process resources
- `Effect.cachedFunction` for repo-level fact memoization  
- `Latch` for staged execution (scan → facter)
- `Deferred` for per-candidate completion signaling
- `SynchronizedRef` for concurrent fact accumulation

## Next Steps

1. Prototype Stream-based directory walker
2. Model facters as RequestResolvers
3. Design candidate/fact Schema
4. Add Supervisor for production resilience
5. Benchmark vs async generator approach
6. Prototype caching layer for repo-scoped facts
7. Implement Latch-based staged execution
