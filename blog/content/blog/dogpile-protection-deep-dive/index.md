+++
title = "Dogpile protection deep-dive"
date = 2026-02-07
description = "How Hitbox prevents the thundering herd problem using lock-free broadcast channels, configurable concurrency limits, and a state machine that coordinates cache refreshes across concurrent requests."

[taxonomies]
tags = ["framework", "platform"]
+++

When a popular cache entry expires, every request that arrives before the cache is
refreshed will trigger an upstream call. Under high concurrency, this means hundreds
or thousands of identical requests hitting your database simultaneously. This is the
thundering herd problem — also known as dogpile or cache stampede.

Hitbox solves this at the framework level so you don't have to.

## The problem in numbers

Consider a cache key that serves 500 requests per second with a 60-second TTL. When the
entry expires, it takes 200ms to refresh from the upstream service. During that 200ms
window, 100 requests arrive for the same key. Without protection, all 100 requests hit
the upstream — a 100x amplification.

At scale, this amplification can cascade. The upstream service slows down under load,
increasing the refresh window, which allows even more requests to pile up. A single
expired cache key can trigger a service outage.

## How Hitbox handles it

Hitbox's dogpile protection works through three mechanisms:

### 1. Request coalescing

When the FSM detects a cache miss, it acquires a logical lock for that cache key. The
first request to acquire the lock becomes the "leader" and proceeds to the upstream
service. All subsequent requests for the same key enter the `Locked` state and wait.

```rust
enum CacheState {
    Pending,
    Hit(CachedValue),
    Miss,
    Stale(CachedValue),
    Locked(broadcast::Receiver<CachedValue>),
    Error(CacheError),
}
```

The leader request creates a `broadcast::channel` when it acquires the lock. Waiting
requests receive a `Receiver` handle. When the leader gets a response from upstream, it
stores the value in the cache and broadcasts it to all waiting receivers simultaneously.

### 2. Lock-free implementation

The logical lock isn't a mutex — it's implemented using atomic compare-and-swap operations
on a concurrent hash map. This means:

- No thread blocking: waiters use async channels, not OS-level locks
- No deadlock risk: locks have a configurable timeout
- No contention: different cache keys are completely independent

```rust
struct LockMap {
    locks: DashMap<String, broadcast::Sender<CachedValue>>,
}

impl LockMap {
    fn try_lock(&self, key: &str) -> LockResult {
        match self.locks.entry(key.to_string()) {
            Entry::Vacant(e) => {
                let (tx, _) = broadcast::channel(1);
                e.insert(tx.clone());
                LockResult::Acquired(tx)
            }
            Entry::Occupied(e) => {
                LockResult::Waiting(e.get().subscribe())
            }
        }
    }
}
```

### 3. Stale-while-revalidate

The most elegant solution to dogpile is to never let entries fully expire. With
stale-while-revalidate, Hitbox serves the expired value immediately while refreshing
it in the background.

```rust
let config = CacheConfig::builder()
    .default_ttl(Duration::from_secs(60))
    .max_stale(Duration::from_secs(10))
    .build();
```

With this configuration, entries are "fresh" for 60 seconds and "stale" for an additional
10 seconds. During the stale window:

1. The first request triggers a background refresh
2. All requests (including the first) receive the stale value immediately
3. Once the refresh completes, subsequent requests get the fresh value

This means zero-latency cache refreshes from the client's perspective. The stale data is
at most 10 seconds old — acceptable for the vast majority of use cases.

## Measuring the impact

In a load test with 1,000 concurrent connections requesting the same cache key:

| Metric | Without protection | With protection |
|--------|-------------------|-----------------|
| Upstream requests during refresh | 1,000 | 1 |
| P99 latency during refresh | 2,400ms | 15ms |
| P50 latency during refresh | 800ms | 3ms |
| Error rate during refresh | 12% | 0% |

The error rate without protection comes from upstream connection pool exhaustion. When
1,000 simultaneous requests hit a database connection pool sized for 50, 950 requests
fail immediately.

## Configuration options

Dogpile protection is enabled by default. You can tune its behavior:

```rust
let config = CacheConfig::builder()
    // Disable dogpile protection entirely
    .dogpile_protection(false)

    // Maximum time to wait for a leader request
    .lock_timeout(Duration::from_secs(5))

    // Maximum stale age for stale-while-revalidate
    .max_stale(Duration::from_secs(10))

    // Maximum number of waiters per key (backpressure)
    .max_waiters(1000)
    .build();
```

The `lock_timeout` is a safety valve. If the leader request takes longer than this timeout,
waiters give up and make their own upstream calls. This prevents indefinite blocking if the
upstream service is unresponsive.

The `max_waiters` setting provides backpressure. If more than 1,000 requests are waiting
for the same key, additional requests bypass the cache entirely and go straight to upstream.
This prevents unbounded memory growth from accumulated receivers.

## Edge cases

### Leader failure

What happens if the leader request fails? Hitbox handles this by broadcasting the error
to all waiters, who then each retry independently (respecting the lock again, so a new
leader is elected). The failed leader releases the lock before broadcasting, ensuring no
deadlock.

### Backend unavailability

If the cache backend is unreachable, dogpile protection is effectively disabled — there's
no cache to protect. Requests fall through to upstream normally. When the backend recovers,
protection resumes automatically.

### Hot key detection

Some cache keys are significantly hotter than others. Hitbox tracks the waiter count per
key, which can be used to identify hot keys that might benefit from longer TTLs or
dedicated caching strategies.

## Implementation details

The entire dogpile protection system is implemented in about 200 lines of Rust. It uses
`tokio::sync::broadcast` for the notification channel and `dashmap` for the lock-free
concurrent map. No unsafe code, no OS-level primitives, fully async.

The simplicity is deliberate. Dogpile protection is a critical path — every cache operation
passes through it. Complex implementations introduce subtle bugs under high concurrency.
Hitbox's implementation is simple enough to audit in a single sitting and has been
fuzz-tested with `cargo-fuzz` to verify correctness under chaotic scheduling.
