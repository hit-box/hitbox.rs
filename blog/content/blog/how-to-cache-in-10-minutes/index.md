+++
title = "How to cache in 10 minutes"
date = 2026-02-10
description = "Highly customizable async caching framework for Rust designed for high-performance applications. Protocol-agnostic async core + first-class HTTP support via hitbox-http. Pluggable backends from in-memory to distributed solutions such as Redis. Built on tower, works with any tokio-based service."

[taxonomies]
tags = ["framework", "guide"]
+++

Getting started with Hitbox is straightforward. In this guide we'll walk through adding
caching to a Rust web service — from zero to production-ready — in about ten minutes.

## Prerequisites

You'll need a working Rust toolchain (1.75+) and a basic familiarity with async Rust.
We'll use Actix Web for the examples, but Hitbox works with any Tower-compatible service.

```bash
cargo add hitbox hitbox-actix hitbox-backend-redis
cargo add actix-web tokio serde --features serde/derive
```

## Step 1: Define a cacheable message

Every cacheable operation in Hitbox starts with a message type. This is any struct that
implements `CacheableRequest`. The trait tells Hitbox how to derive a cache key from the
request and what the response type is.

```rust
use hitbox::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, CacheableRequest)]
#[cache(key = "user:{id}", ttl = 300)]
struct GetUser {
    id: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct User {
    id: u64,
    name: String,
    email: String,
}
```

The `#[cache]` attribute configures the cache key template and time-to-live in seconds.
Hitbox interpolates struct fields into the key at runtime — `GetUser { id: 42 }` produces
the cache key `user:42`.

## Step 2: Create a backend

Hitbox ships with pluggable backends. The in-memory backend is perfect for development and
single-instance deployments. For distributed systems, use the Redis backend.

```rust
use hitbox_backend_redis::RedisBackend;

// In-memory backend for development
let backend = hitbox::InMemoryBackend::new();

// Redis backend for production
let backend = RedisBackend::new("redis://127.0.0.1:6379")
    .await
    .expect("Failed to connect to Redis");
```

Both backends implement the same `Backend` trait, so switching between them requires
changing a single line. No other code changes needed.

## Step 3: Wrap your service

The core of Hitbox is the `CacheLayer` — a Tower layer that intercepts requests and checks
the cache before forwarding to the upstream service.

```rust
use hitbox::CacheLayer;
use tower::ServiceBuilder;

let service = ServiceBuilder::new()
    .layer(CacheLayer::new(backend.clone()))
    .service(upstream_service);
```

For Actix Web, use the dedicated integration crate which provides an actor-based adapter:

```rust
use hitbox_actix::CacheActor;
use actix::prelude::*;

let cache = CacheActor::new(backend).start();

// In your handler
async fn get_user(
    cache: web::Data<Addr<CacheActor<RedisBackend>>>,
    path: web::Path<u64>,
) -> impl Responder {
    let user = cache
        .send(GetUser { id: *path })
        .await
        .unwrap()
        .unwrap();

    web::Json(user)
}
```

## Step 4: Configure TTL and eviction

Hitbox supports per-request TTL configuration through the derive macro, but you can also
set global defaults and override them at runtime.

```rust
use hitbox::CacheConfig;

let config = CacheConfig::builder()
    .default_ttl(Duration::from_secs(60))
    .max_stale(Duration::from_secs(10))
    .lock_timeout(Duration::from_secs(5))
    .build();

let service = ServiceBuilder::new()
    .layer(CacheLayer::with_config(backend, config))
    .service(upstream);
```

The `max_stale` setting enables stale-while-revalidate behavior: when a cache entry expires,
Hitbox can serve the stale value while refreshing it in the background. This dramatically
reduces latency spikes during cache misses.

## Step 5: Enable dogpile protection

One of Hitbox's killer features is built-in dogpile protection. When multiple requests arrive
for the same cache key simultaneously, only one request hits the upstream service. The rest
wait for the result via a broadcast channel.

```rust
let config = CacheConfig::builder()
    .dogpile_protection(true)
    .lock_timeout(Duration::from_secs(5))
    .build();
```

This is enabled by default. Under high concurrency, it prevents the "thundering herd" problem
where hundreds of identical upstream calls fire at once when a popular cache entry expires.

## Step 6: Add cache key strategies

For more complex scenarios, you can implement custom cache key strategies. This is useful when
the cache key depends on runtime context like the authenticated user or request headers.

```rust
use hitbox::CacheKey;

impl CacheKey for GetUserPosts {
    fn cache_key(&self) -> String {
        format!("posts:user:{}:page:{}", self.user_id, self.page)
    }
}
```

You can also use the `CacheKeyPrefix` trait to namespace keys by service or environment:

```rust
impl CacheKeyPrefix for GetUserPosts {
    fn prefix() -> &'static str {
        "blog-service:v2"
    }
}
```

This produces keys like `blog-service:v2:posts:user:42:page:1`, making it easy to invalidate
an entire service's cache during deployments.

## Step 7: Wire it all together

Here's a complete example with Actix Web, Redis, and dogpile protection:

```rust
use actix_web::{web, App, HttpServer};
use hitbox_actix::CacheActor;
use hitbox_backend_redis::RedisBackend;

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let backend = RedisBackend::new("redis://127.0.0.1:6379")
        .await
        .expect("Redis connection failed");

    let cache = CacheActor::new(backend).start();

    HttpServer::new(move || {
        App::new()
            .app_data(web::Data::new(cache.clone()))
            .route("/users/{id}", web::get().to(get_user))
            .route("/users/{id}/posts", web::get().to(get_user_posts))
    })
    .bind("0.0.0.0:8080")?
    .run()
    .await
}
```

That's it. Seven steps, and you have a production-ready caching layer with automatic key
derivation, TTL management, stale-while-revalidate, and dogpile protection.

## What's next

Now that you have basic caching working, consider these next steps:

- **Cache invalidation** — Hitbox supports explicit invalidation via `cache.invalidate(key)`
  and pattern-based invalidation with wildcards
- **Metrics** — The `hitbox-metrics` crate exports Prometheus-compatible counters for hits,
  misses, and latency
- **Serialization** — By default Hitbox uses `bincode` for fast binary serialization, but you
  can plug in `serde_json` or any other format
- **Testing** — Use the `MockBackend` for deterministic unit tests without Redis

Check the [documentation](https://docs.rs/hitbox) for the full API reference, or browse the
[examples](https://github.com/hit-box/hitbox/tree/master/examples) directory on GitHub.
