# effectflow: PubSub for Fanout

> Use PubSub for multi-subscriber output distribution

## Core Insight

`PubSub<A>` is a broadcast channel: one publisher, many subscribers. Instead of a single output queue, use PubSub to **fanout to multiple consumers** without explicit fanout logic.

## Concept

| Pipeline Term | PubSub Equivalent |
|---------------|-------------------|
| Output queue | `PubSub<Output>` |
| Fanout outputter | Multiple `PubSub.subscribe` |
| Consumer | Subscriber fiber |

## Structure

```typescript
// Pipeline publishes to PubSub
const pipeline = Effect.gen(function* () {
  const pubsub = yield* PubSub.unbounded<ProcessedElement>()
  
  // Multiple subscribers (each gets all messages)
  const consoleSub = yield* PubSub.subscribe(pubsub)
  const fileSub = yield* PubSub.subscribe(pubsub)
  const metricsSub = yield* PubSub.subscribe(pubsub)
  
  // Spawn consumer fibers
  yield* Effect.fork(consumeToConsole(consoleSub))
  yield* Effect.fork(consumeToFile(fileSub))
  yield* Effect.fork(consumeToMetrics(metricsSub))
  
  return { publish: (e) => PubSub.publish(pubsub, e) }
})
```

## Benefits

- **Decoupled consumers**: Add/remove without changing pipeline
- **Broadcast**: All subscribers get all messages
- **Backpressure**: Bounded PubSub applies pressure
- **Late subscribers**: Can join anytime (miss earlier messages)
- **Typed**: Full type safety on message type

## Key Patterns

### Dynamic Subscription
```typescript
// Consumers subscribe/unsubscribe at runtime
const addConsumer = (pubsub: PubSub<Element>) =>
  Effect.scoped(
    Effect.gen(function* () {
      const sub = yield* PubSub.subscribe(pubsub)
      yield* Stream.fromQueue(sub).pipe(
        Stream.runForEach(processElement)
      )
    })
  )
```

### Filtered Subscription
```typescript
// Each subscriber can filter independently
Stream.fromQueue(subscription).pipe(
  Stream.filter((e) => e.priority === "error"),
  Stream.runForEach(alertOnError)
)
```

## vs Queue Fanout

| Aspect | Queue + Fanout | PubSub |
|--------|----------------|--------|
| Delivery | Manual copy to each | Automatic broadcast |
| Adding consumers | Modify fanout list | Just subscribe |
| Memory | One copy per consumer | Shared until consumed |
| Backpressure | Slowest consumer | Per-subscriber |

## When Useful

- Multiple independent consumers of same output
- Dynamic consumer registration
- Different consumers need different filtering
- Metrics/logging alongside primary output
