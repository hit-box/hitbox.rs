+++
title = "Welcome to the Hitbox Blog"
date = 2026-02-11
description = "Introducing the official Hitbox blog — a home for architecture deep-dives, release notes, benchmarks and ecosystem news."

[taxonomies]
tags = ["blog"]
+++

We're excited to launch the official Hitbox blog. This is where we'll share everything
happening in the Hitbox ecosystem — from technical deep-dives into cache orchestration
patterns to release announcements and performance benchmarks.

## What is Hitbox?

{% note() %}
Built on Tower and Tokio — works with Actix, Axum, and any async Rust framework.
{% end %}

[Hitbox](https://github.com/hit-box/hitbox) is an async caching framework for Rust
designed for high-performance applications. It provides a protocol-agnostic core with
pluggable backends (in-memory, Redis, and more) and first-class HTTP support via
`hitbox-http` for any Tower-compatible framework.

At its heart, Hitbox uses a **Finite State Machine** to orchestrate cache operations.
Four abstract traits make it extensible to any protocol and storage backend:

```rust
use hitbox::prelude::*;

// Any tower-compatible service can be wrapped with caching
let service = ServiceBuilder::new()
    .layer(CacheLayer::new(backend))
    .service(upstream);
```

## Dogpile protection

{% note() %}
Also known as "thundering herd" or "cache stampede" prevention.
{% end %}

One of Hitbox's standout features is built-in **dogpile protection**. When a cache entry
expires or is missing, multiple simultaneous requests can trigger redundant upstream calls —
the classic "thundering herd" problem. Hitbox uses a configurable concurrency limit per
cache key: additional requests subscribe to a broadcast channel and wait for results
instead of duplicating work.

## What to expect

{% note() %}
New posts every two weeks.
{% end %}

Here's what we're planning to cover on this blog:

- **Architecture deep-dives** — how the FSM works, backend trait design, cache key strategies
- **Release notes** — what's new in each version, migration guides
- **Benchmarks** — performance comparisons, optimization techniques
- **Ecosystem** — integrations with Actix, Axum, and other frameworks
- **Patterns** — real-world caching strategies and anti-patterns

Stay tuned. There's a lot more coming.
