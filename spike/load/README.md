# Load spike (#3)

Does one database node, with the model in `.design/wallet-core.md`, sustain 1,500 operations/s with payment p99 ≤ 300 ms and keep every invariant under concurrency?

**Answer:** it **sustains the peak with about 5× headroom**, and the model stays as it is. There were zero invariant violations in every run.

The issue also asked for bursts of 7,600/s. That target was dropped on 2026-11-17 as not a business need: it is the largest batch second × 100, so it assumes every customer's batch lands in the same second. The burst runs below are kept as measurements only.

## Database

**PostgreSQL 17** is chosen. It meets the four requirements directly:

- conditional `UPDATE ... WHERE balance - x + credit_limit >= 0`;
- multi-row transactions;
- a unique key on an unpartitioned `idempotency_key` table;
- `DETACH PARTITION CONCURRENTLY` plus `DROP` for old months.

**TigerBeetle** is discarded. It does the limit check and idempotent ids natively and is much faster. But its fixed account/transfer shape has no place for:

- the stored response and request hash;
- a per-wallet `seq`;
- a per-customer key that expires after 30 days;
- dropping a month.

All of that would live in a second database, and an operation would no longer be one transaction.

## Layout

| Path | What |
|---|---|
| `docker-compose.yml` | One node, `synchronous_commit` and `fsync` left on |
| `sql/01_schema.sql` | Tables, monthly partitions |
| `sql/02_operations.sql` | `topup`, `payment`, `transfer`, `reversal`, one transaction each |
| `sql/03_seed.sql` | 100 customers, 1M wallets, ~6M operations Aug–Nov, 11.6M idempotency keys |
| `sql/04_indexes.sql` | Every index the write path maintains |
| `sql/05_maintenance.sql` | Key pruning and month archiving |
| `sql/checks.sql` | The invariants; every count must be 0 |
| `bench/*.sql` | pgbench scripts, one per operation or profile |
| `scripts/setup.sh` | Rebuild from scratch (~2 min) |
| `scripts/scenario.sh` | `warmup`, `sustained`, `burst`, `ceiling`, `race`, `prune`, `archive` |
| `scripts/analyze.py` | p50/p95/p99 per script from pgbench logs, by time window |

Reproduce with `scripts/setup.sh`, then `scripts/scenario.sh warmup`, then any scenario, then `docker exec -i tourist-spike-db psql -U wallet -d wallet < sql/checks.sql`.

The organic mix is 60% payment, 22% top-up, 5% transfer, 4% reversal of the client's last payment, 5% retry of the last payment with the same key, 2% shared keys across clients, and 2% the near-limit wallets. Latency is measured by pgbench from each transaction's scheduled start, so it includes queueing.

## Environment and its limits

- One laptop: Intel i5-1235U (2 performance + 8 efficiency cores, 12 threads), 15 GB RAM, NVMe, Docker.
- pgbench runs on the same CPU as PostgreSQL. A server-class node would score higher, so read the ceiling as a floor.
- 1M wallets and 18M entry rows online. Production would hold ~113M wallets and ~1.5B entry rows over 24 months, so index depth and cache hit rate are better here than they would be there.
- 4 monthly partitions online, not 24. This matters to reversal, which probes every partition (see Findings).

## Results

