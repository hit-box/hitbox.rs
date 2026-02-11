+++
title = "Cache key strategies"
date = 2026-02-06
description = "Choosing the right cache key granularity is one of the most impactful decisions in a caching system. Too coarse and you waste memory storing duplicate data. Too fine and your hit rate drops to near zero."

[taxonomies]
tags = ["guide", "platform"]
+++

The cache key is the single most important design decision in any caching layer. It
determines what gets cached, how often it hits, and how hard it is to invalidate. Hitbox
gives you full control over key generation through the `CacheKey` trait and the derive
macro.

## The basics

At its simplest, a cache key is a string that uniquely identifies a cached value. Hitbox
derives keys from your request structs using field interpolation:

```rust
#[derive(CacheableRequest)]
#[cache(key = "user:{id}", ttl = 300)]
struct GetUser {
    id: u64,
}
```

The request `GetUser { id: 42 }` produces the key `user:42`. Simple, predictable,
debuggable.

## Compound keys

Real-world requests often depend on multiple parameters. Hitbox supports compound keys
with multiple field references:

```rust
#[derive(CacheableRequest)]
#[cache(key = "search:{query}:cat:{category}:p:{page}", ttl = 60)]
struct SearchProducts {
    query: String,
    category: String,
    page: u32,
}
```

The key `search:shoes:cat:footwear:p:2` captures all the parameters that affect the
response. Change any parameter and you get a different cache entry.

## Key prefixing

In multi-service architectures, key collisions between services can cause subtle bugs.
Hitbox supports key prefixes to namespace your cache:

```rust
impl CacheKeyPrefix for GetUser {
    fn prefix() -> &'static str {
        "user-service:v3"
    }
}
```

This produces keys like `user-service:v3:user:42`. During deployments, bumping the
version prefix effectively invalidates the entire service's cache without touching Redis.

## Granularity tradeoffs

**Coarse keys** (e.g., `catalog:all`) cache entire datasets. High hit rate, but any change
invalidates everything. Good for data that changes infrequently and is always requested
as a whole.

**Fine keys** (e.g., `product:42:price:usd:warehouse:east`) cache individual values. Low
memory waste, precise invalidation, but lower hit rates. Good for data that's requested
in many different combinations.

**Medium keys** (e.g., `catalog:footwear:page:1`) balance both. This is where most
production systems land. Cache at the API response level, organized by the parameters
that users actually vary.

## Custom key logic

When the derive macro isn't expressive enough, implement `CacheKey` directly:

```rust
impl CacheKey for GetRecommendations {
    fn cache_key(&self) -> String {
        let mut hasher = DefaultHasher::new();
        self.user_segment.hash(&mut hasher);
        self.preferences.hash(&mut hasher);
        format!("recs:{:x}", hasher.finish())
    }
}
```

Hashing is useful when key components are large (like preference vectors) or when you
want to normalize keys to avoid near-duplicates.

## Invalidation patterns

Your key strategy directly determines your invalidation options:

- **Exact invalidation**: `cache.invalidate("user:42")` — requires knowing the exact key
- **Pattern invalidation**: `cache.invalidate_pattern("user:42:*")` — requires hierarchical keys
- **Tag-based invalidation**: associate keys with tags, invalidate all keys with a given tag
- **TTL expiration**: no explicit invalidation needed, just wait

The best strategy depends on your consistency requirements. Most teams use TTL as the
primary mechanism and add explicit invalidation for writes that need immediate visibility.

## Measuring key effectiveness

Hitbox exposes per-key metrics that help you evaluate your key strategy:

- **Hit rate per key pattern**: are your keys too granular?
- **Key cardinality**: how many unique keys exist? High cardinality means high memory usage
- **TTL distribution**: are entries expiring before they're reused?

A well-designed key strategy shows hit rates above 80% with stable cardinality. If
cardinality grows linearly with traffic, your keys might include request-specific data
(like timestamps or session IDs) that shouldn't be part of the key.
