# effectflow: Request Batching

> Use Effect's Batching/Request for automatic deduplication and batching

## Core Insight

Effect's `Request` and `RequestResolver` enable **automatic batching** of operations. If multiple elements need the same external lookup, batch them into one call.

## Concept

| Pipeline Need | Batching Feature |
|---------------|------------------|
| Deduplicate lookups | `Request` with same ID |
| Batch API calls | `RequestResolver.makeBatched` |
| Cache results | `Request` memoization |
| N+1 prevention | Automatic batching window |

## Structure

```typescript
import { Request, RequestResolver, Effect } from "effect"

// Define a request type
interface EnrichRequest extends Request.Request<EnrichedData, EnrichError> {
  readonly _tag: "EnrichRequest"
  readonly userId: string
}

const EnrichRequest = Request.tagged<EnrichRequest>("EnrichRequest")

// Batched resolver
const EnrichResolver = RequestResolver.makeBatched(
  (requests: ReadonlyArray<EnrichRequest>) =>
    Effect.gen(function* () {
      // Single bulk API call for all requests
      const userIds = requests.map((r) => r.userId)
      const results = yield* bulkFetchUserData(userIds)
      
      // Complete each request
      return requests.map((req, i) => 
        Request.succeed(req, results[i])
      )
    })
)

// Use in pipe
const enrichPipe = (element: Element) =>
  Effect.request(
    EnrichRequest({ userId: element.userId }),
    EnrichResolver
  ).pipe(
    Effect.map((enriched) => ({ ...element, ...enriched }))
  )
```

## Benefits

- **Automatic batching**: Effect collects requests in window
- **Deduplication**: Same request ID → single execution
- **Caching**: Results cached for request lifetime
- **Transparent**: Caller doesn't know about batching
- **Concurrent-safe**: Works across fibers

## Key Patterns

### Batching Window
```typescript
// Requests within 10ms window batch together
Effect.withRequestBatching(true).pipe(
  Effect.withRequestCaching(true)
)
```

### Fallback on Failure
```typescript
const resilientResolver = RequestResolver.makeBatched(
  (requests) =>
    batchFetch(requests).pipe(
      Effect.catchAll(() =>
        // Fallback to individual requests
        Effect.forEach(requests, individualFetch)
      )
    )
)
```

### DataLoader Pattern
```typescript
// Classic DataLoader semantics
const loader = <K, V>(batchFn: (keys: K[]) => Effect<Map<K, V>>) =>
  RequestResolver.makeBatched((requests: Request<V, Error>[]) =>
    batchFn(requests.map((r) => r.key)).pipe(
      Effect.map((results) =>
        requests.map((r) => Request.succeed(r, results.get(r.key)!))
      )
    )
  )
```

## When Useful

- External API calls that support bulk operations
- Database lookups (batch SELECT)
- Cache population
- Preventing N+1 query patterns
- Rate-limited APIs (fewer calls = fewer limits)
