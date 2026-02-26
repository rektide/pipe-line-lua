# typeflow: TypeScript Design Document

> Type-safe implicit-flow pipeline for structured data processing

## Overview

typeflow is a TypeScript implementation of the pipeflow architecture. It provides strongly-typed pipelines where elements flow implicitly through a line of pipe, with no explicit cursor object. The design leverages TypeScript's type system for compile-time safety while maintaining runtime flexibility.

## Design Goal

1. **Type Safety**: Full inference of input/output type through pipeline
2. **Zero Cursor Allocation**: No per-element object creation
3. **Composable**: Pipe combine and chain naturally
4. **Async-First**: Native Promise/async support with optional queue
5. **Tree-Shakeable**: Modular design for minimal bundle

## Core Type

### Element and Context

```typescript
/**
 * Base element flowing through pipeline.
 * Extended by specific event type.
 */
interface Element {
  readonly id?: string;
  readonly time?: bigint;
  readonly source?: string;
  readonly type?: string;
  [key: string]: unknown;
}

/**
 * CloudEvents-compatible structured element.
 */
interface CloudElement extends Element {
  readonly id: string;
  readonly source: string;
  readonly type: string;
  readonly specversion: "1.0";
  readonly time: bigint;
}

/**
 * Log element with priority level.
 */
interface LogElement extends Element {
  readonly message?: string;
  readonly priority?: Priority;
  readonly priorityLevel?: number;
}

type Priority = "error" | "warn" | "info" | "log" | "debug" | "trace";

const PriorityLevel: Record<Priority, number> = {
  error: 1,
  warn: 2,
  info: 3,
  log: 4,
  debug: 5,
  trace: 6,
};
```

### Pipe

```typescript
/**
 * A pipe transforms input to output.
 * Returns undefined/null to filter (stop processing).
 * Returns false to explicitly discard.
 */
type Pipe<In, Out, Ctx = Line> = (
  input: In,
  line: Ctx,
  pos: number
) => Out | undefined | null | false | Promise<Out | undefined | null | false>;

/**
 * Sync pipe (no Promise).
 */
type SyncPipe<In, Out, Ctx = Line> = (
  input: In,
  line: Ctx,
  pos: number
) => Out | undefined | null | false;

/**
 * Async pipe (returns Promise).
 */
type AsyncPipe<In, Out, Ctx = Line> = (
  input: In,
  line: Ctx,
  pos: number
) => Promise<Out | undefined | null | false>;

/**
 * Identity pipe (passthrough).
 */
type IdentityPipe<T, Ctx = Line> = Pipe<T, T, Ctx>;

/**
 * Pipe that may emit multiple element.
 */
type MultiEmitPipe<In, Out, Ctx = Line> = (
  input: In,
  line: Ctx & { emit: (out: Out) => void },
  pos: number
) => void | Promise<void>;
```

### Stage

```typescript
/**
 * Pipeline stage: pipe reference + optional queue config.
 */
interface Stage<In = unknown, Out = unknown> {
  /** Pipe name (registry lookup) or function */
  readonly pipe: string | Pipe<In, Out>;
  
  /** Async mode: "sync" | "queue" | "worker" */
  readonly mode?: StageMode;
  
  /** Queue instance (if mode is "queue") */
  readonly queue?: Queue<In>;
  
  /** Optional stage name for debugging */
  readonly name?: string;
}

type StageMode = "sync" | "queue" | "worker";

/**
 * Stage tuple for type inference.
 * [pipeName] or [pipeName, mode] or [pipeName, mode, queue]
 */
type StageTuple =
  | [string]
  | [string, StageMode]
  | [string, StageMode, Queue<unknown>];
```

### Line

