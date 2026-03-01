+++
title = "Should I Use Moka or Hitbox?"
date = 2026-02-28
description = "A short overview of the Rust caching ecosystem — what stores data, what coordinates it, and where Hitbox fits in."

[taxonomies]
tags = ["moka", "caching"]

[extra]
og_image = "og/moka-or-hitbox.png"
og_highlight = "Moka"
reading_time = 2
+++

{% tldr() %}
**tl;dr:** Both. Moka is a storage backend. Hitbox is an orchestrator. They solve different problems.
{% end %}

Rust has a lot of caching crates: Moka, redis-rs, Memcache, lru_cache, cached, and others. They can be roughly split into two groups — storage engines (databases, data structures) and crates that add higher-level functionality, like http-cache-tower with HTTP semantics. This article focuses on the first group.

## The Cache Storage Trap

A typical Moka-based handler looks like this:

```rust
use moka::future::Cache;

async fn get_user(
    State(user_service): State<UserService>,
    State(cache): State<Cache<String, Vec<u8>>>,
    Path(user_id): Path<u64>,
) -> Result<Json<User>, AppError> {
    let key = format!("user:{user_id}");

    if let Some(bytes) = cache.get(&key).await {
        return Ok(Json(serde_json::from_slice(&bytes)?));
    }

    let user = user_service.get_user(user_id).await?;
    let bytes = serde_json::to_vec(&user)?;
    cache.insert(key, bytes).await;

    Ok(Json(user))
}
```

One line of business logic, ten lines of caching plumbing — key construction, serialization (not required for Moka itself, but unavoidable with Redis or other byte-oriented backends), hit/miss logic. This pattern repeats in every handler that uses caching, usually with slight variations.

Under high traffic, this approach runs into several known problems.

**Dogpile effect.** When a cached entry expires and many requests arrive simultaneously, all of them miss the cache and hit the upstream — the actual data source behind it, whether that's a database, an external API, or another service. A locking mechanism solves this partially — one request refreshes, the others wait — but if that request is slow or fails, all waiters are affected. A semaphore-based approach allows a few requests to race, with the first to finish broadcasting the result to the rest. There's also a policy question: if the upstream returns an error, should waiters fail or retry independently?

**Offload revalidation.** To reduce cache-miss latency, the TTL can be split into two phases — a stale window and a hard expiration. Requests that hit a stale entry receive the cached value immediately while a background job refreshes it.

```
|── fresh ──|── stale ──|── expired ──>
0        stale_ttl      ttl
```

**Distributed state.** With multiple server instances, each running its own Moka cache, hit rates drop because instances don't share state. Adding Redis solves sharing but removes fast local reads. Using both as L1 (Moka) and L2 (Redis Cluster) preserves local speed but requires refilling logic, write ordering, and consistency code between layers.

On top of this, a production caching system typically also requires metrics, a serialization format and compression, and the ability to add new backends.

**So, one day, it becomes its own Hitbox.**

## Hitbox

Hitbox is a cache orchestrator. It works with storage backends — Moka, Redis, FeOxDB — and provides a `Backend` trait for adding others. The backends handle storage; Hitbox handles coordination.

For function-level caching, a `#[cached]` macro replaces the manual plumbing:

```rust
#[cached]
async fn get_user(user_id: UserId) -> Result<User, AppError> {
    db.query_user(user_id.0).await
}
```

For HTTP services, caching is handled as Tower middleware. Predicates define which requests and responses are cacheable, extractors define how cache keys are constructed, and policies define TTL, stale behavior, and concurrency limits. For a step-by-step walkthrough of setting this up in Axum, see [Response Caching in Axum with Hitbox](https://blog.hitbox.rs/blog/axum-caching-in-10-minutes/).

The features described above — dogpile prevention, stale-while-revalidate, L1/L2 composition — are built-in and controlled through configuration:

- **Dogpile prevention** — a concurrency limit per cache key
- **Stale-While-Revalidate** — a stale window with background refresh via offload policy
- **L1/L2 composition** — backends composed with configurable refill, read, and write policies
- **Multi-tier** — composition is recursive (Moka → FeOxDB → Redis)

Changing the caching strategy — from single-backend to multi-tier, or from no-stale to stale-while-revalidate — is a configuration change. Handler and middleware code remains the same.

## Conclusion

Moka, Redis, and Hitbox solve different parts of the caching problem. Moka and Redis are storage engines. Hitbox is an orchestration layer that composes them. There is no choice to make between them — they work together.
