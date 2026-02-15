# effectflow: Schedule for Retry and Batching

> Use Schedule for retry policies, periodic flush, and rate limiting

## Core Insight

`Schedule<Out, In, R>` describes recurrence patterns. Apply to pipeline for:

- **Retry** failed pipe stages
- **Periodic flush** of batched output
- **Rate limiting** throughput
- **Timeout** slow stages

## Concept

| Pipeline Need | Schedule Pattern |
|---------------|------------------|
| Retry on failure | `Effect.retry(pipe, schedule)` |
| Periodic batch flush | `Schedule.spaced` + consumer |
| Rate limit | `Schedule.fixed` between sends |
| Timeout | `Effect.timeout` + `Schedule.once` |
| Exponential backoff | `Schedule.exponential` |

## Structure

```typescript
// Retry transient failures with backoff
const resilientPipe = (input: Element) =>
  riskyTransform(input).pipe(
    Effect.retry(
      Schedule.exponential("100 millis").pipe(
        Schedule.compose(Schedule.recurs(3))
      )
    )
  )

// Periodic batch flush
const batchConsumer = (queue: Queue<Element>, flush: (batch: Element[]) => Effect<void>) =>
  Effect.gen(function* () {
    const batch = yield* Ref.make<Element[]>([])
    
    // Flush on schedule OR when batch full
    yield* Effect.race(
      Schedule.spaced("1 second").pipe(
        Effect.repeat(flushBatch(batch, flush))
      ),
      watchBatchSize(batch, 100, flush)
    )
  })
```

## Benefits

- **Composable**: Combine schedules with `&&`, `||`, `andThen`
- **Introspectable**: Track retry count, delays
- **Resource-aware**: Jitter, capping, windows
- **Type-safe**: Schedule carries input/output types

## Key Patterns

### Capped Exponential Backoff
```typescript
Schedule.exponential("100 millis").pipe(
  Schedule.either(Schedule.spaced("10 seconds")),  // Cap at 10s
  Schedule.compose(Schedule.recurs(5)),             // Max 5 retries
)
```

### Rate Limiting
```typescript
const rateLimited = <A>(effect: Effect<A>, rps: number) =>
  effect.pipe(
    Effect.delay(Duration.millis(1000 / rps))
  )
```

### Windowed Batching
```typescript
Stream.groupedWithin({ 
  max: 100, 
  timeout: Duration.seconds(5) 
})
```

## When Useful

- Unreliable external services (HTTP, DB)
- Batching for efficiency (bulk writes)
- Rate limiting API calls
- Timeout slow operations
- Implementing circuit breakers