```typescript
/**
 * Pipeline definition and execution context.
 */
interface Line<In = unknown, Out = unknown> {
  /** Pipeline stage */
  readonly pipe: readonly Stage[];
  
  /** Output destination */
  readonly output: Queue<Out>;
  
  /** Async queue (sparse, by position) */
  readonly queue: Map<number, Queue<unknown>>;
  
  /** Parent registry for pipe resolution */
  readonly registry: Registry;
  
  /** Revision counter (increment on mutation) */
  rev: number;
  
  /** Context field (inherited by child line) */
  readonly source?: string;
  readonly filter?: string | ((source: string) => boolean);
  readonly [key: string]: unknown;
  
  /** Send element through pipeline */
  send(input: In): void | Promise<void>;
  
  /** Emit to specific position */
  emit(input: unknown, pos: number): void | Promise<void>;
  
  /** Derive child line */
  derive<NewIn = In, NewOut = Out>(
    config: Partial<LineConfig<NewIn, NewOut>>
  ): Line<NewIn, NewOut>;
  
  /** Modify pipeline */
  splice(start: number, deleteCount: number, ...stage: Stage[]): Stage[];
  
  /** Add async queue at position */
  async(pos: number): Queue<unknown>;
  
  /** Resolve pipe by name */
  resolve<I, O>(name: string): Pipe<I, O> | undefined;
  
  /** Create logger */
  logger(config?: LoggerConfig): Logger;
  
  /** Prepare/start segment runtime hooks */
  prepare_segments(): void;
  
  /** Stop prepared segment runtime hooks */
  stop_segments(): void;
}

interface LineConfig<In = unknown, Out = unknown> {
  pipe?: Array<Stage | string | Pipe<unknown, unknown>>;
  source?: string;
  filter?: string | ((source: string) => boolean);
  registry?: Registry;
  output?: Queue<Out>;
  [key: string]: unknown;
}
```

### Registry

```typescript
/**
 * Repository of named pipe.
 */
interface Registry {
  /** Registered pipe */
  readonly pipe: Map<string, Pipe<unknown, unknown>>;
  
  /** Parent registry (for inheritance) */
  readonly parent?: Registry;
  
  /** Register a pipe */
  register<In, Out>(name: string, pipe: Pipe<In, Out>): void;
  
  /** Resolve pipe by name */
  resolve<In, Out>(name: string): Pipe<In, Out> | undefined;
  
  /** Derive child registry */
  derive(): Registry;
}
```

### Queue

```typescript
/**
 * Async queue interface (MPSC pattern).
 */
interface Queue<T> {
  push(value: T): void;
  pop(): Promise<T>;
  tryPop(): T | undefined;
  isEmpty(): boolean;
  close(): void;
}

/**
 * Queue factory.
 */
interface QueueFactory {
  create<T>(): Queue<T>;
}
```

### Logger

```typescript
/**
 * Logger with priority method.
 */
interface Logger {
  (msg: string | LogElement): void;
  
  error(msg: string | LogElement): void;
  warn(msg: string | LogElement): void;
  info(msg: string | LogElement): void;
  log(msg: string | LogElement): void;
  debug(msg: string | LogElement): void;
  trace(msg: string | LogElement): void;
  
  readonly source: string;
  readonly line: Line;
}

interface LoggerConfig {
  module?: string;
  source?: string;
  [key: string]: unknown;
}
```

## Type-Safe Pipeline Inference

### Chained Pipe Type

