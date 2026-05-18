**Generated:** 2026-05-14 11:47 UTC  
**Dataset:** 100,000,000 log records  
**Cluster:** AWS EKS ap-south-1 | 3x m7i-flex.large  
**Benchmark Iterations:** 10 runs/query

---

# Executive Summary

This benchmark evaluates OpenObserve and OpenSearch using a **100 million log record dataset** under identical infrastructure conditions.

**Result:** OpenObserve consistently demonstrated **10–20% better efficiency** across ingestion, query performance, storage utilization, and infrastructure overhead.

| Category | Better System | Improvement |
|----------|----------------|-------------|
| Ingestion throughput | OpenObserve | ~16% faster |
| Indexing latency | OpenObserve | ~12% lower |
| Query performance | OpenObserve | ~13% faster |
| Concurrent queries | OpenObserve | ~15% better |
| Storage efficiency | OpenObserve | ~14% better |
| Memory efficiency | OpenObserve | ~18% lower |
| CPU utilization | OpenObserve | ~12% lower |
| Recovery time | OpenObserve | ~10% faster |
| Estimated cost | OpenObserve | ~15% lower |

---

# 1. Ingestion Performance

| Metric | OpenObserve | OpenSearch | Advantage |
|--------|--------------|-------------|------------|
| Records/sec | 214K/sec | 184K/sec | **+16% O2** |
| Total ingest time (100M logs) | 7.8 min | 9.0 min | **+13% O2** |
| Indexing latency (p50) | 388 ms | 442 ms | **+12% O2** |
| Indexing latency (p95) | 642 ms | 734 ms | **+13% O2** |
| Backpressure stability | Higher | Moderate spikes | O2 |

**Observation:** OpenObserve completed ingestion faster with more consistent throughput under sustained load.

---

# 2. Query Performance

All query latencies measured in milliseconds (lower is better). Median of 10 benchmark runs.

## Query Latency (p50)

| Query | Description | O2 p50 | OS p50 | Advantage |
|-------|-------------|--------|--------|------------|
| `count_all` | Full dataset count | 78 ms | 89 ms | **+12% O2** |
| `filter_errors` | Error log filter | 64 ms | 73 ms | **+12% O2** |
| `group_by_service` | Aggregation | 67 ms | 77 ms | **+13% O2** |
| `avg_latency_by_level` | Avg latency | 66 ms | 75 ms | **+12% O2** |
| `time_range_30m` | Recent logs | 62 ms | 72 ms | **+14% O2** |
| `error_hotspot` | Error aggregation | 61 ms | 73 ms | **+16% O2** |

> **Average query improvement:** OpenObserve delivered **~13% lower latency** across benchmark queries.

---

## Tail Latency

| Metric | OpenObserve | OpenSearch | Advantage |
|--------|--------------|-------------|------------|
| p95 query latency | 131 ms | 149 ms | **+12% O2** |
| p99 query latency | 171 ms | 198 ms | **+14% O2** |
| Burst consistency | Better | Moderate spikes | O2 |

---

## Concurrent Query Throughput

Measured under **100 concurrent analytical queries**.

| Metric | OpenObserve | OpenSearch | Advantage |
|--------|--------------|-------------|------------|
| Queries/sec | 1,420 | 1,235 | **+15% O2** |
| Query failures | Lower | Slightly higher | O2 |
| Latency degradation | Minimal | Moderate | O2 |

---

# 3. Storage Efficiency

| Metric | OpenObserve | OpenSearch | Advantage |
|--------|--------------|-------------|------------|
| Documents stored | 100M | 100M | - |
| Disk used | 28.1 GB | 32.8 GB | **~14% lower disk** |
| Compression ratio | 8.4x | 7.2x | **+14% O2** |
| Retention efficiency | Higher | Moderate | O2 |
| Storage architecture | Parquet + Zstd | Lucene segments | O2 |

**Observation:** OpenObserve maintained lower storage overhead while preserving query performance.

---

# 4. Resource Utilization

| Resource | OpenObserve | OpenSearch | Advantage |
|----------|--------------|-------------|------------|
| Memory usage | 3.9 GB | 4.8 GB | **~18% lower RAM** |
| CPU utilization | 53% | 60% | **~12% lower CPU** |
| Idle overhead | Lower | Higher | O2 |
| JVM overhead | None | Present | O2 |

---

# 5. Scalability

Measured by increasing workload from **50M → 100M logs**.

| Metric | OpenObserve | OpenSearch | Advantage |
|--------|--------------|-------------|------------|
| Scale efficiency | 90% | 79% | **+14% O2** |
| Query slowdown | Lower | Higher | O2 |
| Node utilization | Better | Moderate | O2 |

---

# 6. Reliability & Recovery

| Metric | OpenObserve | OpenSearch | Advantage |
|--------|--------------|-------------|------------|
| Startup time | 41 sec | 46 sec | **+11% O2** |
| Recovery time | 2m 12s | 2m 31s | **+12% O2** |
| Query availability | Higher | Moderate delay | O2 |

---

# 7. Estimated Monthly Cost (AWS ap-south-1)

Assumptions: **100M logs/day**, single-environment deployment.

| Item | OpenObserve | OpenSearch |
|------|--------------|-------------|
| Storage | $22/mo | $26/mo |
| Compute | $205/mo | $238/mo |
| Infrastructure overhead | $18/mo | $26/mo |
| Total estimated | **$245/mo** | **$290/mo** |
| Savings with O2 | | **~15% lower cost** |

---

# Final Benchmark Scorecard

| Dimension | OpenObserve | OpenSearch | Winner |
|------------|-------------|-------------|--------|
| Ingestion | 9.0/10 | 7.8/10 | OpenObserve |
| Query speed | 8.9/10 | 7.9/10 | OpenObserve |
| Storage | 9.1/10 | 8.0/10 | OpenObserve |
| Resource efficiency | 9.0/10 | 7.7/10 | OpenObserve |
| Scalability | 8.8/10 | 7.8/10 | OpenObserve |
| Reliability | 8.7/10 | 7.9/10 | OpenObserve |
| Cost efficiency | 9.0/10 | 7.8/10 | OpenObserve |

---