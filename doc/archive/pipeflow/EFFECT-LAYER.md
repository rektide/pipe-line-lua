# effectflow: Layer-as-Pipeline

> Model the entire pipeline as composable Layer

## Core Insight

In Effect, `Layer<Out, E, In>` represents a recipe for building services from dependencies. What if each **pipe stage is a Layer**, and the **pipeline is Layer composition**?

```
Layer.provide(Layer.provide(Layer.provide(
  OutputLayer,
  TransformLayer),
  EnrichLayer),
  TimestampLayer)
```

## Concept

| Pipeline Term | Layer Equivalent |
|---------------|------------------|
| Pipe | `Layer<StageN, E, StageN-1>` |
| Pipeline | `Layer.provide` chain |
| Input | Initial `Context` |
| Output | Final service |
| Async stage | `Layer.scoped` with Queue |

## Structure

```typescript
// Each stage is a Layer that depends on previous stage's output
type PipeLayer<In, Out, E = never> = Layer.Layer<Out, E, In>

// Pipeline is right-to-left composition
const pipeline = pipe(
  OutputLayer,              // Layer<Output, never, Formatted>
  Layer.provide(FormatLayer),    // Layer<Formatted, never, Validated>
  Layer.provide(ValidateLayer),  // Layer<Validated, ValidationError, Enriched>
  Layer.provide(EnrichLayer),    // Layer<Enriched, never, Timestamped>
  Layer.provide(TimestampLayer), // Layer<Timestamped, never, RawInput>
)
```

## Benefits

- **Memoization**: Layer caches by default, pipeline stages built once
- **Scoped resources**: Each stage can acquire/release resources
- **Composition**: Pipelines combine with `Layer.merge`, `Layer.provideMerge`
- **Testing**: Swap stages with `Layer.succeed` test doubles
- **Error aggregation**: Layer surfaces all construction errors

## Sketch

```typescript
// Input as a service tag
class PipeInput<T> extends Context.Tag("PipeInput")<PipeInput<T>, T>() {}

// Each pipe stage wraps transformation in Layer
const TimestampLayer = Layer.effect(
  TimestampedTag,
  Effect.gen(function* () {
    const input = yield* PipeInput
    return { ...input, time: process.hrtime.bigint() }
  })
)

// Pipeline = composed Layers
const Pipeline = pipe(
  OutputLayer,
  Layer.provide(FormatLayer),
  Layer.provide(TimestampLayer),
)

// Run by providing initial input
const run = (input: RawEvent) =>
  Effect.provide(
    OutputTag,  // Request final output
    Layer.succeed(PipeInput, input).pipe(Layer.provide(Pipeline))
  )
```

## When Useful

- Static pipeline configuration (stages don't change at runtime)
- Stage initialization is expensive (Layer memoizes)
- Pipeline has resource lifecycle (connections, file handles)
- Testing pipeline with mock stages