```typescript
/**
 * Infer output type of chained pipe.
 */
type ChainOutput<
  Pipe extends readonly unknown[],
  Input
> = Pipe extends readonly []
  ? Input
  : Pipe extends readonly [infer First, ...infer Rest]
  ? First extends PipeFn<Input, infer Output>
    ? ChainOutput<Rest, NonNullable<Output>>
    : never
  : never;

type PipeFn<In, Out> = (input: In, line: Line, pos: number) => Out;

/**
 * Builder for type-safe pipeline construction.
 */
class LineBuilder<In, Current = In> {
  private stage: Stage[] = [];
  
  pipe<Out>(
    pipe: Pipe<Current, Out> | string
  ): LineBuilder<In, NonNullable<Out>> {
    this.stage.push({ pipe: pipe as Pipe<unknown, unknown> });
    return this as unknown as LineBuilder<In, NonNullable<Out>>;
  }
  
  async<Out>(
    pipe: Pipe<Current, Out> | string
  ): LineBuilder<In, NonNullable<Out>> {
    this.stage.push({ pipe: pipe as Pipe<unknown, unknown>, mode: "queue" });
    return this as unknown as LineBuilder<In, NonNullable<Out>>;
  }
  
  build(config?: Partial<LineConfig<In, Current>>): Line<In, Current> {
    return createLine({
      ...config,
      pipe: this.stage,
    });
  }
}

// Usage
const line = new LineBuilder<RawEvent>()
  .pipe(timestamper)        // RawEvent → TimestampedEvent
  .pipe(enricher)           // TimestampedEvent → EnrichedEvent
  .async(validator)         // EnrichedEvent → ValidatedEvent (async)
  .pipe(formatter)          // ValidatedEvent → FormattedEvent
  .build({ source: "myapp" });

// line: Line<RawEvent, FormattedEvent>
```

## Implementation

### Line Implementation

```typescript
class LineImpl<In, Out> implements Line<In, Out> {
  readonly pipe: Stage[];
  readonly output: Queue<Out>;
  readonly queue: Map<number, Queue<unknown>>;
  readonly registry: Registry;
  rev: number = 0;
  
  private consumerHandle: ConsumerHandle[] = [];
  
  constructor(config: LineConfig<In, Out>) {
    this.pipe = normalizePipe(config.pipe ?? []);
    this.output = config.output ?? createQueue<Out>();
    this.queue = new Map();
    this.registry = config.registry ?? defaultRegistry;
    
    // Copy context field
    Object.keys(config).forEach((key) => {
      if (!["pipe", "output", "queue", "registry"].includes(key)) {
        (this as Record<string, unknown>)[key] = config[key];
      }
    });
  }
  
  send(input: In): void | Promise<void> {
    return this.emit(input as unknown, 0);
  }
  
  emit(input: unknown, pos: number): void | Promise<void> {
    while (pos < this.pipe.length) {
      const stage = this.pipe[pos];
      const queue = this.queue.get(pos);
      
      // Async handoff
      if (queue) {
        queue.push(input);
        return;
      }
      
      // Resolve and execute pipe
      const pipeFn = this.resolvePipe(stage);
      if (!pipeFn) {
        pos++;
        continue;
      }
      
      const result = pipeFn(input, this, pos);
      
      // Handle async pipe
      if (result instanceof Promise) {
        return result.then((resolved) => {
          if (resolved === undefined || resolved === null || resolved === false) {
            return;
          }
          return this.emit(resolved, pos + 1);
        });
      }
      
      // Sync result
      if (result === undefined || result === null || result === false) {
        return;
      }
      
      input = result;
      pos++;
    }
    
    // Reached end, push to output
    this.output.push(input as Out);
  }
  
  private resolvePipe(stage: Stage): Pipe<unknown, unknown> | undefined {
    if (typeof stage.pipe === "function") {
      return stage.pipe;
    }
    return this.resolve(stage.pipe);
  }
  
  resolve<I, O>(name: string): Pipe<I, O> | undefined {
    // Check local registry first
    const local = this.registry.resolve<I, O>(name);
    if (local) return local;
    
    // Check as property
    const prop = (this as Record<string, unknown>)[name];
    if (typeof prop === "function") {
      return prop as Pipe<I, O>;
    }
    
    return undefined;
  }
  
  derive<NewIn = In, NewOut = Out>(
    config: Partial<LineConfig<NewIn, NewOut>>
  ): Line<NewIn, NewOut> {
    const child = new LineImpl<NewIn, NewOut>({
      pipe: config.pipe ?? [...this.pipe],
      output: config.output ?? createQueue<NewOut>(),
      registry: config.registry ?? this.registry.derive(),
    });
    
    // Inherit context field
    Object.keys(this).forEach((key) => {
      if (!["pipe", "output", "queue", "registry", "rev"].includes(key)) {
        if (!(key in config)) {
          (child as Record<string, unknown>)[key] = 
            (this as Record<string, unknown>)[key];
        }
      }
    });
    
    // Apply config
    Object.keys(config).forEach((key) => {
      (child as Record<string, unknown>)[key] = config[key];
    });
    
    return child;
  }
  
  splice(start: number, deleteCount: number, ...stage: Stage[]): Stage[] {
    const deleted = this.pipe.splice(start, deleteCount, ...stage);
    
    // Adjust queue position
    const newQueue = new Map<number, Queue<unknown>>();
    this.queue.forEach((q, pos) => {
      if (pos < start) {
        newQueue.set(pos, q);
      } else if (pos >= start + deleteCount) {
        newQueue.set(pos - deleteCount + stage.length, q);
      }
    });
    this.queue.clear();
    newQueue.forEach((q, pos) => this.queue.set(pos, q));
    
    this.rev++;
    return deleted;
  }
  
  async(pos: number): Queue<unknown> {
    if (!this.queue.has(pos)) {
      this.queue.set(pos, createQueue<unknown>());
    }
    return this.queue.get(pos)!;
  }
  
  logger(config: LoggerConfig = {}): Logger {
    const source = config.source ?? 
      (config.module && this.source 
        ? `${this.source}:${config.module}` 
        : this.source ?? "typeflow");
    
    const logFn = ((msg: string | LogElement) => {
      const element: LogElement = typeof msg === "string" 
        ? { message: msg } 
        : msg;
      element.source = element.source ?? source;
      this.send(element as In);
    }) as Logger;
    
    logFn.source = source;
    logFn.line = this as unknown as Line;
    
    // Add priority method
    (Object.keys(PriorityLevel) as Priority[]).forEach((priority) => {
      logFn[priority] = (msg: string | LogElement) => {
        const element: LogElement = typeof msg === "string"
          ? { message: msg }
          : msg;
        element.priority = priority;
        element.priorityLevel = PriorityLevel[priority];
        logFn(element);
      };
    });
    
    return logFn;
  }
  
  prepare_segments(): void {
    this.queue.forEach((queue, pos) => {
      const handle = spawnConsumer(this, pos, queue);
      this.consumerHandle.push(handle);
    });
  }
  
  stop_segments(): void {
    this.consumerHandle.forEach((h) => h.cancel());
    this.consumerHandle = [];
  }
}
```

