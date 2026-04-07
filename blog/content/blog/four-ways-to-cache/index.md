+++
title = "Four Ways to Cache in Rust"
date = 2026-04-06
description = "There are a few ways to add caching to a Rust project. This article walks through each approach, explains when to reach for it, and shows how Hitbox fits in."

[taxonomies]
tags = ["caching", "tutorial", "architecture"]

[extra]
og_image = "og/four-ways-to-cache.png"
og_highlight = "Four"
+++

{% tldr() %}
**tl;dr:** Caching can live in four places: as HTTP middleware, as a client-side proxy, as a function wrapper, or as a raw data structure. Each solves a different problem. Hitbox covers the first three; the fourth is what Moka and Redis already do on their own.
{% end %}

There are a few ways to add caching to a project. They look similar on the surface --- all of them store a result and return it later --- but they differ in where the cache sits, what it wraps, and how much of your code it touches.

In this article we'll walk through four approaches, look at each one from the Hitbox perspective, and show a small intro for getting started.

## 1. Cache as HTTP middleware

This is the reverse-proxy approach. Instead of modifying your handlers, you place a caching layer between the client and your service. The layer intercepts requests, checks the cache, and either returns a stored response or forwards the request upstream.

{% note() %}
This is the same idea as enabling cache in NGINX --- but inside your application, with full control over predicates, keys, and TTLs.
{% end %}

In Hitbox, this is the Tower integration. You create a `Cache` layer and attach it to a route. The layer handles everything: cache key generation, storage, hit/miss logic, and response headers.

```rust
use std::time::Duration;

use hitbox::Config;
use hitbox::policy::PolicyConfig;
use hitbox::predicate::PredicateExt;
use hitbox_http::{
    extractors::{MethodConfig, MethodExtractor, query::QueryExtractor},
    predicates::{
        header::{HeaderPredicate, Operation as HeaderOperation},
        response::StatusCodePredicate,
    },
    request, response,
};
use hitbox_moka::MokaBackend;
use hitbox_tower::Cache;

#[tokio::main]
async fn main() {
    let backend = MokaBackend::builder()
        .max_entries(1024 * 1024)
        .build();

    let config = Config::builder()
        .request_predicate(
            // Skip cache when client sends Cache-Control: no-cache
            request::predicate()
                .header(HeaderOperation::Contains(
                    http::header::CACHE_CONTROL,
                    "no-cache".to_string(),
                ))
                .not(),
        )
        .response_predicate(
            // Only cache successful responses
            response::predicate()
                .status(http::StatusCode::OK),
        )
        .extractor(
            request::extractor()
                .method(MethodConfig::new())
                .query("page".to_string())
                .query("limit".to_string()),
        )
        .policy(PolicyConfig::builder()
            .ttl(Duration::from_secs(60))
            .build())
        .build();

    let cache = Cache::builder()
        .backend(backend)
        .config(config)
        .build();

    let app = Router::new()
        .route("/tasks", get(list_tasks).layer(cache))
        .route("/health", get(health));

    // ...
}
```

The handler code stays untouched. Cache configuration --- what to cache, how to build the key, how long to keep it --- lives outside the business logic. And you get the full set of Hitbox features: predicates, extractors, stale-while-revalidate, dogpile prevention, and observability.

This approach works best when you own the service and want transparent caching that wraps the entire request-response cycle without modifying handlers.

