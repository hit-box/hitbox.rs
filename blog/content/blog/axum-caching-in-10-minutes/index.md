+++
title = "Add Response Caching to Axum in 10 Minutes"
date = 2026-02-16
description = "A step-by-step guide to adding transparent HTTP response caching to your Axum application using Hitbox — from zero to cached in under 10 minutes."

[taxonomies]
tags = ["tutorial", "axum", "caching"]
+++

Your Axum API hits the database on every request. The same query, the same result,
hundreds of times per second. Let's fix that.

In this article we'll add transparent response caching to an Axum application using
Hitbox. No changes to your handlers. No manual cache invalidation. Just a Tower layer
that sits between the client and your service.

## The API

{% note() %}
Full source code is in the [examples directory](https://github.com/hit-box/hitbox/tree/master/examples).
{% end %}

We're building a product catalog API. Two endpoints:

- `GET /products` — list products with pagination and category filtering
- `GET /products/:id` — get product details by ID

Here's the starting point — pure Axum, no caching:

```rust
use axum::{
    Json, Router,
    extract::{Path, Query},
    routing::get,
};
use serde::{Deserialize, Serialize};

// ── Domain types ────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize)]
struct Product {
    id: u32,
    name: String,
    category: String,
    price_cents: u32,
}

#[derive(Debug, Clone, Serialize)]
struct ProductList {
    products: Vec<Product>,
    total: u32,
    page: u32,
}

#[derive(Debug, Deserialize)]
struct ListParams {
    #[serde(default = "default_page")]
    page: u32,
    #[serde(default = "default_limit")]
    limit: u32,
    category: Option<String>,
}

fn default_page() -> u32 { 1 }
fn default_limit() -> u32 { 20 }

// ── Handlers ────────────────────────────────────────────────────────

async fn list_products(Query(params): Query<ListParams>) -> Json<ProductList> {
    // In a real app this queries a database
    tracing::info!("DB query: products page={}, category={:?}",
        params.page, params.category);

    let products = db::find_products(params.category.as_deref(),
        params.page, params.limit);
    let total = db::count_products(params.category.as_deref());

    Json(ProductList { products, total, page: params.page })
}

async fn get_product(
    Path(id): Path<u32>,
) -> Result<Json<Product>, http::StatusCode> {
    tracing::info!("DB query: product id={}", id);

    db::find_product(id)
        .map(Json)
        .ok_or(http::StatusCode::NOT_FOUND)
}

async fn health() -> &'static str { "OK" }

// ── Router ──────────────────────────────────────────────────────────

#[tokio::main]
async fn main() {
    let app = Router::new()
        .route("/products", get(list_products))
        .route("/products/{id}", get(get_product))
        .route("/health", get(health));

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000")
        .await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
```

Every request runs a database query. `GET /products?page=1` — query. Same request
one second later — same query, same result. Let's fix that.

## The cache layer

{% note() %}
Hitbox is modular — pick only the crates you need.
{% end %}

First, add Hitbox to your `Cargo.toml`:

```toml
# Hitbox caching
hitbox = "0.2"
hitbox-tower = "0.2"
hitbox-http = "0.2"
hitbox-moka = "0.2"
```

Four crates, each with a clear role:

| Crate | Role |
|-------|------|
| `hitbox` | Core: config, policies, predicate traits |
| `hitbox-tower` | `Cache` layer for Tower/Axum |
| `hitbox-http` | HTTP-aware predicates and extractors |
| `hitbox-moka` | In-memory backend ([Moka](https://github.com/moka-rs/moka) — lock-free, sub-microsecond) |

Now create a backend and the simplest possible cache:

```rust
use std::time::Duration;
use hitbox::Config;
use hitbox::policy::PolicyConfig;
use hitbox_moka::MokaBackend;
use hitbox_tower::Cache;

#[tokio::main]
async fn main() {
    // 1. Create an in-memory backend
    let backend = MokaBackend::builder()
        .max_entries(10_000)
        .build();

    // 2. Build a cache config with a 60-second TTL
    let config = Config::builder()
        .policy(PolicyConfig::builder()
            .ttl(Duration::from_secs(60))
            .build())
        .build();

    // 3. Create a Cache layer
    let cache = Cache::builder()
        .backend(backend)
        .config(config)
        .build();

    // 4. Apply it to a route
    let app = Router::new()
        .route("/products", get(list_products).layer(cache))
        .route("/products/{id}", get(get_product))
        .route("/health", get(health));

    // ...
}
```

That's a working cache. First request hits your handler, response gets stored. Second
request gets the stored response — your handler is never called. After 60 seconds the
entry expires and the cycle repeats.

Hitbox adds an `x-cache-status` header to every response so you can see what happened:

```sh
curl -v http://localhost:3000/products
# < x-cache-status: MISS    — first request, hit your handler

curl -v http://localhost:3000/products
# < x-cache-status: HIT     — served from cache, handler not called
```

But there's a problem. Try requesting a negative page number:

```sh
curl -v http://localhost:3000/products?page=-1
# < HTTP/1.1 400 Bad Request

curl -v http://localhost:3000/products?page=1
# < HTTP/1.1 400 Bad Request  ← cached error!
```

Your handler correctly rejected `page=-1` with a `400 Bad Request` — but Hitbox cached
that error. Now every request to `/products` returns the cached 400 for the next 60
seconds. We need to tell Hitbox **what** to cache and what to let pass through.

## Predicates: control what gets cached

{% note() %}
Predicates compose with `.and()`, `.or()`, and `.not()` — like building a filter chain.
{% end %}

A **predicate** is a rule that decides whether a request or response is cacheable.
Hitbox evaluates predicates before storing anything. If a predicate says "no", the
response passes through uncached.

There are two kinds:

- **Request predicates** — evaluated before checking the cache. "Should we even look
  for a cached response?"
- **Response predicates** — evaluated after your handler runs. "Should we store this
  response?"

The fix for our problem: add a response predicate that only caches `200 OK`:

```rust
use hitbox::predicate::PredicateExt;
use hitbox_http::predicates::response::StatusCode as ResponseStatusCode;

let config = Config::builder()
    .response_predicate(
        // Only cache 200 OK responses.
        // 400s, 404s, 500s — everything else passes through uncached.
        ResponseStatusCode::new(http::StatusCode::OK),
    )
    .policy(PolicyConfig::builder()
        .ttl(Duration::from_secs(60))
        .build())
    .build();
```

Now errors never enter the cache. A `400 Bad Request` or `404 Not Found` goes straight
to the client without being stored.

Predicates compose. Want to cache both `200` and `304` responses?

```rust
let predicate = ResponseStatusCode::new(http::StatusCode::OK)
    .or(ResponseStatusCode::new(http::StatusCode::NOT_MODIFIED));
```

The `.and()`, `.or()`, and `.not()` combinators let you build complex rules from
simple building blocks.

With the error caching problem solved, there's still the pagination issue:

```sh
curl http://localhost:3000/products?page=1  # MISS — returns page 1, cached
curl http://localhost:3000/products?page=2  # HIT  — returns page 1 again!
```

Both requests hit the same cache entry because Hitbox doesn't know that `page` matters.
That's what extractors fix.

## Extractors: smart cache keys

{% note() %}
Without an extractor, all requests to the same path share one cache entry.
{% end %}

Right now `/products?page=1` and `/products?page=2` return the same cached response.
That's because the default cache key doesn't include query parameters. An **extractor**
tells Hitbox which parts of the request to include in the cache key.

### Product list — keyed by query params

```rust
use hitbox_http::extractors::{
    Method as MethodExtractor,
    query::QueryExtractor as QueryExtractorTrait,
};

let list_config = Config::builder()
    .response_predicate(ResponseStatusCode::new(http::StatusCode::OK))
    .extractor(
        // Cache key = HTTP method + query params
        MethodExtractor::new()
            .query("page".to_string())
            .query("limit".to_string())
            .query("category".to_string()),
    )
    .policy(PolicyConfig::builder()
        .ttl(Duration::from_secs(60))
        .build())
    .build();
```

Now each combination of `page`, `limit`, and `category` gets its own cache entry:

```sh
curl http://localhost:3000/products?page=1          # MISS → cached as key A
curl http://localhost:3000/products?page=2          # MISS → cached as key B
curl http://localhost:3000/products?page=1          # HIT  → returns key A
curl http://localhost:3000/products?category=tools  # MISS → cached as key C
```

### Product details — keyed by path segment

For `/products/{id}`, we need the product ID in the cache key. Use a path extractor:

```rust
use hitbox_http::extractors::path::PathExtractor;

let details_config = Config::builder()
    .response_predicate(ResponseStatusCode::new(http::StatusCode::OK))
    .extractor(
        // Cache key = HTTP method + product ID from path
        MethodExtractor::new().path("/products/{id}"),
    )
    .policy(PolicyConfig::builder()
        .ttl(Duration::from_secs(300))  // Details change less often
        .build())
    .build();
```

The `.path("/products/{id}")` pattern extracts `{id}` from the URL. Product 1 and
product 2 get separate cache entries, each valid for 5 minutes.

Wire both configs into the router:

```rust
let list_cache = Cache::builder()
    .backend(backend.clone())
    .config(list_config)
    .build();

let details_cache = Cache::builder()
    .backend(backend.clone())
    .config(details_config)
    .build();

let app = Router::new()
    .route("/products", get(list_products).layer(list_cache))
    .route("/products/{id}", get(get_product).layer(details_cache))
    .route("/health", get(health));
```

Each route gets its own cache config with its own TTL, extractors, and predicates.
The `/health` endpoint has no cache layer — it always hits the handler.

## Auth-aware caching

{% note() %}
Header extractors support regex value extraction and transform chains — extract what
you need, hash what's sensitive.
{% end %}

Your API has authenticated endpoints. Users send `Authorization` headers with their
credentials. You want each user to get their own cache — but you don't want raw
tokens sitting in your cache keys.

### Simple: full header value

The quickest approach — add the `Authorization` header to the cache key with
`.header()`:

```rust
use hitbox_http::extractors::header::HeaderExtractor;

let config = Config::builder()
    .response_predicate(ResponseStatusCode::new(http::StatusCode::OK))
    .extractor(
        MethodExtractor::new()
            .query("page".to_string())
            .query("limit".to_string())
            .query("category".to_string())
            .header("authorization".to_string()),
    )
    .policy(PolicyConfig::builder()
        .ttl(Duration::from_secs(60))
        .build())
    .build();
```

Now user A and user B each get their own cache entries. Anonymous requests (no header)
share a separate entry. But the full `Authorization` value — including the raw token —
ends up in the cache key. We can do better.

### Transforms: hash sensitive values

Use `Header::new_with` for full control over extraction. Add `Transform::Hash` to
SHA256-hash the value before it enters the cache key:

```rust
use hitbox_http::extractors::header::{
    Header, NameSelector, ValueExtractor, Transform,
};

let extractor = Header::new_with(
    MethodExtractor::new()
        .query("page".to_string())
        .query("limit".to_string())
        .query("category".to_string()),
    NameSelector::Exact("authorization".to_string()),
    ValueExtractor::Full,
    vec![Transform::Hash],
);

let config = Config::builder()
    .response_predicate(ResponseStatusCode::new(http::StatusCode::OK))
    .extractor(extractor)
    .policy(PolicyConfig::builder()
        .ttl(Duration::from_secs(60))
        .build())
    .build();
```

`Transform::Hash` produces a truncated SHA256 (16 hex characters). Different tokens
produce different cache keys, but the actual token never appears in the key. Good for
security audits, good for logging.

### Value extraction: pull out what matters

Sometimes you don't need the whole header value. `ValueExtractor::Regex` extracts
just the part you care about using a capture group.

For Bearer tokens — extract the token part, then hash it:

```rust
use regex::Regex;

let extractor = Header::new_with(
    MethodExtractor::new()
        .query("page".to_string()),
    NameSelector::Exact("authorization".to_string()),
    // "Bearer eyJhbG..." → captures "eyJhbG..."
    ValueExtractor::Regex(Regex::new(r"Bearer (.+)").unwrap()),
    vec![Transform::Hash],
);
```

Transforms chain — each one applies to the output of the previous, left to right.
Normalize before hashing for case-insensitive matching:

```rust
vec![Transform::Lowercase, Transform::Hash]
```

## Cache-Control: let clients decide

{% note() %}
RFC 9111 defines `Cache-Control: no-cache` — the client asks for a fresh response.
{% end %}

Sometimes a client needs fresh data. An admin refreshing a dashboard, a CI pipeline
fetching the latest state. HTTP already has a standard for this: the `Cache-Control`
header.

Add a request predicate that respects `Cache-Control: no-cache`:

```rust
let config = Config::builder()
    .request_predicate(
        RequestHeader::new(HeaderOperation::Contains(
            http::header::CACHE_CONTROL,
            "no-cache".to_string(),
        ))
        .not(),
    )
    // ... rest of config
    .build();
```

The pattern: match the header, invert with `.not()`. If the client sends
`Cache-Control: no-cache`, the cache is bypassed:

```sh
# Normal request — served from cache
curl http://localhost:3000/products
# < x-cache-status: HIT

# Force fresh response
curl -H 'Cache-Control: no-cache' http://localhost:3000/products
# < x-cache-status: MISS
```

Your API now speaks the HTTP caching language. Clients that need control have it.
Clients that don't send the header get fast cached responses.

## Full example

The complete product catalog API with all the caching patterns from this article is
available as a runnable example:
[`examples/axum-products.rs`](https://github.com/hit-box/hitbox/tree/master/examples/examples/axum-products.rs).

## What's next

{% note() %}
Everything in Hitbox composes — backends, predicates, extractors.
Mix and match to fit your architecture.
{% end %}

This article covered the core concepts: backends, predicates, and extractors.
Hitbox can do more:

- **Different backends** — Replace `hitbox-moka` with `hitbox-redis` for distributed
  caching across multiple instances. Same builder API, shared cache.
- **Backend composition** — Combine backends into layered caches. Local Moka in front
  of remote Redis — L1/L2 caching with configurable promotion policies.
- **Body predicates and extractors** — Cache based on response body content. For
  example, skip caching empty product lists or extract cache keys from JSON payloads.
- **Stale-while-revalidate** — Serve stale data instantly while refreshing in the
  background with `PolicyConfig::builder().stale(Duration::from_secs(300))`.
- **Dogpile prevention** — When a cache entry expires, only one request triggers
  the upstream call. The rest subscribe to a broadcast channel and wait for the
  result. Built in, no configuration needed.

Check the [documentation](https://docs.rs/hitbox) and the
[examples directory](https://github.com/hit-box/hitbox/tree/master/examples) for the
full feature set.