### Registry Implementation

```typescript
class RegistryImpl implements Registry {
  readonly pipe: Map<string, Pipe<unknown, unknown>>;
  readonly parent?: Registry;
  
  constructor(parent?: Registry) {
    this.pipe = new Map();
    this.parent = parent;
  }
  
  register<In, Out>(name: string, pipe: Pipe<In, Out>): void {
    this.pipe.set(name, pipe as Pipe<unknown, unknown>);
  }
  
  resolve<In, Out>(name: string): Pipe<In, Out> | undefined {
    const local = this.pipe.get(name);
    if (local) return local as Pipe<In, Out>;
    
    if (this.parent) {
      return this.parent.resolve<In, Out>(name);
    }
    
    return undefined;
  }
  
  derive(): Registry {
    return new RegistryImpl(this);
  }
}

const defaultRegistry = new RegistryImpl();
```

### Queue Implementation

```typescript
interface QueueNode<T> {
  value: T;
  next?: QueueNode<T>;
}

class MpscQueue<T> implements Queue<T> {
  private head?: QueueNode<T>;
  private tail?: QueueNode<T>;
  private waiter?: {
    resolve: (value: T) => void;
    reject: (error: Error) => void;
  };
  private closed = false;
  
  push(value: T): void {
    if (this.closed) {
      throw new Error("Queue closed");
    }
    
    if (this.waiter) {
      const { resolve } = this.waiter;
      this.waiter = undefined;
      resolve(value);
      return;
    }
    
    const node: QueueNode<T> = { value };
    if (this.tail) {
      this.tail.next = node;
      this.tail = node;
    } else {
      this.head = this.tail = node;
    }
  }
  
  pop(): Promise<T> {
    if (this.head) {
      const value = this.head.value;
      this.head = this.head.next;
      if (!this.head) this.tail = undefined;
      return Promise.resolve(value);
    }
    
    if (this.closed) {
      return Promise.reject(new Error("Queue closed"));
    }
    
    return new Promise((resolve, reject) => {
      this.waiter = { resolve, reject };
    });
  }
  
  tryPop(): T | undefined {
    if (!this.head) return undefined;
    const value = this.head.value;
    this.head = this.head.next;
    if (!this.head) this.tail = undefined;
    return value;
  }
  
  isEmpty(): boolean {
    return !this.head;
  }
  
  close(): void {
    this.closed = true;
    if (this.waiter) {
      this.waiter.reject(new Error("Queue closed"));
      this.waiter = undefined;
    }
  }
}

function createQueue<T>(): Queue<T> {
  return new MpscQueue<T>();
}
```

