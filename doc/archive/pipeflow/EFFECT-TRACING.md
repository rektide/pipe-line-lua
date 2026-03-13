# effectflow: Observability with Tracing and Metrics

> Built-in tracing spans and metrics for pipeline visibility

## Core Insight

Effect has native tracing (`Tracer`) and metrics (`Metric`) support. Each **pipe stage becomes a span**, pipeline execution is a **trace**, and throughput/latency are **metrics**.

## Concept

| Pipeline Term | Observability |
|---------------|---------------|
| Pipe execution | `Effect.withSpan("stage-name")` |
| Pipeline run | Parent trace span |
| Throughput | `Metric.counter` |
| Latency | `Metric.histogram` |
| Queue depth | `Metric.gauge` |
| Errors | `Metric.counter` with tags |

## Structure

```typescript
// Wrap each pipe in a span
const tracedPipe = <In, Out>(name: string, pipe: Pipe<In, Out>): Pipe<In, Out> =>
  (input) => pipe(input).pipe(Effect.withSpan(name))

// Pipeline creates parent span
const tracedPipeline = (input: Element) =>
  Effect.withSpan("pipeline")(
    pipe(
      input,
      tracedPipe("timestamp", timestamper),
      Effect.andThen(tracedPipe("enrich", enricher)),
      Effect.andThen(tracedPipe("format", formatter)),
    )
  )

// Metrics
const processed = Metric.counter("pipeline.processed")
const latency = Metric.histogram("pipeline.latency.ms", Metric.Boundaries.linear(0, 10, 20))

const metered = <A>(effect: Effect<A>) =>
  Effect.timed(effect).pipe(
    Effect.tap(([duration, _]) => 
      Metric.update(latency, Duration.toMillis(duration))
    ),
    Effect.tap(() => Metric.increment(processed)),
    Effect.map(([_, result]) => result)
  )
```

## Benefits

- **Zero-config**: Effect runtime includes tracer
- **OpenTelemetry**: Export to Jaeger, Zipkin, etc.
- **Correlation**: Automatic trace ID propagation
- **Low overhead**: Sampling, lazy evaluation
- **Typed metrics**: Metric types prevent misuse

## Key Patterns

### Span Attributes
```typescript
Effect.withSpan("process", {
  attributes: {
    "element.source": element.source,
    "element.priority": element.priority,
  }
})
```

### Error Tracking
```typescript
const errors = Metric.counter("pipeline.errors").pipe(
  Metric.taggedWithLabels(["stage", "error_type"])
)

pipe.pipe(
  Effect.catchAll((error) =>
    Metric.increment(errors, { stage: "validate", error_type: error._tag }).pipe(
      Effect.andThen(Effect.fail(error))
    )
  )
)
```

### Queue Depth Gauge
```typescript
const queueDepth = Metric.gauge("queue.depth")

Effect.repeat(
  Queue.size(queue).pipe(Effect.flatMap((size) => Metric.set(queueDepth, size))),
  Schedule.spaced("1 second")
)
```

## Integration

```typescript
import { NodeSdk } from "@effect/opentelemetry"
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http"

const TracingLayer = NodeSdk.layer(() => ({
  resource: { serviceName: "effectflow" },
  spanProcessor: new BatchSpanProcessor(new OTLPTraceExporter()),
}))

// Provide to pipeline
program.pipe(Effect.provide(TracingLayer))
```

## When Useful

- Production observability requirements
- Debugging slow pipeline stages
- Capacity planning (throughput metrics)
- Error rate monitoring
- Distributed tracing across services
