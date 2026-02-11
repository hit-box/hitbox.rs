+++
title = "Platform for caching"
date = 2026-02-08
description = "We think of Hitbox not as a library, but as a platform for caching, designed from day one to be easily extensible without enforcing a single backend, protocol, or caching strategy."

[taxonomies]
tags = ["framework", "platform"]
+++

Most caching libraries are opinionated. They pick a backend, a serialization format, and a
set of assumptions about how you'll use them. Hitbox takes a different approach: it's a
platform for building caching systems, not a prepackaged solution.

## Why a platform?

The caching needs of a real-time game server are fundamentally different from those of an
e-commerce API. A game server needs sub-millisecond local cache with aggressive eviction.
An e-commerce API needs distributed caching with careful invalidation around inventory
changes. A platform approach lets both teams use the same core framework while making
completely different tradeoffs.

Hitbox achieves this through four abstract traits:

```rust
pub trait Backend: Send + Sync + 'static {
    async fn get(&self, key: &str) -> Result<Option<CachedValue>>;
    async fn set(&self, key: &str, value: CachedValue, ttl: Duration) -> Result<()>;
    async fn delete(&self, key: &str) -> Result<()>;
}

pub trait CacheableRequest: Send + Sync + 'static {
    type Response: Serialize + DeserializeOwned;
    fn cache_key(&self) -> String;
    fn cache_ttl(&self) -> Duration;
}
```

Everything in Hitbox is built on these interfaces. The FSM that orchestrates cache
operations doesn't know or care whether it's talking to Redis, Memcached, DynamoDB, or
a local `HashMap`. It just calls `get` and `set`.

## Backend ecosystem

This trait-based design has enabled a growing ecosystem of backends:

- **hitbox-backend-redis** — Production-grade Redis backend with connection pooling,
  pipelining, and cluster support
- **hitbox-backend-memory** — Lock-free in-memory cache using `DashMap`, ideal for
  single-instance deployments and L1 caching
- **hitbox-backend-dynamodb** — AWS DynamoDB backend for serverless architectures
  where Redis isn't available

Community contributors have added experimental backends for SQLite (embedded caching with
persistence) and Memcached (for teams with existing Memcached infrastructure).

Writing a new backend is straightforward. The `Backend` trait has three required methods
and typically takes 50-100 lines of code to implement. Here's a minimal example:

```rust
struct MyBackend {
    store: DashMap<String, (CachedValue, Instant)>,
}

#[async_trait]
impl Backend for MyBackend {
    async fn get(&self, key: &str) -> Result<Option<CachedValue>> {
        match self.store.get(key) {
            Some(entry) if entry.1 > Instant::now() => Ok(Some(entry.0.clone())),
            _ => Ok(None),
        }
    }

    async fn set(&self, key: &str, value: CachedValue, ttl: Duration) -> Result<()> {
        self.store.insert(key.to_string(), (value, Instant::now() + ttl));
        Ok(())
    }

    async fn delete(&self, key: &str) -> Result<()> {
        self.store.remove(key);
        Ok(())
    }
}
```

## Protocol agnosticism

Hitbox's core is protocol-agnostic. The `CacheableRequest` trait works with any request/
response pattern — HTTP, gRPC, WebSocket messages, or custom binary protocols.

The `hitbox-http` crate adds HTTP-specific features like `Cache-Control` header parsing,
`ETag` support, and conditional request handling. But these are optional extensions, not
core requirements.

For Tower-based services, the `CacheLayer` integrates directly into the middleware stack:

```rust
let service = ServiceBuilder::new()
    .layer(CacheLayer::new(backend))
    .layer(TimeoutLayer::new(Duration::from_secs(30)))
    .layer(RateLimitLayer::new(100, Duration::from_secs(1)))
    .service(my_service);
```

This composability is deliberate. Caching is one layer in your service stack, not a
framework that takes over your architecture.

## Serialization flexibility

By default, Hitbox uses `bincode` for serialization — it's fast and compact. But not
every team wants binary serialization. Some need JSON for debugging visibility, others
need `MessagePack` for cross-language compatibility.

Hitbox supports pluggable serializers through the `CacheSerializer` trait:

```rust
pub trait CacheSerializer {
    fn serialize<T: Serialize>(value: &T) -> Result<Vec<u8>>;
    fn deserialize<T: DeserializeOwned>(bytes: &[u8]) -> Result<T>;
}
```

Switching from `bincode` to JSON is a one-line configuration change. The rest of your
code stays the same.

## The FSM at the core

What ties everything together is Hitbox's finite state machine. The FSM manages the
lifecycle of every cache operation:

1. **Pending** — Request received, checking cache
2. **Hit** — Cache entry found and valid, returning cached response
3. **Miss** — No cache entry, forwarding to upstream
4. **Stale** — Entry expired but within `max_stale`, serving stale + revalidating
5. **Locked** — Another request is refreshing this key, waiting for result
6. **Error** — Backend failure, falling through to upstream

Each state transition is well-defined and tested. The FSM ensures that edge cases —
concurrent requests, backend timeouts, serialization failures — are handled consistently
regardless of which backend or protocol you're using.

## Design philosophy

Hitbox follows a few core principles:

**Don't hide complexity, manage it.** Caching is inherently complex. Rather than hiding
that complexity behind a simple API that breaks in edge cases, Hitbox exposes the
complexity through well-designed abstractions that handle edge cases correctly.

**Composition over configuration.** Instead of a single cache object with dozens of
options, Hitbox provides composable pieces — backends, serializers, key strategies,
middleware layers — that you assemble to match your needs.

**Fail open, always.** A cache failure should never break your application. Hitbox
treats the cache as an optimization layer that can be removed without affecting
correctness.

These principles make Hitbox a platform you can build on, not a library you'll
eventually need to replace.