### Consumer Implementation

```typescript
interface ConsumerHandle {
  cancel(): void;
  readonly running: boolean;
}

function spawnConsumer(
  line: Line,
  pos: number,
  queue: Queue<unknown>
): ConsumerHandle {
  let running = true;
  
  const run = async () => {
    while (running) {
      try {
        const input = await queue.pop();
        await line.emit(input, pos);
      } catch (err) {
        if ((err as Error).message === "Queue closed") {
          break;
        }
        console.error("Consumer error:", err);
      }
    }
  };
  
  // Start consumer
  run();
  
  return {
    cancel() {
      running = false;
      queue.close();
    },
    get running() {
      return running;
    },
  };
}
```

## Built-in Pipe

```typescript
// timestamper.ts
export const timestamper: Pipe<Element, Element & { time: bigint }> = (
  input,
  _line,
  _pos
) => {
  return {
    ...input,
    time: process.hrtime.bigint(),
  };
};

// cloudevent.ts
export const cloudevent: Pipe<Element, CloudElement> = (
  input,
  line,
  _pos
) => {
  return {
    ...input,
    id: input.id ?? crypto.randomUUID(),
    source: input.source ?? (line.source as string) ?? "typeflow",
    type: input.type ?? "typeflow.event",
    specversion: "1.0",
    time: input.time ?? process.hrtime.bigint(),
  };
};

// module_filter.ts
export const moduleFilter: Pipe<Element, Element> = (
  input,
  line,
  _pos
) => {
  const filter = line.filter as string | ((s: string) => boolean) | undefined;
  if (!filter) return input;
  
  const source = input.source;
  if (!source) return input;
  
  if (typeof filter === "string") {
    return source.includes(filter) ? input : undefined;
  }
  
  return filter(source) ? input : undefined;
};

// level_filter.ts
export const levelFilter: Pipe<LogElement, LogElement> = (
  input,
  line,
  _pos
) => {
  const max_level = (line.max_level as number) ?? Number.POSITIVE_INFINITY;
  const level = input.level ?? Number.POSITIVE_INFINITY;
  return level <= max_level ? input : undefined;
};

// Register default pipe
defaultRegistry.register("timestamper", timestamper);
defaultRegistry.register("cloudevent", cloudevent);
defaultRegistry.register("module_filter", moduleFilter);
defaultRegistry.register("level_filter", levelFilter);
```

## Outputter