For a step-by-step walkthrough with Axum, see [Add Response Caching to Axum in 10 Minutes](/blog/axum-caching-in-10-minutes/). The full example is also available in the [repository](https://github.com/hit-box/hitbox/blob/main/examples/examples/axum.rs).

## 2. Cache as a client-side proxy

This one looks a little unusual, but it is very useful in practice.

{% note() %}
This approach requires no changes to your handler code --- just swap the HTTP client for one with a caching middleware.
{% end %}

Imagine your service makes a request to a third-party API on every incoming request. The data you fetch is shared across all users --- say, a configuration map or a feature-flag set --- but the external call adds significant latency. Your SLA is tight and that extra round-trip makes it hard to stay within bounds.

Here's a concrete scenario: you fetch a lookup table for all users from a remote service, and your own API has per-user endpoints. If you use the middleware approach (option 1), each user that isn't in cache triggers a separate call to the remote service. But the remote service returns the same data regardless of which user you're serving.

The solution is to cache on the client side. Wrap your HTTP client with a caching middleware so it makes only one request per TTL window to the remote service. All subsequent calls within that window return the cached response instantly.

In Hitbox, the `hitbox-reqwest` crate integrates with `reqwest-middleware`:

```rust
use std::time::Duration;

use hitbox::Config;
use hitbox::policy::PolicyConfig;
use hitbox_http::{
    extractors::{MethodConfig, MethodExtractor, PathExtractor},
    predicates::request::MethodPredicate,
    request, response,
};
use hitbox_moka::MokaBackend;
use hitbox_reqwest::CacheMiddleware;
use reqwest::Client;
use reqwest_middleware::ClientBuilder;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let backend = MokaBackend::builder()
        .max_entries(1000)
        .build();

    let config = Config::builder()
        .request_predicate(request::predicate().method(http::Method::GET))
        .response_predicate(response::predicate())
        .extractor(
            request::extractor()
                .method(MethodConfig::new())
                .path("/{path}*"),
        )
        .policy(PolicyConfig::builder()
            .ttl(Duration::from_secs(60))
            .build())
        .build();

    let cache_middleware = CacheMiddleware::builder()
        .backend(backend)
        .config(config)
        .build();

    // Build the reqwest client with caching middleware
    let client = ClientBuilder::new(Client::new())
        .with(cache_middleware)
        .build();

    // First request: cache miss, fetches from the remote service
    let response = client
        .get("https://api.example.com/config")
        .send()
        .await?;

    // Second request: cache hit, no network call
    let response = client
        .get("https://api.example.com/config")
        .send()
        .await?;

    Ok(())
}
```

You don't rewrite your request logic. You swap the HTTP client for one with a caching layer and the cache takes care of the rest. The same predicates, extractors, and policies from the middleware approach work here too.

The full example is in the [repository](https://github.com/hit-box/hitbox/blob/main/examples/examples/reqwest.rs).

## 3. Cache as a function wrapper

This is memoization --- a well-known pattern, especially if you've worked with Python's `@functools.lru_cache` or similar decorators.

{% note() %}
All Hitbox features --- backends, TTL, stale policies --- work with memoized functions too.
{% end %}

You find a function whose result is expensive to compute and doesn't change often, and you wrap it with a cache macro. In Hitbox, the `hitbox-fn` crate provides the `#[cached]` attribute and derive macros for cache key extraction:

```rust
use std::time::Duration;

use hitbox::CacheStatus;
use hitbox_fn::Cache;
use hitbox_fn::prelude::*;
use hitbox_moka::MokaBackend;
use serde::{Deserialize, Serialize};

// Domain types derive KeyExtract for automatic cache key generation
#[derive(Debug, Clone, Copy, KeyExtract)]
pub struct UserId(#[key_extract(name = "user_id")] pub u64);

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, CacheableResponse)]
pub struct UserProfile {
    pub id: u64,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ApiError;

// The #[cached] macro transforms this into a cacheable function
#[cached]
pub async fn get_user(user_id: UserId) -> Result<UserProfile, ApiError> {
    println!("[upstream] fetching user {}", user_id.0);
    Ok(UserProfile {
        id: user_id.0,
        name: format!("User {}", user_id.0),
    })
}

#[tokio::main]
async fn main() {
    let cache = Cache::builder()
        .backend(MokaBackend::builder().max_entries(100).build())
        .policy(PolicyConfig::builder()
            .ttl(Duration::from_secs(60))
            .build())
        .build();

    // First call: executes the function, caches the result
    let (result, ctx) = get_user(UserId(1)).cache(&cache).with_context().await;
    assert_eq!(ctx.status, CacheStatus::Miss);

    // Second call: returns cached result, function body never runs
    let (result, ctx) = get_user(UserId(1)).cache(&cache).with_context().await;
    assert_eq!(ctx.status, CacheStatus::Hit);
}
```

A few things to note:

- `#[derive(KeyExtract)]` on arguments controls which fields become part of the cache key. The `#[key_extract(skip)]` attribute excludes fields like request IDs that shouldn't affect caching.
- `#[derive(CacheableResponse)]` on return types controls serialization. The `#[cacheable_response(skip)]` attribute excludes sensitive fields like access tokens from the cache.
- The `#[cached]` attribute on the function handles the rest --- wrapping the call, checking the cache, storing on miss.

This approach works best for expensive computations or data-fetching functions where you want per-call caching without restructuring your code. All Hitbox features --- pluggable backends, TTL, stale-while-revalidate --- are available through the `Cache` builder.

The full example with more patterns (multi-argument functions, skipped fields, zero-argument functions) is in the [repository](https://github.com/hit-box/hitbox/blob/main/examples/examples/memoization_derive.rs).

## 4. Cache as a data structure

This is probably the first thing most developers think of when they hear "caching": a key-value store. You pick a spot in the code, create a `HashMap` (or a `Cache` from Moka, or a Redis connection), and manually manage `get`, `insert`, and `delete` operations.

```rust
use moka::future::Cache;

async fn get_user(
    cache: &Cache<String, Vec<u8>>,
    user_service: &UserService,
    user_id: u64,
) -> Result<User, AppError> {
    let key = format!("user:{user_id}");

    // Manual cache lookup
    if let Some(bytes) = cache.get(&key).await {
        return Ok(serde_json::from_slice(&bytes)?);
    }

    // Cache miss: fetch, serialize, store
    let user = user_service.get_user(user_id).await?;
    let bytes = serde_json::to_vec(&user)?;
    cache.insert(key, bytes).await;

    Ok(user)
}
```

This gives you maximum control. You decide exactly when to read, when to write, and when to evict. It's the caching equivalent of working with raw sockets instead of an HTTP framework.

{% note() %}
Hitbox doesn't operate at this level --- it's an orchestrator, not a storage engine. For raw key-value access, use Moka or Redis directly.
{% end %}

But it comes with downsides. The caching logic spreads across your codebase, mixed in with business logic. Every handler repeats the same pattern: build a key, check the cache, handle the miss, serialize, store. And as the system grows, you end up reimplementing the features that Hitbox provides out of the box: dogpile prevention, stale-while-revalidate, multi-tier composition, observability.

The difference is similar to using a web framework versus raw TCP sockets. More control, but more work --- and more room for subtle bugs.

**Hitbox doesn't work at this level.** If raw key-value access is what you need, reach for [Moka](https://github.com/moka-rs/moka) or [Redis](https://github.com/redis-rs/redis-rs) directly. For a deeper comparison, see [Should I Use Moka or Hitbox?](/blog/moka-or-hitbox/).

## Comparison

| | HTTP Middleware | Client-Side Proxy | Function Wrapper | Data Structure |
|---|---|---|---|---|
| **Hitbox crate** | `hitbox-tower` | `hitbox-reqwest` | `hitbox-fn` | --- (use Moka/Redis) |
| **What it wraps** | Incoming HTTP requests | Outgoing HTTP requests | Any async function | Nothing (manual) |
| **Code changes** | None (add a layer) | Swap the HTTP client | Add `#[cached]` macro | Inline in every call site |
| **Cache key** | Extractors (path, query, headers) | Extractors (path, method) | `KeyExtract` derive | Manual string building |
| **Predicates** | Request + Response | Request + Response | N/A (cache all calls) | Manual if/else |
| **Dogpile prevention** | Built-in | Built-in | Built-in | Manual |
| **Stale-while-revalidate** | Built-in | Built-in | Built-in | Manual |
| **Backend composition** | L1/L2/L3 | L1/L2/L3 | L1/L2/L3 | Manual |
| **Observability** | Metrics + tracing | Metrics + tracing | Metrics + tracing | Manual |
| **Best for** | API services you own | Expensive external calls | Pure computations | Fine-grained control |

## Choosing an approach

The approaches aren't mutually exclusive. A single service might use HTTP middleware for its public API, a cached reqwest client for calls to external services, and memoization for an expensive internal computation.

Start with the approach that matches where your bottleneck is:

- **Slow API responses** that repeat? HTTP middleware.
- **Slow external dependency** called on every request? Client-side proxy.
- **Expensive function** called with the same arguments? Memoization.
- **Need full manual control** over every cache operation? Data structure.

The first three share the same Hitbox ecosystem --- same backends, same configuration patterns, same observability. Moving between them is a configuration change, not a rewrite.
