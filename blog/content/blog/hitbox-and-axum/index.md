+++
title = "Hitbox and Axum"
date = 2026-02-05
description = "Axum is becoming the default choice for new Rust web services. Here is how to integrate Hitbox caching into an Axum application using Tower layers, with examples for route-level and extractor-based caching."

[taxonomies]
tags = ["framework", "guide"]
+++

Axum and Hitbox are a natural fit. Both are built on Tower, so Hitbox's `CacheLayer`
plugs directly into Axum's middleware stack. No adapters, no glue code.

## Basic setup

Add the dependencies:

```bash
cargo add hitbox hitbox-tower
cargo add axum tokio serde --features serde/derive
```

Create a cached Axum service in a few lines:

```rust
use axum::{Router, routing::get, extract::Path};
use hitbox::CacheLayer;
use hitbox::InMemoryBackend;

#[tokio::main]
async fn main() {
    let backend = InMemoryBackend::new();

    let app = Router::new()
        .route("/users/:id", get(get_user))
        .layer(CacheLayer::new(backend));

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000")
        .await
        .unwrap();
    axum::serve(listener, app).await.unwrap();
}
```

The `CacheLayer` wraps the entire router. Every request that implements `CacheableRequest`
will be cached automatically. Requests without a cache implementation pass through
unchanged.

## Route-level caching

Sometimes you want caching on specific routes, not the whole app. Axum's `Router::layer`
method supports per-route middleware:

```rust
let cached_routes = Router::new()
    .route("/products/:id", get(get_product))
    .route("/categories", get(list_categories))
    .layer(CacheLayer::new(backend.clone()));

let uncached_routes = Router::new()
    .route("/cart", get(get_cart).post(update_cart))
    .route("/checkout", post(checkout));

let app = Router::new()
    .merge(cached_routes)
    .merge(uncached_routes);
```

Product listings and categories are cached. Cart and checkout — which are user-specific
and mutation-heavy — skip the cache entirely.

## Extractor-based caching

For finer control, use Hitbox as an Axum extractor. This lets you cache at the handler
level with full access to request context:

```rust
use hitbox::CacheHandle;

async fn get_user(
    Path(id): Path<u64>,
    cache: CacheHandle,
) -> Json<User> {
    let user = cache
        .get_or_insert(
            format!("user:{id}"),
            Duration::from_secs(300),
            || async { fetch_user_from_db(id).await },
        )
        .await
        .unwrap();

    Json(user)
}
```

The `get_or_insert` pattern is familiar if you've used `HashMap::entry`. Check the cache
first; if missing, run the closure and store the result. Dogpile protection is built in —
concurrent calls for the same key coalesce automatically.

## Configuration per route

Different routes have different caching needs. A product page might cache for 5 minutes,
while a search result caches for 30 seconds:

```rust
let product_cache = CacheLayer::with_config(
    backend.clone(),
    CacheConfig::builder()
        .default_ttl(Duration::from_secs(300))
        .build(),
);

let search_cache = CacheLayer::with_config(
    backend.clone(),
    CacheConfig::builder()
        .default_ttl(Duration::from_secs(30))
        .max_stale(Duration::from_secs(5))
        .build(),
);

let app = Router::new()
    .route("/products/:id", get(get_product))
    .layer(product_cache)
    .route("/search", get(search))
    .layer(search_cache);
```

## Error handling

Hitbox integrates with Axum's error handling. Cache backend failures don't return 500
errors — they fall through to the upstream handler. You can observe failures through
metrics or by adding a custom error hook:

```rust
let config = CacheConfig::builder()
    .on_error(|err| {
        tracing::warn!("cache error: {err}");
    })
    .build();
```

This keeps your service available even when Redis is down, while giving you visibility
into cache health.

## Testing

Hitbox provides a `MockBackend` for testing cached handlers without a running Redis:

```rust
#[tokio::test]
async fn test_cached_handler() {
    let backend = MockBackend::new();
    let app = create_app(backend.clone());

    let response = app
        .oneshot(Request::get("/users/1").body(Body::empty()).unwrap())
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(backend.get_count("user:1"), 1);

    // Second request hits cache
    let response = app
        .oneshot(Request::get("/users/1").body(Body::empty()).unwrap())
        .await
        .unwrap();

    assert_eq!(backend.get_count("user:1"), 1); // no new upstream call
    assert_eq!(backend.hit_count("user:1"), 1);
}
```

The `MockBackend` tracks all operations, making it easy to assert caching behavior in
your test suite.