| Measurement | Result |
|---|---|
| Sustained 1,500/s for 300 s, 32 connections | 1,500/s served, 0 failures. Payment p50 1.0 ms, **p99 1.8 ms**, max 68 ms. All operations p99 1.9 ms |
| Batch wallet at 70 writes/s, alongside the sustained run | p99 2.0 ms, max 121 ms. Any backend waiting on a lock in 0.1% of 3,000 samples (every 100 ms); at most 4 waiters on the batch wallet at once. **Lock wait does not dominate** |
| Ceiling, unthrottled organic mix, by connection count | 8: 6,671/s (p99 2.3 ms) · 12: **7,661/s** (p99 3.0 ms) · 16: 7,394/s · 24: 7,678/s (p99 7.1 ms) · 32: 7,274/s · 64: 6,308/s (p99 35 ms) |
| Burst 7,600/s for 10 s on top of 1,500/s, burst on 96 connections (no longer a target) | ~5,100/s served. Organic p99 rises to **1.9 s** during the burst; burst callers p99 4.0 s |
| Same burst, burst traffic on its own 12-connection pool (no longer a target) | ~7,000/s served at peak. Organic p99 **9.1 ms** during the burst; burst callers queue, p99 1.7 s. Backlog gone 1 s after the burst ends |
| Race: 32 connections unthrottled on 20 wallets with `credit_limit` 1,000, plus 20 shared keys | 7,869/s. Balances reached exactly `-credit_limit` and never beyond. 141k in-flight duplicates on 20 keys: 20 operations |
| Idempotency across the month boundary | Key written at Oct 31 23:59:59.9, retried at Nov 1 00:00:00.1: original response returned, nothing written |
| Pruning 1.8M expired keys (one day at 100×), batched `DELETE` of 5,000, under 1,500/s | 12.6 s, 361 batches. Payment p99 **2.5 ms** during, 3.0 ms before |
| Archiving August (287,577 wallets touched) under 1,500/s | 8.2 s total: wallet `archived_balance`/`archived_seq` 7.3 s in batches of 10,000; counterpart totals 0.7 s; detach 19 ms; drop 137 ms. Payment p99 **2.5 ms** during; one transaction took 1.4 s, most likely queued behind a batch's row locks |
| Invariants, after all of the above (9.4M operations, 18.6M entries online, August dropped) | **0 violations** on all 11 checks (`results/checks-final.txt`). The checks were confirmed to fail on injected bugs |

`results/prune-during-host-apt` is a discarded run: the host was installing packages, and payment p99 was 58 ms before pruning started.

### What limits the ceiling

At 64 connections the CPU was 95% busy. The top waits were `LWLock:BufferContent`, then `LWLock:WALWrite`. Experiments on the 64-connection ceiling, one change each:

| Change | Ceiling | Waits |
|---|---|---|
| none | 6,308/s | BufferContent 622, WALWrite 420 |
| drop the entry PK and the key `created_at` index | 6,530/s (+3.5%) | unchanged |
| `CACHE 100` on the id sequences | 6,296/s | BufferContent 537 → 71; WALWrite now first |
| `wal_compression = lz4` (with the cache) | 6,392/s | unchanged |
| 12–24 connections instead of 64 | **7,661/s** | — |

The sequence cache is kept in the schema: it removes the contention, though not the CPU limit. `wal_compression` is not kept. WAL was ~11 KB per payment just after a checkpoint, mostly full-page images of randomly touched wallet and key-index pages. The lever that matters is the number of active connections.

The vmstat and wait-sample files from the first 64-connection ceiling run were overwritten; the figures above come from the session that ran it.

## Findings for the model

1. **Invariant 5 breaks when a month is dropped** unless the counterpart side is archived too. Added `ledger_account.archived_total` and `archive_state.online_from`, written once per archived month in one transaction. Neither is on the write path, so D2 still holds where it matters.
2. **The archive boundary is by `seq`, not by partition.** `created_at` is the transaction's start time. A transaction that started first can take the wallet lock second, so at a month boundary a wallet's `seq` order and its partitions can disagree. Invariants 2 and 3 count only entries with `seq > archived_seq`, which stays exact and holds at every step of the archive.
3. **D5's "unique per account" cannot be a database constraint.** On a partitioned table a unique index must include `created_at`, the same trap as D4's Careful. Gapless `seq` rests on the wallet row lock, and invariant 2 checks it.
4. **Counterpart order by `entry_id` is approximate.** With cached sequences, and even without them, ids are not in commit order across sessions.
5. **A reversal finds its original by id alone**, so it probes every online partition. That was fine with 4 partitions (reversal p99 2.9 ms) and is unmeasured with 24. A month hint in the request, or an id that encodes the month, would fix it.
6. **Rejection reasons are read after the failed update**, so under a race a few are labelled `concurrent_change`: 480 of 81k in the race run. The decision itself is always right; the Payment spec should take the reason from the statement.
7. **Keep active connections few.** Throughput peaks at 12–24 active connections on 12 threads, and falls ~18% at 64. The high-level design should size the pool to the cores, not to the callers.