```typescript
interface Outputter<T> {
  write(element: T): void | Promise<void>;
  close?(): void | Promise<void>;
}

// Console outputter
export function console<T extends Element>(
  config?: { format?: (e: T) => string }
): Outputter<T> {
  const format = config?.format ?? ((e) => JSON.stringify(e));
  return {
    write(element) {
      globalThis.console.log(format(element));
    },
  };
}

// File outputter (Node.js)
export function file<T extends Element>(
  config: { path: string; format?: (e: T) => string }
): Outputter<T> {
  const fs = require("fs");
  const format = config.format ?? JSON.stringify;
  const stream = fs.createWriteStream(config.path, { flags: "a" });
  
  return {
    write(element) {
      stream.write(format(element) + "\n");
    },
    close() {
      return new Promise((resolve) => stream.end(resolve));
    },
  };
}

// JSONL outputter
export function jsonl<T extends Element>(
  config: { path: string }
): Outputter<T> {
  return file({
    path: config.path,
    format: (e) => JSON.stringify(e),
  });
}

// Fanout outputter
export function fanout<T extends Element>(
  ...outputter: Outputter<T>[]
): Outputter<T> {
  return {
    async write(element) {
      await Promise.all(outputter.map((o) => o.write(element)));
    },
    async close() {
      await Promise.all(
        outputter.map((o) => o.close?.())
      );
    },
  };
}
```

## Driver

```typescript
interface Driver {
  start(): void;
  stop(): void;
}

// Interval driver
export function interval(ms: number, callback: () => void): Driver {
  let handle: ReturnType<typeof setInterval> | undefined;
  
  return {
    start() {
      if (handle) return;
      handle = setInterval(callback, ms);
    },
    stop() {
      if (handle) {
        clearInterval(handle);
        handle = undefined;
      }
    },
  };
}

// Rescheduler driver
export function rescheduler(
  config: {
    interval: number;
    backoff?: number;
    maxInterval?: number;
  },
  callback: () => boolean | Promise<boolean>
): Driver {
  const baseInterval = config.interval;
  const backoff = config.backoff ?? 1.5;
  const maxInterval = config.maxInterval ?? 2000;
  let currentInterval = baseInterval;
  let handle: ReturnType<typeof setTimeout> | undefined;
  let running = false;
  
  const schedule = async () => {
    if (!running) return;
    
    const hadWork = await callback();
    if (hadWork) {
      currentInterval = baseInterval;
    } else {
      currentInterval = Math.min(currentInterval * backoff, maxInterval);
    }
    
    handle = setTimeout(schedule, currentInterval);
  };
  
  return {
    start() {
      if (running) return;
      running = true;
      schedule();
    },
    stop() {
      running = false;
      if (handle) {
        clearTimeout(handle);
        handle = undefined;
      }
    },
  };
}
```

## Module Structure

```
typeflow/
├── src/
│   ├── index.ts           # Main export
│   ├── line.ts            # Line implementation
│   ├── registry.ts        # Registry implementation
│   ├── queue.ts           # MPSC queue
│   ├── consumer.ts        # Async consumer
│   ├── pipe/
│   │   ├── index.ts       # Re-export all pipe
│   │   ├── timestamper.ts
│   │   ├── cloudevent.ts
│   │   ├── module_filter.ts
│   │   └── level_filter.ts
│   ├── outputter/
│   │   ├── index.ts
│   │   ├── console.ts
│   │   ├── file.ts
│   │   ├── jsonl.ts
│   │   └── fanout.ts
│   ├── driver/
│   │   ├── index.ts
│   │   ├── interval.ts
│   │   └── rescheduler.ts
│   └── type.ts            # All type definition
├── test/
│   ├── line.test.ts
│   ├── registry.test.ts
│   ├── queue.test.ts
│   └── pipe.test.ts
├── package.json
├── tsconfig.json
└── README.md
```

## Package.json

