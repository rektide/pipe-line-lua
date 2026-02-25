# effectflow: Effect-Based Design Document

> Type-safe pipeline using Effect for structured concurrency, error handling, and dependency injection

## Overview

effectflow reimagines the pipeflow architecture using [Effect](https://effect.website), a powerful TypeScript library for building type-safe, concurrent applications. Instead of manual async/queue handling, effectflow leverages Effect's primitives: `Effect<A, E, R>` for computations, `Queue<A>` for backpressure-aware async handoff, `Stream<A, E, R>` for multi-element emission, and `Layer` for dependency injection.

## Design Philosophy

| Aspect | pipeflow/typeflow | effectflow |
|--------|-------------------|------------|
| Async | Manual Promise/queue | `Effect<A, E, R>` with fibers |
| Error | Try/catch, `undefined` | Typed error channel `E` |
| Dependencies | Manual context passing | `Context.Tag` + `Layer` |
| Backpressure | Manual MPSC | `Queue.bounded` |
| Multi-emit | `line.emit()` calls | `Stream<A, E, R>` |
| Resource | Manual cleanup | `Scope` + `Effect.acquireRelease` |
| Concurrency | Manual fiber spawn | `Effect.fork`, `Fiber`, `Semaphore` |

## Core Concepts

### Effect Primer

```typescript
import { Effect, pipe } from "effect"

// Effect<A, E, R> represents:
// - A: Success value type
// - E: Error type (typed failures)
// - R: Required dependencies (context)

// Simple effect
const greet: Effect.Effect<string> = Effect.succeed("Hello")

// Effect with error
const parse = (s: string): Effect.Effect<number, Error> =>
  isNaN(Number(s))
    ? Effect.fail(new Error(`Invalid: ${s}`))
    : Effect.succeed(Number(s))

// Effect with dependency
class Logger extends Context.Tag("Logger")<
  Logger,
  { log: (msg: string) => Effect.Effect<void> }
>() {}

const program: Effect.Effect<void, never, Logger> = Effect.gen(function* () {
  const logger = yield* Logger
  yield* logger.log("Hello from Effect")
})
```

### Pipeline as Effect Composition

In effectflow, a pipeline is a composition of Effect-returning functions using `pipe` and `Effect.andThen`:

```typescript
import { Effect, pipe } from "effect"

// A pipe is a function: (input) => Effect<output, error, deps>
type Pipe<In, Out, E = never, R = never> = (
  input: In
) => Effect.Effect<Out, E, R>

// Pipeline composition
const pipeline = (input: RawEvent) =>
  pipe(
    input,
    timestamper,           // RawEvent → Effect<TimestampedEvent>
    Effect.andThen(enrich),   // → Effect<EnrichedEvent>
    Effect.andThen(validate), // → Effect<ValidatedEvent, ValidationError>
    Effect.andThen(format),   // → Effect<FormattedEvent>
  )
```

## Type Definition

### Element

```typescript
import { Data } from "effect"

// Immutable element with structural equality
class Element extends Data.Class<{
  readonly id?: string
  readonly time?: bigint
  readonly source?: string
  readonly type?: string
  readonly [key: string]: unknown
}> {}

// CloudEvents-compatible element
class CloudElement extends Data.Class<{
  readonly id: string
  readonly source: string
  readonly type: string
  readonly specversion: "1.0"
  readonly time: bigint
  readonly data?: unknown
}> {}

// Log element with priority
const Priority = {
  error: 1,
  warn: 2,
  info: 3,
  log: 4,
  debug: 5,
  trace: 6,
} as const

type Priority = keyof typeof Priority

class LogElement extends Data.Class<{
  readonly message?: string
  readonly priority?: Priority
  readonly priorityLevel?: number
  readonly source?: string
  readonly time?: bigint
}> {}
```

### Pipe

```typescript
import { Effect, Option } from "effect"

/**
 * A Pipe transforms input to output via Effect.
 * - Returns Effect<Out> to continue
 * - Returns Effect<Option.none()> to filter/drop
 * - Fails with E to propagate error
 */
type Pipe<In, Out, E = never, R = never> = (
  input: In
) => Effect.Effect<Option.Option<Out>, E, R>

/**
 * Simplified pipe that always produces output (no filtering).
 */
type TransformPipe<In, Out, E = never, R = never> = (
  input: In
) => Effect.Effect<Out, E, R>

/**
 * Filter pipe that may drop element.
 */
type FilterPipe<T, E = never, R = never> = (
  input: T
) => Effect.Effect<boolean, E, R>
```

### Line (Pipeline Service)

```typescript
import { Context, Effect, Layer, Queue, Stream } from "effect"

/**
 * Line configuration.
 */
interface LineConfig<In = unknown, Out = unknown> {
  readonly source?: string
  readonly filter?: string | ((source: string) => boolean)
  readonly pipe: ReadonlyArray<Pipe<unknown, unknown, unknown, unknown>>
  readonly queueCapacity?: number
}

/**
 * Line service interface.
 */
interface Line<In, Out, E = never> {
  /** Send element through pipeline */
  readonly send: (input: In) => Effect.Effect<void, E>

  /** Output queue for processed element */
  readonly output: Queue.Dequeue<Out>

  /** Source identifier */
  readonly source: string

  /** Create child line with additional pipe */
  readonly derive: <NewOut, NewE>(
    config: Partial<LineConfig<Out, NewOut>>
  ) => Effect.Effect<Line<In, NewOut, E | NewE>, never, Scope>

  /** Create logger for this line */
  readonly logger: (config?: {
    module?: string
  }) => Logger
}

/**
 * Line service tag for dependency injection.
 */
class LineService extends Context.Tag("effectflow/Line")<
  LineService,
  Line<unknown, unknown>
>() {}
```

### Registry

```typescript
import { Context, Effect, HashMap, Layer, Ref } from "effect"

/**
 * Registry service for named pipe.
 */
interface Registry {
  /** Register a pipe by name */
  readonly register: <In, Out, E, R>(
    name: string,
    pipe: Pipe<In, Out, E, R>
  ) => Effect.Effect<void>

  /** Resolve pipe by name */
  readonly resolve: <In, Out, E, R>(
    name: string
  ) => Effect.Effect<Option.Option<Pipe<In, Out, E, R>>>

  /** Derive child registry */
  readonly derive: () => Effect.Effect<Registry>
}

class RegistryService extends Context.Tag("effectflow/Registry")<
  RegistryService,
  Registry
>() {}

/**
 * Live registry implementation.
 */
const RegistryLive = Layer.effect(
  RegistryService,
  Effect.gen(function* () {
    const store = yield* Ref.make(HashMap.empty<string, Pipe<unknown, unknown, unknown, unknown>>())

    return {
      register: (name, pipe) =>
        Ref.update(store, HashMap.set(name, pipe as Pipe<unknown, unknown, unknown, unknown>)),

      resolve: (name) =>
        Ref.get(store).pipe(
          Effect.map((map) => HashMap.get(map, name) as Option.Option<Pipe<unknown, unknown, unknown, unknown>>)
        ),

      derive: () =>
        Effect.gen(function* () {
          const parent = yield* Ref.get(store)
          const child = yield* Ref.make(parent)
          return {
            register: (name, pipe) =>
              Ref.update(child, HashMap.set(name, pipe as Pipe<unknown, unknown, unknown, unknown>)),
            resolve: (name) =>
              Ref.get(child).pipe(Effect.map((map) => HashMap.get(map, name))),
            derive: () => Effect.die("Nested derive not implemented"),
          } as Registry
        }),
    }
  })
)
```

## Implementation

### Line Implementation

```typescript
import { Effect, Layer, Queue, Scope, pipe, Option, Ref } from "effect"

/**
 * Create a Line layer with configuration.
 */
const makeLine = <In, Out>(
  config: LineConfig<In, Out>
): Effect.Effect<Line<In, Out>, never, Scope | RegistryService> =>
  Effect.gen(function* () {
    const registry = yield* RegistryService
    const outputQueue = yield* Queue.unbounded<Out>()
    const source = config.source ?? "effectflow"

    // Resolve all pipe from registry or use directly
    const resolvedPipe = yield* Effect.forEach(config.pipe, (p) => {
      if (typeof p === "string") {
        return registry.resolve(p).pipe(
          Effect.flatMap(Option.match({
            onNone: () => Effect.fail(new Error(`Pipe not found: ${p}`)),
            onSome: Effect.succeed,
          }))
        )
      }
      return Effect.succeed(p)
    })

    // Execute pipeline
    const execute = (input: In): Effect.Effect<void> =>
      Effect.gen(function* () {
        let current: unknown = input

        for (const pipeFn of resolvedPipe) {
          const result = yield* pipeFn(current)

          if (Option.isNone(result)) {
            // Element filtered out
            return
          }

          current = result.value
        }

        // Push to output
        yield* Queue.offer(outputQueue, current as Out)
      })

    const line: Line<In, Out> = {
      send: execute,
      output: outputQueue,
      source,

      derive: (childConfig) =>
        makeLine({
          ...config,
          ...childConfig,
          source: childConfig.source ?? source,
          pipe: [...config.pipe, ...(childConfig.pipe ?? [])],
        }),

      logger: (loggerConfig) => makeLogger(line, loggerConfig),
    }

    return line
  })

/**
 * Line layer factory.
 */
const LineLayer = <In, Out>(config: LineConfig<In, Out>) =>
  Layer.scoped(
    LineService,
    makeLine(config) as Effect.Effect<Line<unknown, unknown>, never, Scope | RegistryService>
  )
```

### Async Stage with Queue

```typescript
import { Effect, Queue, Fiber, Scope } from "effect"

/**
 * Create an async stage using bounded queue.
 */
const asyncStage = <In, Out, E, R>(
  pipe: Pipe<In, Out, E, R>,
  capacity = 16
): Effect.Effect<Pipe<In, Out, E, R>, never, Scope> =>
  Effect.gen(function* () {
    const queue = yield* Queue.bounded<In>(capacity)

    // Spawn consumer fiber
    const consumer = yield* Effect.fork(
      Effect.forever(
        Effect.gen(function* () {
          const input = yield* Queue.take(queue)
          yield* pipe(input)
        })
      )
    )

    // Ensure cleanup on scope close
    yield* Effect.addFinalizer(() =>
      Fiber.interrupt(consumer).pipe(Effect.andThen(Queue.shutdown(queue)))
    )

    // Return enqueuing pipe
    return (input: In) =>
      Queue.offer(queue, input).pipe(
        Effect.as(Option.some(undefined as unknown as Out))
      )
  })
```

### Stream-Based Multi-Emit

```typescript
import { Stream, Effect, Option } from "effect"

/**
 * Pipe that emits multiple element as Stream.
 */
type StreamPipe<In, Out, E = never, R = never> = (
  input: In
) => Stream.Stream<Out, E, R>

/**
 * Flatten stream pipe into regular pipeline.
 */
const flattenStreamPipe = <In, Out, E, R>(
  streamPipe: StreamPipe<In, Out, E, R>,
  outputQueue: Queue.Enqueue<Out>
): Pipe<In, void, E, R> =>
  (input) =>
    streamPipe(input).pipe(
      Stream.runForEach((item) => Queue.offer(outputQueue, item)),
      Effect.as(Option.some(undefined as void))
    )

// Example: split pipe
const splitter: StreamPipe<{ items: string[] }, string> = (input) =>
  Stream.fromIterable(input.items)
```

### Logger

```typescript
import { Effect, Option } from "effect"

interface Logger {
  (msg: string | Partial<LogElement>): Effect.Effect<void>
  error: (msg: string | Partial<LogElement>) => Effect.Effect<void>
  warn: (msg: string | Partial<LogElement>) => Effect.Effect<void>
  info: (msg: string | Partial<LogElement>) => Effect.Effect<void>
  log: (msg: string | Partial<LogElement>) => Effect.Effect<void>
  debug: (msg: string | Partial<LogElement>) => Effect.Effect<void>
  trace: (msg: string | Partial<LogElement>) => Effect.Effect<void>
}

const makeLogger = <In, Out>(
  line: Line<In, Out>,
  config?: { module?: string }
): Logger => {
  const source = config?.module
    ? `${line.source}:${config.module}`
    : line.source

  const send = (msg: string | Partial<LogElement>, priority?: Priority) => {
    const element: Partial<LogElement> =
      typeof msg === "string" ? { message: msg } : msg

    return line.send({
      ...element,
      source: element.source ?? source,
      priority: element.priority ?? priority,
      priorityLevel: element.priorityLevel ?? (priority ? Priority[priority] : undefined),
    } as In)
  }

  const logger = ((msg) => send(msg)) as Logger

  for (const priority of Object.keys(Priority) as Priority[]) {
    logger[priority] = (msg) => send(msg, priority)
  }

  return logger
}
```

## Built-in Pipe

### Timestamper

```typescript
import { Effect, Option } from "effect"

const timestamper: TransformPipe<Element, Element & { time: bigint }> = (input) =>
  Effect.sync(() => ({
    ...input,
    time: process.hrtime.bigint(),
  }))

// As filtering pipe (Option wrapper)
const timestamperPipe: Pipe<Element, Element & { time: bigint }> = (input) =>
  timestamper(input).pipe(Effect.map(Option.some))
```

### CloudEvent Enricher

```typescript
import { Effect, Option, Random } from "effect"

const cloudevent: Pipe<Element, CloudElement, never, LineService> = (input) =>
  Effect.gen(function* () {
    const line = yield* LineService
    const uuid = yield* Random.randomUUID

    return Option.some({
      ...input,
      id: input.id ?? uuid,
      source: input.source ?? line.source,
      type: input.type ?? "effectflow.event",
      specversion: "1.0" as const,
      time: input.time ?? process.hrtime.bigint(),
    })
  })
```

### Module Filter

```typescript
import { Effect, Option } from "effect"

const moduleFilter = (
  filter: string | ((source: string) => boolean)
): Pipe<Element, Element> => (input) =>
  Effect.sync(() => {
    const source = input.source
    if (!source) return Option.some(input)

    const passes =
      typeof filter === "string"
        ? source.includes(filter)
        : filter(source)

    return passes ? Option.some(input) : Option.none()
  })
```

### Priority Filter

```typescript
const priorityFilter = (minLevel: number): Pipe<LogElement, LogElement> => (input) =>
  Effect.sync(() => {
    const level = input.priorityLevel ?? 0
    return level >= minLevel ? Option.some(input) : Option.none()
  })
```

## Outputter as Effect Services

```typescript
import { Context, Effect, Layer, Queue, Stream, Scope } from "effect"

/**
 * Outputter service interface.
 */
interface Outputter<T> {
  readonly write: (element: T) => Effect.Effect<void>
}

/**
 * Console outputter.
 */
const ConsoleOutputter = <T extends Element>(): Outputter<T> => ({
  write: (element) =>
    Effect.sync(() => {
      console.log(JSON.stringify(element))
    }),
})

/**
 * File outputter (uses platform FileSystem).
 */
import { FileSystem } from "@effect/platform"

const FileOutputter = <T extends Element>(
  path: string
): Effect.Effect<Outputter<T>, never, FileSystem.FileSystem> =>
  Effect.gen(function* () {
    const fs = yield* FileSystem.FileSystem

    return {
      write: (element) =>
        fs.writeFileString(path, JSON.stringify(element) + "\n", { flag: "a" }),
    }
  })

/**
 * JSONL outputter.
 */
const JsonlOutputter = <T extends Element>(
  path: string
): Effect.Effect<Outputter<T>, never, FileSystem.FileSystem> =>
  FileOutputter<T>(path)

/**
 * Fanout outputter.
 */
const FanoutOutputter = <T>(...outputter: Outputter<T>[]): Outputter<T> => ({
  write: (element) =>
    Effect.all(outputter.map((o) => o.write(element)), { concurrency: "unbounded" }).pipe(
      Effect.asVoid
    ),
})
```

## Consumer with Fiber

```typescript
import { Effect, Fiber, Queue, Scope, Schedule } from "effect"

/**
 * Consume queue and write to outputter.
 */
const consumeOutput = <T>(
  queue: Queue.Dequeue<T>,
  outputter: Outputter<T>
): Effect.Effect<never, never, Scope> =>
  Effect.gen(function* () {
    const fiber = yield* Effect.fork(
      Effect.forever(
        Effect.gen(function* () {
          const element = yield* Queue.take(queue)
          yield* outputter.write(element)
        })
      )
    )

    yield* Effect.addFinalizer(() => Fiber.interrupt(fiber))

    return yield* Fiber.join(fiber)
  })

/**
 * Batch consumer with schedule.
 */
const batchConsume = <T>(
  queue: Queue.Dequeue<T>,
  outputter: Outputter<T>,
  batchSize: number,
  schedule: Schedule.Schedule<unknown, unknown>
): Effect.Effect<never, never, Scope> =>
  Effect.gen(function* () {
    const fiber = yield* Effect.fork(
      Effect.repeat(
        Effect.gen(function* () {
          const batch = yield* Queue.takeBetween(queue, 1, batchSize)
          yield* Effect.forEach(batch, (e) => outputter.write(e), {
            concurrency: "unbounded",
          })
        }),
        schedule
      )
    )

    yield* Effect.addFinalizer(() => Fiber.interrupt(fiber))

    return yield* Fiber.join(fiber)
  })
```

## Complete Example

```typescript
import { Effect, Layer, Queue, Scope, pipe, Option } from "effect"

// Define pipeline
const AppLine = LineLayer({
  source: "myapp:main",
  pipe: [
    timestamperPipe,
    cloudevent,
    moduleFilter("myapp"),
  ],
})

// Program using the line
const program = Effect.gen(function* () {
  const line = yield* LineService

  // Create logger
  const log = line.logger({ module: "startup" })

  // Log message
  yield* log.info("Application starting")
  yield* log.debug({ message: "Config loaded", data: { debug: true } })

  // Consume output
  const outputter = ConsoleOutputter()
  const element = yield* Queue.take(line.output)
  yield* outputter.write(element)
})

// Compose layers
const MainLayer = pipe(
  AppLine,
  Layer.provide(RegistryLive)
)

// Run
Effect.runPromise(
  program.pipe(
    Effect.provide(MainLayer),
    Effect.scoped
  )
)
```

## Advanced: Stream Pipeline

For pipelines that emit multiple element, use `Stream`:

```typescript
import { Stream, Effect, Queue } from "effect"

/**
 * Stream-based line for multi-emit pipe.
 */
const makeStreamLine = <In, Out>(
  transform: (input: In) => Stream.Stream<Out>
): Effect.Effect<
  {
    send: (input: In) => Effect.Effect<void>
    output: Queue.Dequeue<Out>
  },
  never,
  Scope
> =>
  Effect.gen(function* () {
    const inputQueue = yield* Queue.unbounded<In>()
    const outputQueue = yield* Queue.unbounded<Out>()

    // Consumer fiber
    yield* Effect.fork(
      Stream.fromQueue(inputQueue).pipe(
        Stream.flatMap(transform),
        Stream.runForEach((item) => Queue.offer(outputQueue, item))
      )
    )

    return {
      send: (input) => Queue.offer(inputQueue, input),
      output: outputQueue,
    }
  })

// Usage
const splitLine = makeStreamLine<{ items: string[] }, string>((input) =>
  Stream.fromIterable(input.items).pipe(
    Stream.map((item) => item.toUpperCase())
  )
)
```

## Error Handling

Effect provides typed error handling:

```typescript
import { Effect, Option, Either } from "effect"

// Pipe with typed error
class ValidationError extends Data.TaggedError("ValidationError")<{
  readonly field: string
  readonly message: string
}> {}

const validatePipe: Pipe<unknown, ValidatedElement, ValidationError> = (input) =>
  Effect.gen(function* () {
    if (!isValid(input)) {
      return yield* Effect.fail(
        new ValidationError({ field: "data", message: "Invalid input" })
      )
    }
    return Option.some(validated(input))
  })

// Error recovery
const withFallback = <In, Out, E, R>(
  pipe: Pipe<In, Out, E, R>,
  fallback: Out
): Pipe<In, Out, never, R> => (input) =>
  pipe(input).pipe(
    Effect.catchAll(() => Effect.succeed(Option.some(fallback)))
  )

// Error logging
const withErrorLog = <In, Out, E, R>(
  pipe: Pipe<In, Out, E, R>
): Pipe<In, Out, E, R> => (input) =>
  pipe(input).pipe(
    Effect.tapError((error) =>
      Effect.logError(`Pipe failed: ${error}`)
    )
  )
```

## Module Structure

```
effectflow/
├── src/
│   ├── index.ts           # Main export
│   ├── Line.ts            # Line service
│   ├── Registry.ts        # Registry service
│   ├── Logger.ts          # Logger factory
│   ├── Pipe/
│   │   ├── index.ts
│   │   ├── Timestamper.ts
│   │   ├── CloudEvent.ts
│   │   ├── ModuleFilter.ts
│   │   └── PriorityFilter.ts
│   ├── Outputter/
│   │   ├── index.ts
│   │   ├── Console.ts
│   │   ├── File.ts
│   │   ├── Jsonl.ts
│   │   └── Fanout.ts
│   ├── Element.ts         # Element type
│   └── Error.ts           # Error type
├── test/
│   ├── Line.test.ts
│   ├── Registry.test.ts
│   └── Pipe.test.ts
├── package.json
├── tsconfig.json
└── README.md
```

## Package.json

```json
{
  "name": "effectflow",
  "version": "0.1.0",
  "description": "Effect-based pipeline for structured data flow",
  "type": "module",
  "main": "./dist/index.js",
  "types": "./dist/index.d.ts",
  "exports": {
    ".": {
      "import": "./dist/index.js",
      "types": "./dist/index.d.ts"
    },
    "./Pipe": {
      "import": "./dist/Pipe/index.js",
      "types": "./dist/Pipe/index.d.ts"
    },
    "./Outputter": {
      "import": "./dist/Outputter/index.js",
      "types": "./dist/Outputter/index.d.ts"
    }
  },
  "scripts": {
    "build": "tsdown src/index.ts --dts",
    "check": "tsgo --noEmit",
    "test": "vitest",
    "lint": "oxlint"
  },
  "dependencies": {
    "effect": "^3.0.0"
  },
  "devDependencies": {
    "@effect/platform": "^0.70.0",
    "@effect/platform-node": "^0.60.0",
    "@typescript/native-preview": "^7.0.0-dev",
    "oxlint": "latest",
    "tsdown": "latest",
    "vitest": "latest"
  },
  "peerDependencies": {
    "effect": ">=3.0.0"
  },
  "keywords": ["effect", "pipeline", "dataflow", "logging", "typescript"],
  "license": "MIT"
}
```

## Test Example

```typescript
import { describe, it, expect } from "vitest"
import { Effect, Layer, Queue, Scope, Option } from "effect"
import { makeLine, RegistryLive, timestamperPipe } from "effectflow"

describe("Line", () => {
  const TestLayer = Layer.provide(RegistryLive)

  it("should send element through pipeline", async () => {
    const program = Effect.gen(function* () {
      const line = yield* makeLine({
        source: "test",
        pipe: [timestamperPipe],
      })

      yield* line.send({ message: "test" })

      const output = yield* Queue.take(line.output)
      expect(output.message).toBe("test")
      expect(output.time).toBeDefined()
    })

    await Effect.runPromise(
      program.pipe(Effect.provide(TestLayer), Effect.scoped)
    )
  })

  it("should filter element returning None", async () => {
    const filterPipe: Pipe<{ keep: boolean }, { keep: boolean }> = (input) =>
      Effect.succeed(input.keep ? Option.some(input) : Option.none())

    const program = Effect.gen(function* () {
      const line = yield* makeLine({
        source: "test",
        pipe: [filterPipe],
      })

      yield* line.send({ keep: false })
      yield* line.send({ keep: true })

      const output = yield* Queue.take(line.output)
      expect(output.keep).toBe(true)
    })

    await Effect.runPromise(
      program.pipe(Effect.provide(TestLayer), Effect.scoped)
    )
  })
})
```

## Comparison: typeflow vs effectflow

| Feature | typeflow | effectflow |
|---------|----------|------------|
| Error typing | Manual `Error` type | `Effect<A, E, R>` typed errors |
| Dependencies | Manual passing | `Context.Tag` + `Layer` DI |
| Concurrency | Manual fibers | `Effect.fork`, `Fiber`, `Semaphore` |
| Backpressure | Manual MPSC | `Queue.bounded` with suspension |
| Resource cleanup | Manual close() | `Scope` + finalizer |
| Retries | Manual loop | `Schedule` + `Effect.retry` |
| Multi-emit | Callback `emit()` | `Stream<A, E, R>` |
| Testing | Manual mocking | `Layer.succeed` test double |
| Observability | Manual logging | `Effect.log`, `Tracer`, `Metrics` |

## When to Use effectflow

**Choose effectflow when:**
- You need typed error handling across the pipeline
- Complex concurrency with backpressure is required
- Dependency injection for testability is important
- You want automatic resource cleanup via Scope
- You need retry/schedule logic built-in
- You're already using Effect in your application

**Choose typeflow when:**
- Minimal dependencies preferred
- Simple async/await is sufficient
- Bundle size is critical (Effect is ~50KB)
- Team is not familiar with Effect patterns

## License

MIT
