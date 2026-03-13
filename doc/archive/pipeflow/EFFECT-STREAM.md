# effectflow: Stream-Native Pipeline

> Pipeline IS a Stream transformation, not a queue chain

## Core Insight

Rather than queues connecting pipe stages, the **pipeline itself is a `Stream.Stream`**. Input flows in, transformations compose via `Stream.map`/`Stream.flatMap`, output flows out.

```
Stream<RawInput> → Stream.pipe(transform₁, transform₂, ...) → Stream<Output>
```

## Concept

| Pipeline Term | Stream Equivalent |
|---------------|-------------------|
| Pipe | `Stream.map` / `Stream.flatMap` |
| Filter | `Stream.filter` |
| Async boundary | `Stream.buffer` / `Stream.mapConcurrent` |
| Multi-emit | `Stream.flatMap` (1→N) |
| Pipeline | `Stream.pipe(...)` composition |
| Output | `Stream.run*` sink |

## Structure

```typescript
// Pipeline as Stream transformation
const pipeline = (input: Stream.Stream<RawEvent>) =>
  input.pipe(
    Stream.map(timestamper),
    Stream.map(enricher),
    Stream.filter(moduleFilter),
    Stream.buffer({ capacity: 16 }),  // async boundary
    Stream.map(formatter),
  )

// Run with sink
Stream.runForEach(pipeline(inputStream), outputter.write)
```

## Benefits

- **Backpressure**: Built into Stream, no manual queue management
- **Concurrency**: `Stream.mapConcurrent` for parallel stages
- **Chunking**: `Stream.groupedWithin` for batching
- **Resource safety**: Stream finalizers for cleanup
- **Composition**: Streams compose naturally
- **Pull-based**: Consumer controls throughput

## Key Patterns

### Async Boundary
```typescript
Stream.buffer({ capacity: 16 })  // Bounded async buffer
Stream.mapConcurrent(4, transform)  // Parallel transform
```

### Multi-Emit (1→N)
```typescript
Stream.flatMap((item) => Stream.fromIterable(item.children))
```

### Batching
```typescript
Stream.groupedWithin({ max: 100, timeout: "1 second" })
```

### Error Handling
```typescript
Stream.catchAll((error) => Stream.succeed(fallbackValue))
Stream.retry(Schedule.exponential("100 millis"))
```

## When Useful

- High-throughput processing
- Natural backpressure needed
- Variable emission rates (1→N transforms)
- Batching/windowing requirements
- Integration with existing Stream sources