```json
{
  "name": "typeflow",
  "version": "0.1.0",
  "description": "Type-safe implicit-flow pipeline",
  "type": "module",
  "main": "./dist/index.js",
  "types": "./dist/index.d.ts",
  "exports": {
    ".": {
      "import": "./dist/index.js",
      "types": "./dist/index.d.ts"
    },
    "./pipe": {
      "import": "./dist/pipe/index.js",
      "types": "./dist/pipe/index.d.ts"
    },
    "./outputter": {
      "import": "./dist/outputter/index.js",
      "types": "./dist/outputter/index.d.ts"
    },
    "./driver": {
      "import": "./dist/driver/index.js",
      "types": "./dist/driver/index.d.ts"
    }
  },
  "scripts": {
    "build": "tsdown src/index.ts --dts",
    "check": "tsgo --noEmit",
    "test": "vitest",
    "lint": "oxlint",
    "format": "oxfmt --write src/"
  },
  "devDependencies": {
    "@typescript/native-preview": "^7.0.0-dev",
    "oxfmt": "latest",
    "oxlint": "latest",
    "tsdown": "latest",
    "vitest": "latest"
  },
  "keywords": ["pipeline", "dataflow", "logging", "typescript"],
  "license": "MIT"
}
```

## Usage Example

```typescript
import { createLine, LineBuilder } from "typeflow";
import { timestamper, cloudevent, moduleFilter } from "typeflow/pipe";
import { console as consoleOut, jsonl } from "typeflow/outputter";
import { rescheduler } from "typeflow/driver";

// Simple usage
const app = createLine({
  source: "myapp:main",
  pipe: ["timestamper", "cloudevent", "module_filter"],
});

const log = app.logger({ module: "startup" });
log.info("Application starting");

// Type-safe builder
interface AppEvent {
  message: string;
  userId?: string;
}

const typedLine = new LineBuilder<AppEvent>()
  .pipe(timestamper)
  .pipe(cloudevent)
  .pipe((input, line, pos) => {
    // TypeScript knows input has time, id, source, etc.
    return { ...input, processed: true };
  })
  .build({ source: "myapp" });

// Consume output
const outputter = consoleOut<CloudEvent>();

(async () => {
  while (true) {
    const event = await typedLine.output.pop();
    outputter.write(event);
  }
})();

// With driver
const driver = rescheduler({ interval: 100 }, async () => {
  const event = typedLine.output.tryPop();
  if (event) {
    await outputter.write(event);
    return true;
  }
  return false;
});

driver.start();
```

## Test Example

```typescript
import { describe, it, expect } from "vitest";
import { createLine, createRegistry } from "typeflow";
import { timestamper } from "typeflow/pipe";

describe("Line", () => {
  it("should send element through pipeline", async () => {
    const line = createLine({
      pipe: [timestamper],
    });
    
    line.send({ message: "test" });
    
    const output = await line.output.pop();
    expect(output.message).toBe("test");
    expect(output.time).toBeDefined();
    expect(typeof output.time).toBe("bigint");
  });
  
  it("should filter element returning undefined", async () => {
    const line = createLine({
      pipe: [
        (input) => input.keep ? input : undefined,
      ],
    });
    
    line.send({ keep: false });
    line.send({ keep: true });
    
    const output = await line.output.pop();
    expect(output.keep).toBe(true);
    expect(line.output.isEmpty()).toBe(true);
  });
  
  it("should support async pipe", async () => {
    const line = createLine({
      pipe: [
        async (input) => {
          await new Promise((r) => setTimeout(r, 10));
          return { ...input, delayed: true };
        },
      ],
    });
    
    await line.send({ message: "async" });
    
    const output = await line.output.pop();
    expect(output.delayed).toBe(true);
  });
});

describe("Registry", () => {
  it("should resolve registered pipe", () => {
    const registry = createRegistry();
    const myPipe = (input: unknown) => input;
    
    registry.register("myPipe", myPipe);
    
    expect(registry.resolve("myPipe")).toBe(myPipe);
  });
  
  it("should inherit from parent registry", () => {
    const parent = createRegistry();
    parent.register("parentPipe", (i) => i);
    
    const child = parent.derive();
    child.register("childPipe", (i) => i);
    
    expect(child.resolve("parentPipe")).toBeDefined();
    expect(child.resolve("childPipe")).toBeDefined();
    expect(parent.resolve("childPipe")).toBeUndefined();
  });
});
```

## License

MIT
