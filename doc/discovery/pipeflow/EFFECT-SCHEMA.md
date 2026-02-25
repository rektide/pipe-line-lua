# effectflow: Schema-Validated Pipeline

> Use Effect Schema for type-safe element transformation and validation

## Core Insight

`@effect/schema` provides runtime validation that mirrors TypeScript types. Each **pipe stage can declare input/output schemas**, enabling:

- Automatic validation at stage boundaries
- Runtime type narrowing
- JSON serialization/deserialization
- Documentation generation

## Concept

| Pipeline Term | Schema Equivalent |
|---------------|-------------------|
| Element type | `Schema.Schema<A>` |
| Transform pipe | `Schema.transform(from, to, decode, encode)` |
| Validation pipe | `Schema.filter` / `Schema.refine` |
| Boundary | `Schema.decode` / `Schema.encode` |

## Structure

```typescript
// Define element schemas
const RawEventSchema = Schema.Struct({
  message: Schema.String,
  data: Schema.optional(Schema.Unknown),
})

const TimestampedSchema = Schema.extend(RawEventSchema, Schema.Struct({
  time: Schema.BigIntFromSelf,
}))

const CloudElementSchema = Schema.Struct({
  id: Schema.UUID,
  source: Schema.String,
  type: Schema.String,
  specversion: Schema.Literal("1.0"),
  time: Schema.BigIntFromSelf,
  data: Schema.optional(Schema.Unknown),
})

// Pipe as schema transformation
const timestampPipe = Schema.transform(
  RawEventSchema,
  TimestampedSchema,
  {
    decode: (raw) => ({ ...raw, time: process.hrtime.bigint() }),
    encode: ({ time, ...rest }) => rest,
  }
)
```

## Benefits

- **Runtime safety**: Catch malformed data at boundaries
- **Bidirectional**: Encode for serialization, decode for parsing
- **Error messages**: Rich, structured validation errors
- **Composition**: Schemas compose with `Schema.extend`, `Schema.pipe`
- **JSON Schema**: Generate OpenAPI/JSON Schema for docs
- **Arbitrary**: Generate test data with fast-check integration

## Key Patterns

### Validation Pipe
```typescript
const validatedPipe = Schema.filter(CloudElementSchema, (e) =>
  e.source.startsWith("myapp:") ? Option.none() : Option.some("Invalid source")
)
```

### Transformation Chain
```typescript
const pipeline = Schema.compose(
  timestampTransform,
  enrichTransform,
  cloudEventTransform,
)

// Decode through entire pipeline
const result = Schema.decodeUnknownSync(pipeline)(rawInput)
```

### Boundary Validation
```typescript
// At queue boundary, validate shape
const validateAndQueue = (input: unknown) =>
  Schema.decodeUnknown(RawEventSchema)(input).pipe(
    Effect.flatMap((valid) => Queue.offer(inputQueue, valid))
  )
```

## When Useful

- External input (HTTP, file, user input) needs validation
- Pipeline crosses trust boundaries
- Need serialization format (JSON Lines, protobuf)
- Want auto-generated documentation
- Testing with generated arbitrary data
