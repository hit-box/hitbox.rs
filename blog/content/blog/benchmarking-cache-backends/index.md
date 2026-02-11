+++
title = "Benchmarking cache backends"
date = 2026-02-04
description = "We benchmarked Hitbox's in-memory and Redis backends under realistic workloads — mixed reads and writes, varying key cardinality, and concurrent access patterns. Here are the numbers."

[taxonomies]
tags = ["benchmark", "platform"]
+++

Performance claims without numbers are just opinions. We ran Hitbox's backends through a
standardized benchmark suite to give you real data for choosing the right backend for
your workload.

## Test setup

All benchmarks ran on an AWS c6i.2xlarge (8 vCPU, 16 GB RAM) with Redis 7.2 on a
separate c6i.xlarge in the same availability zone. Network latency between instances
averaged 0.15ms.

The benchmark tool generates realistic workloads:

- **Read-heavy**: 95% GET, 5% SET (typical API caching)
- **Mixed**: 70% GET, 20% SET, 10% DELETE (content management)
- **Write-heavy**: 40% GET, 50% SET, 10% DELETE (session storage)

Each test runs for 60 seconds with a 10-second warmup. Results are the median of 5 runs.

## Throughput: operations per second

### Read-heavy workload (95/5)

| Concurrency | In-Memory | Redis |
|-------------|-----------|-------|
| 1           | 2,400,000 | 42,000 |
| 10          | 8,100,000 | 380,000 |
| 100         | 9,200,000 | 820,000 |
| 1000        | 9,100,000 | 790,000 |

The in-memory backend is ~11x faster than Redis at high concurrency. This is expected —
no network round-trip, no serialization overhead.

### Mixed workload (70/20/10)

| Concurrency | In-Memory | Redis |
|-------------|-----------|-------|
| 1           | 1,800,000 | 38,000 |
| 10          | 5,900,000 | 340,000 |
| 100         | 6,800,000 | 720,000 |
| 1000        | 6,700,000 | 690,000 |

Write operations are more expensive for both backends. The in-memory backend uses
`DashMap` which handles concurrent writes efficiently through sharded locking.

## Latency: P50 and P99

### Read-heavy at 100 concurrent connections

| Backend   | P50    | P99    | P99.9  |
|-----------|--------|--------|--------|
| In-Memory | 8μs    | 24μs   | 89μs   |
| Redis     | 110μs  | 340μs  | 1.2ms  |

Sub-microsecond P50 is achievable with the in-memory backend when the working set fits
in CPU cache. The Redis P99 is dominated by network latency and occasional GC pauses.

## Key cardinality impact

We tested with 1K, 100K, and 10M unique keys to measure how cardinality affects
performance:

| Keys  | In-Memory ops/s | In-Memory P99 | Redis ops/s | Redis P99 |
|-------|----------------|---------------|-------------|-----------|
| 1K    | 9,200,000      | 24μs          | 820,000     | 340μs     |
| 100K  | 8,800,000      | 31μs          | 810,000     | 360μs     |
| 10M   | 7,100,000      | 58μs          | 780,000     | 390μs     |

The in-memory backend shows ~23% throughput degradation at 10M keys due to increased
hash map overhead and reduced CPU cache effectiveness. Redis is remarkably stable
across cardinalities.

## Memory usage

| Keys  | In-Memory (RSS) | Redis (used_memory) |
|-------|-----------------|---------------------|
| 1K    | 12 MB           | 8 MB                |
| 100K  | 89 MB           | 64 MB               |
| 10M   | 6.2 GB          | 4.8 GB              |

Redis is more memory-efficient due to its optimized data structures. The in-memory
backend stores Rust structs directly, which includes alignment padding and `Vec`
capacity overhead.

## Dogpile protection overhead

We measured the cost of dogpile protection under contention — 100 concurrent requests
for the same expired key:

| Metric                    | Without protection | With protection |
|---------------------------|-------------------|-----------------|
| Upstream requests         | 100               | 1               |
| Total wall time           | 2,100ms           | 215ms           |
| P99 client latency        | 2,050ms           | 210ms           |
| Memory per waiting request | N/A              | 128 bytes       |

The broadcast channel adds 128 bytes per waiting request — negligible. The latency
improvement is dramatic because the upstream service isn't overloaded.

## Recommendations

**Use in-memory when:**
- Single-instance deployment or per-instance caching is acceptable
- Sub-millisecond latency is required
- Working set fits comfortably in RAM
- Cache consistency across instances isn't needed

**Use Redis when:**
- Multiple app instances need shared cache state
- Cache should survive app restarts
- Working set exceeds single-instance RAM
- You need pattern-based invalidation across services

**Use both (L1 + L2) when:**
- You need sub-millisecond latency AND cross-instance consistency
- Hot keys benefit from local caching, long tail from shared cache
- You're willing to accept brief inconsistency between L1 and L2

The two-tier approach gives you the best of both worlds at the cost of slightly more
complex invalidation logic. Hitbox's `TieredBackend` handles this composition for you.
