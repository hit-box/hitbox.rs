+++
title = "Real-world system"
date = 2026-02-09
description = "Highly customizable async caching framework for Rust designed for high-performance applications. Protocol-agnostic async core + first-class HTTP support via hitbox-http. Pluggable backends from in-memory to distributed solutions such as Redis. Built on tower, works with any tokio-based service."

[taxonomies]
tags = ["framework"]
+++

Building caching into a production system is different from adding it to a tutorial.
Real-world services have to deal with partial failures, varying load patterns, and data
that changes at unpredictable intervals. Here's how teams are using Hitbox in practice.

## The architecture

A typical Hitbox deployment sits between your HTTP handlers and your data layer. Requests
flow through the cache layer before reaching databases, third-party APIs, or compute-heavy
operations.

```
Client → Load Balancer → App Server → CacheLayer → Upstream Service
                                          ↕
                                     Redis / Memory
```

The cache layer is transparent to your application logic. Your handlers don't know whether
they're getting a cached response or a fresh one — the service interface is identical.

## Case study: API gateway

One common pattern is using Hitbox as a caching layer in an API gateway. The gateway
receives requests from mobile and web clients, checks the cache, and either returns a
cached response or forwards the request to the appropriate microservice.

```rust
#[derive(CacheableRequest)]
#[cache(key = "catalog:{category}:{page}", ttl = 120)]
struct GetCatalog {
    category: String,
    page: u32,
}
```

The catalog data changes roughly every few minutes, so a 120-second TTL provides a good
balance between freshness and performance. With dogpile protection enabled, even during
cache refreshes only one request per key hits the catalog service.

In production, this pattern reduced P99 latency from 450ms to 12ms and cut upstream
traffic by 87%. The cache hit rate stabilizes around 94% during peak hours.

## Cache invalidation strategies

The hardest part of caching is knowing when to invalidate. Hitbox supports several
approaches depending on your consistency requirements.

**TTL-based expiration** is the simplest. Set a TTL on each request type and let entries
expire naturally. This works well for data that changes on a predictable schedule.

**Explicit invalidation** is necessary when data changes are event-driven. Hitbox provides
a direct invalidation API:

```rust
cache.invalidate("user:42").await;
cache.invalidate_pattern("posts:user:42:*").await;
```

**Stale-while-revalidate** is a hybrid approach. Hitbox serves the stale cached value
immediately while refreshing it in the background. This eliminates latency spikes during
cache misses at the cost of briefly serving outdated data.

```rust
let config = CacheConfig::builder()
    .default_ttl(Duration::from_secs(60))
    .max_stale(Duration::from_secs(10))
    .build();
```

## Handling partial failures

In a distributed system, the cache backend itself can fail. Hitbox handles this gracefully:
if Redis is unreachable, requests fall through to the upstream service. Your application
continues to function — just without caching.

This fail-open behavior is critical for production systems. A cache should improve
performance, never block requests. Hitbox logs cache backend errors and increments a
counter so your monitoring can alert on degraded cache availability.

## Monitoring and observability

Understanding cache behavior is essential for tuning. Hitbox exposes metrics that answer
the key questions: What's the hit rate? Which keys are hot? How often does dogpile
protection activate?

The `hitbox-metrics` crate integrates with Prometheus to expose:

- `hitbox_requests_total` — total cache lookups, labeled by hit/miss/error
- `hitbox_latency_seconds` — histogram of cache operation latency
- `hitbox_dogpile_waits_total` — number of requests that waited for dogpile resolution
- `hitbox_backend_errors_total` — cache backend failures

A healthy system shows a hit rate above 80%, dogpile waits under 5% of total requests,
and zero backend errors. If your hit rate drops below 60%, your TTLs might be too short
or your cache keys too granular.

## Scaling considerations

Hitbox scales horizontally because the cache layer is stateless — all state lives in the
backend. Adding more app server instances doesn't require any cache coordination.

For high-throughput services (>10K requests/second), consider:

- **Connection pooling** — The Redis backend supports configurable connection pools
- **Key sharding** — Distribute keys across multiple Redis instances
- **Local + remote** — Use an in-memory L1 cache backed by Redis L2

The two-tier approach is particularly effective. Hot keys are served from local memory
with sub-microsecond latency, while the Redis layer handles the long tail and provides
consistency across instances.

## Lessons learned

After running Hitbox in production across several services, a few patterns emerge:

1. **Start with conservative TTLs.** It's easier to increase a TTL than to debug stale
   data issues. Begin with 30-60 seconds and increase based on observed staleness tolerance.

2. **Cache at the right granularity.** Caching an entire API response is simpler but wastes
   memory. Caching individual database queries is more efficient but harder to invalidate.
   Find the level that matches your invalidation strategy.

3. **Monitor from day one.** Don't add caching without metrics. You need to know whether
   it's actually helping, and you need to detect regressions quickly.

4. **Test cache failures.** Regularly verify that your service works correctly when the
   cache backend is down. Chaos engineering practices like killing Redis during load tests
   reveal surprising dependencies.

Hitbox is designed to make these patterns easy. The framework handles the hard parts —
concurrency control, backend abstraction, failure recovery — so you can focus on choosing
the right caching strategy for your data.
