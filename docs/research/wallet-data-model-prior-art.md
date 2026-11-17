# Wallet data model: prior art

Purpose: check the data-model decisions in #1 against how existing ledgers and wallets model their data, before those decisions get locked in. This is the deliverable of the spike in #2.

- Date: 2026-11-17
- Discovery: [#1](../../../../issues/1) · Spike: [#2](../../../../issues/2)
- Method: primary sources only (official docs, source code, first-party engineering blogs). Every claim below links to the page it came from. Anything built for much larger scale than ours (~1,500 entries/s organic peak, 7,600/s bursts, single currency) is labelled **perspective** and is not a recommendation.

## Sources

| # | Source | Link | Designed for | Answers |
|---|---|---|---|---|
| TB | TigerBeetle docs | [transfer][tb-transfer], [account][tb-account], [two-phase][tb-2pc], [reliable submission][tb-reliable], [create_transfers][tb-create], [data modeling][tb-model], [correcting transfers][tb-correct], [closing accounts][tb-close], [performance][tb-perf] | A purpose-built OLTP financial database. Batches of up to 8,190 transfers per request; multiple ledgers (currency or any grouping). Much larger scale than ours: **perspective**. | Q1, Q2, Q3, Q4, Q5, Q6 |
| ST-API | Stripe API docs | [idempotent requests (v1)][st-idem], [API v2 idempotency][st-v2], [balance transaction][st-btxn], [customer balance transaction][st-cbtxn], [create refund][st-refund], [Treasury balances & transactions][st-treasury] | Global, regulated, multi-currency payments. Much larger scale: **perspective**, but the API shapes are directly comparable. | Q2, Q3, Q4, Q5, Q6 |
| ST-L | Stripe engineering blog, "Ledger" | [stripe.dev][st-ledger] | Stripe's internal money-movement ledger, 5 billion events/day. **Perspective.** | Q1, Q4, Q5 |
| MT | Modern Treasury docs and engineering journal | [high-throughput ledgers][mt-throughput], [concurrency][mt-concurrency], [optimistic locking][mt-optlock], [immutability][mt-immutable], [ledger transaction][mt-ltx], [reversal][mt-reversal], [idempotency][mt-idem] | Ledger-as-a-service on Postgres for fintechs, multi-currency. Stated target of 1,200 transactions (4,800 entries) per second. **Closest to our scale.** | Q1, Q2, Q3, Q4, Q5, Q6, Q7 |
| FO | Formance Ledger docs (v3.2) and source | [transactions & postings][fo-tx], [accounts][fo-accounts], [reverting][fo-revert], [idempotency][fo-idem], [architecting for scale][fo-scale], [bi-temporality][fo-bitemp], [revert source][fo-revert-src] | Open-source programmable ledger on Postgres, multi-asset. Docs say it is optimised for about 1K writes/s per ledger on commodity storage. **Close to our scale.** | Q1, Q2, Q3, Q5, Q6, Q7 |
| BL | Blnk docs | [balances][bl-balances], [internal balances][bl-internal], [inflight][bl-inflight], [refunds][bl-refund], [unique reference migration][bl-ref], [hot balances][bl-hot], [benchmarks][bl-bench], [snapshots][bl-snap], [historical balances][bl-hist] | Open-source ledger on Postgres and Redis, multi-currency. Benchmarked on a single 4 vCPU host. **Close to our scale.** | Q1, Q2, Q3, Q4, Q5, Q6, Q7 |
| SQ | Square engineering blog, "Books" (2019) | [developer.squareup.com][sq-books] | Square's multi-tenant double-entry service on Cloud Spanner, about 20 TB. **Perspective.** | Q1, Q2, Q3, Q5 |
| UB | Uber engineering blog, LedgerStore | [trillions of indexes][ub-index], [DynamoDB to LedgerStore][ub-migrate] | Over a trillion immutable entries, petabytes. **Perspective.** | Q7 |
| PG | pgledger (open source, Postgres only) | [README][pg-readme], [pgledger.sql][pg-sql] | Single-author library implemented entirely in Postgres functions. Benchmarks were run on a laptop. Close to our stack. | Q1, Q2, Q3, Q6, Q7 |

Not read: Airbnb's "Avoiding double payments" post returned HTTP 403, so it is not cited. Shopify, Monzo, Nubank and Adyen were not needed to reach two sources per question and were not checked.

## Q1. Double-entry with customer-side accounts?

Findings:
- Every ledger *product* studied is double-entry. Each transaction balances debits against credits ([MT][mt-ltx], [SQ][sq-books], [ST-L][st-ledger], [TB][tb-model], [PG][pg-readme]).
- Money that comes from outside is modelled as a system account:
  - Formance's `world` account is an unlimited source ([FO][fo-scale]).
  - Blnk requires a source on every transaction and represents money "that belongs outside the ledger" as internal (General Ledger) balances such as `@DepositsUSD` ([BL][bl-internal]).
  - TigerBeetle frames accounts as the operator's assets, liabilities and income ([TB][tb-model]).
- Those system accounts are exactly where the hot spots appear:
  - Modern Treasury: the bank settlement account is the hot account "because it's present on most Transactions" ([MT][mt-throughput]).
  - Formance: "using the same source account repeatedly creates a bottleneck at the PostgreSQL level" ([FO][fo-scale]).
  - Blnk: treasury, settlement and fee accounts are the cases it shards ([BL][bl-hot]).
- Stripe Ledger uses clearing accounts that should be empty at steady state, so a non-zero balance flags a missing or mismatched event ([ST-L][st-ledger]). That is the payoff of double-entry: reconciliation across systems. **Perspective** (5B events/day, many internal producers).
- The customer-facing wallet objects at Stripe are single-sided:
  - A customer balance transaction has `amount`, `ending_balance` and a reference to the invoice or credit note that caused it ([ST-API][st-cbtxn]).
  - A balance transaction has `amount` and `source` ([ST-API][st-btxn]).
  - Neither carries a counterpart account.

What this changes here: nothing. Customer-side accounts (revenue, cash per payment method) would be our hottest rows, which is the problem MT, FO and BL all have to engineer around. The reconciliation benefit belongs to the POS/ERP, as #1 already says. Keeping the counterpart on `operation` (`payment_method_id`, `pos_id`) matches the single-sided wallet objects Stripe exposes.

## Q2. Primitive: entry per account, or transfer (debit, credit, amount)?

Findings:
- **Transfer as the primitive.**
  - TigerBeetle: `debit_account_id`, `credit_account_id`, `amount`; multi-leg operations are chained with `flags.linked` ([TB][tb-transfer]).
  - Formance: each posting has exactly one source and one destination, grouped into an atomic transaction ([FO][fo-tx]).
  - Blnk: `source` and `destination` ([BL][bl-inflight]).
  - pgledger: `from_account_id`/`to_account_id` on the transfer, **plus** one entry row per account carrying previous and current balance and version ([PG][pg-sql]).
- **Transaction with N entries.**
  - Modern Treasury: a ledger transaction holds `ledger_entries` (direction, amount, account) whose credits must equal debits ([MT][mt-ltx]).
  - Square: `journal_entries` with `book_entries` rows, one per book touched ([SQ][sq-books]).
  - Stripe Treasury: a `Transaction` aggregates `TransactionEntry` rows that each affect one account ([ST-API][st-treasury]).

What this changes here: nothing. `operation` + one `entry` per wallet is the MT, Square and Stripe Treasury shape. The transfer shape presumes both sides are ledger accounts, and ours deliberately are not (Q1). pgledger shows that even transfer-based ledgers end up writing a per-account entry row to serve statements and historical balances.

## Q3. Balance stored or derived? Hot accounts?

Findings:
- **Stored, in every source.**
  - TigerBeetle stores cumulative `debits_posted`/`credits_posted` (and pending) on the account ([TB][tb-account]).
  - Formance says it "does not store balances directly" but stores cumulative volumes per account, from which balance is input minus output ([FO][fo-tx]), in an `accounts_volumes` table ([FO][fo-scale]).
  - Blnk keeps running balances plus a `version` counter on the balance and does not support editing the balance directly ([BL][bl-balances]).
  - Modern Treasury caches balances so reads are O(1) ([MT][mt-throughput]).
  - Square updates the current balance on `books` on every operation ([SQ][sq-books]).
  - pgledger keeps `balance` and `version` on the account ([PG][pg-sql]).
- **Running balance per entry** is common:
  - Square caches balances on `book_entries`.
  - Modern Treasury keeps a resulting balance per entry ([MT][mt-throughput]).
  - pgledger stores previous and current balance on each entry ([PG][pg-readme]).
  - Stripe's customer balance transaction exposes `ending_balance` ([ST-API][st-cbtxn]).
- **Concurrency control** is a row lock or an atomic in-database check, never a read then a write.
  - Modern Treasury uses Postgres row-level locks when an entry carries a balance condition ([MT][mt-throughput]).
  - pgledger sorts account ids and locks them `FOR UPDATE` in that order to prevent deadlocks ([PG][pg-sql]).
  - TigerBeetle enforces `debits_must_not_exceed_credits` inside the database ([TB][tb-account]) and argues interactive transactions fail under high contention ([TB][tb-perf]).
- **Hot accounts**, by source:
  - Modern Treasury: make the hot account receive only asynchronous entries (applied within 60 s) and lock only on low-throughput user accounts ([MT][mt-concurrency]).
  - Formance: split the hot account into a pool of sub-accounts (e.g. `@world:<random_id>`, pool of about 20), because locks are per (account, asset) ([FO][fo-scale]).
  - Blnk: queue, coalescing of same source/destination transactions into one commit, and sharding into N balances ([BL][bl-hot]). Its benchmark applied 2,830–3,500 transactions/min (≈47–58/s) on one hot balance versus 9,600/min spread out, on a 4 vCPU host in queued inflight mode ([BL][bl-bench]).
  - pgledger: about 9,300 transfers/s with 10 accounts and 20 workers on a laptop ([PG][pg-readme]). Not a production number.

What this changes here: Balance and Limit rule are kept. Our conditional `UPDATE ... WHERE balance - :x + credit_limit >= 0` is the same "atomic check inside the database" idea as TB's flags and MT's balance locks. `entry.balance_after` matches Square, MT, pgledger and Stripe.

Two notes for #3:
- A transfer touches two wallets, so update them in a fixed order (by `wallet_id`), as pgledger does, to avoid deadlocks.
- Our only hot wallet (70 writes/s, batches only) is within the range where Blnk and pgledger report single-row throughput. Sharding a wallet would break the single-row limit check, so the first lever if #3 shows contention is **coalescing the batch into fewer writes**, the Blnk approach.

## Q4. Pending state (reserve, then confirm)?

Findings:
- **All four products have one.**
  - TigerBeetle: pending transfers reserve into `debits_pending`; post (full or partial), void or timeout resolves them, at most once, by a new transfer referencing `pending_id` ([TB][tb-2pc]).
  - Blnk: inflight transactions with commit (full or partial), void and expiry ([BL][bl-inflight]).
  - Modern Treasury: `pending`, `posted` and `archived` statuses; pending is mutable, posted is immutable ([MT][mt-ltx]).
  - Stripe Treasury: `open`, `posted` and `void`, with `outbound_pending` sub-balances ([ST-API][st-treasury]).
- **The stated reasons are all asynchronous external settlement:**
  - Modern Treasury: ACH and wire payments take days and may fail, and pending "may not suit every product" ([MT][mt-immutable]).
  - Blnk: KYC limits, card authorisation, external payouts ([BL][bl-inflight]).
  - Stripe Treasury: outbound payments that can be cancelled before funds leave ([ST-API][st-treasury]).
  - Stripe Ledger models a charge as pending-then-released ([ST-L][st-ledger]).
- Formance warns against using reverts as a substitute for a pending → cancelled workflow; that should be modelled with account structure ([FO][fo-revert]).

What this changes here: no pending state, kept and now recorded as a decision. Our payments are synchronous and online, settled by our own conditional update. Paying with several wallets is out of scope (the integrator reverses), and there is no external rail to wait on. Pending would add a second balance (`balance_pending`) to every limit check. Revisit only if multi-wallet payment comes into scope or the top-up processor becomes asynchronous.

## Q5. Reversals and corrections

Findings:
- **Correct with new records; never edit.** Every source agrees ([TB][tb-correct], [MT][mt-immutable], [SQ][sq-books], [ST-L][st-ledger], [FO][fo-revert]).
- **Explicit references both ways.**
  - Modern Treasury: `reverses_ledger_transaction_id` on the reversal and `reversed_by_ledger_transaction_id` on the original ([MT][mt-ltx]).
  - Formance: stores `RevertedByTransaction` on the original and a back-link on the revert ([FO][fo-revert-src]).
  - TigerBeetle has no reference field. It suggests a correction `code` and reusing `user_data_128` to group original and correction ([TB][tb-correct]).
- **Once only.**
  - Formance rejects a second revert with `ErrTransactionAlreadyReverted` ([FO][fo-revert-src]).
  - Blnk allows one refund per transaction (`409 TXN_ALREADY_REFUNDED`); the refund's reference is derived from the original id (`{original_txn_id}_refund`) ([BL][bl-refund]).
  - Modern Treasury rejects a reversal while a non-archived one exists, and only posted transactions can be reversed ([MT][mt-reversal]).
- **Granularity.**
  - Formance revert, Blnk refund and MT reversal are full mirrors ([FO][fo-revert], [BL][bl-refund], [MT][mt-reversal]).
  - Stripe refunds may be partial and repeated until the charge is fully refunded ([ST-API][st-refund]).
  - Modern Treasury also describes a "difference" correction as an alternative to reverse-and-rebook ([MT][mt-immutable]).

What this changes here: nothing. Full mirror with `reverses_operation_id` and `reversed_by_operation_id` is the MT/Formance shape, field for field. The `UPDATE ... WHERE reversed_by_operation_id IS NULL` guard does what Formance's "already reverted" check does.

Blnk's derived unique reference is an alternative that lives in the idempotency table. We should not use it: our idempotency keys expire after 30 days and reversal has no time limit.

## Q6. Idempotency and key retention

Findings:
- **Client-generated key, checked against request contents.**
  - Stripe compares parameters and errors on mismatch ([ST-API][st-idem]).
  - Formance (v2.2+) stores a request hash and returns a validation error on mismatch ([FO][fo-idem]).
  - TigerBeetle returns `exists_with_different_*` ([TB][tb-create]).
  - pgledger raises "already used with a different request" ([PG][pg-readme]).
- **Failures are remembered too.**
  - Stripe v1 replays the saved response "including `500` errors" ([ST-API][st-idem]).
  - TigerBeetle (≥0.16.4) returns `id_already_failed` so a retry cannot produce a different outcome ([TB][tb-create]).
  - Modern Treasury saves only successful results ([MT][mt-idem]).
- **Retention:**
  - Stripe API v1: keys can be pruned after 24 h ([ST-API][st-idem]).
  - Stripe API v2: 30 days ([ST-API][st-v2]).
  - Modern Treasury: 24 h ([MT][mt-idem]).
  - TigerBeetle: no expiry; the id *is* the record ([TB][tb-reliable], [TB][tb-transfer]).
  - Blnk: a database-level unique index on `transactions.reference` ([BL][bl-ref]).
  - pgledger: a separate `pgledger_idempotency_keys` table, no expiry ([PG][pg-sql]).
- **Scope:**
  - Stripe v2: per account ([ST-API][st-v2]).
  - Formance: per ledger ([FO][fo-idem]).
- **Concurrent duplicates:** pgledger takes `pg_advisory_xact_lock` on the key so concurrent duplicates wait ([PG][pg-sql]).

What this changes here: Idempotency is kept. A separate table unique on `(tenant_id, key)` is the pgledger design. 30 days matches Stripe v2 and is longer than Stripe v1 and MT. Storing rejections with `request_hash` matches Stripe v1, TigerBeetle and Formance. Note for the API work: a concurrent duplicate must wait on the key (unique-index insert first, or an advisory lock) before the wallet `UPDATE`.

## Q7. Archiving without losing balance auditability

Findings:
- **Hot/cold split by time.**
  - Uber kept 12 weeks of ledger data hot and moved older data to blob storage ([UB][ub-migrate]).
  - Uber offloads older ledgers to cold storage in event-time-range batches, using time-range indexes ([UB][ub-index]).
  - Modern Treasury lists moving old data to cold storage as future work, not current practice ([MT][mt-throughput]).
- **Segment by time or by group.** Formance suggests separate ledgers per group of users or per period (year, then month) ([FO][fo-scale]).
- **Periodic balances.**
  - Blnk takes one balance snapshot per balance per day and reconstructs balances in between from transactions; historical balance queries use the snapshots, or recompute from source ([BL][bl-snap], [BL][bl-hist]).
  - Modern Treasury keeps an effective-time balance cache for historical balances ([MT][mt-throughput]).
  - Square, MT and pgledger store the balance on every entry, so the last entry before a cutoff is the closing balance ([SQ][sq-books], [PG][pg-readme]).
- **Not found:** no source describes how it keeps balance continuity *across* an archive boundary (opening balance plus online entries equals current balance) once old entries leave the database.

What this changes here: Partitioning is kept. One addition (New): when a monthly partition is archived, write a per-wallet **closing balance** for that month (from the last entry's `balance_after`, or carried forward for wallets with no movement). Then for every wallet, `closing balance at the online window's start + sum(online entries) = wallet.balance` stays checkable after the archive, which matters because the balance never expires. This follows Blnk's snapshots and the per-entry balance of Square, MT and pgledger. The exact table and job are left to #3.

## Prior art (ready to paste into #1)

> ## Prior art
>
> Checked in #2 (full notes: `docs/research/wallet-data-model-prior-art.md`). Primary sources only.
>
> - **Modern Treasury** (Postgres ledger-as-a-service, target 4,800 entries/s, closest to our scale): transaction + N entries; balance cached and locked per row; hot accounts are the settlement/counterpart accounts and get async entries; full reversal linked by `reverses_`/`reversed_by_` ids; idempotency 24 h. *Changes:* confirms operation + entries, stored balance, `reversed_by_operation_id`; hot accounts come from counterpart accounts, which is a reason to keep not having them.
> - **Formance Ledger** (Postgres, ~1K writes/s per ledger): source→destination postings; balances from stored volumes; hot `world` account split into a pool; revert once, back-linked; idempotency key + request hash per ledger; segment ledgers by user group or time. *Changes:* confirms reverse-once and per-tenant key scope; customer grouping per database mirrors its segmentation.
> - **Blnk** (Postgres + Redis): running balance + version; inflight (hold/commit/void) for card and payout flows; refund once, full; unique `reference` as idempotency; hot balance ≈50/s on 4 vCPU, mitigated by coalescing and sharding; daily balance snapshots. *Changes:* coalescing is the first lever if the 70/s batch wallet contends; snapshots inspire closing balances at archive time.
> - **TigerBeetle** (purpose-built, much larger scale, perspective): transfer primitive with cumulative debit/credit totals; limits enforced in-database; two-phase pending transfers; corrections as new transfers; id is the idempotency key, failures remembered. *Changes:* none; confirms enforcing the limit inside one atomic statement.
> - **Stripe** (perspective): idempotency 24 h (v1) / 30 days (v2) with request comparison and stored errors; customer balance transactions are single-sided with `ending_balance`; internal Ledger is double-entry with clearing accounts for reconciliation at 5B events/day. *Changes:* 30-day retention matches v2; single-sided wallet entries have precedent.
> - **Square Books** (Spanner, perspective): journal entry + book entries, balance cached on books and entries, monotonic version per book. *Changes:* confirms `balance_after` and `seq`/`last_seq`.
> - **Uber LedgerStore** (perspective): immutable ledger, 12 weeks hot then cold storage by time range. *Changes:* confirms time-based archiving.
> - **pgledger** (Postgres-only library): balance + version on account, previous/current balance per entry, separate idempotency table, accounts locked in sorted order. *Changes:* lock wallets in `wallet_id` order in transfers.
>
> Not found in any source: how to keep balance continuity across an archive boundary, which led to the new closing-balance decision.

## Decisions revisited

| Decision | Verdict | Reason | Sources |
|---|---|---|---|
| Balance (stored on `wallet`) | **Kept** | Every source stores a balance or cumulative totals; per-entry running balance is common. | [TB][tb-account], [FO][fo-tx], [BL][bl-balances], [MT][mt-throughput], [SQ][sq-books], [PG][pg-sql] |
| Limit rule (conditional `UPDATE`) | **Kept**, with a note | Same as TB's in-database flags and MT's row-locked balance conditions. Note: in a transfer, update the two wallets in `wallet_id` order to avoid deadlocks. Adopted now: wallet-ordered locking in transfers. Deferred to #3: coalescing batch writes on the hot wallet, only if contention shows; do not shard a wallet. | [TB][tb-account], [MT][mt-throughput], [PG][pg-sql], [BL][bl-hot] |
| Idempotency (`idempotency_key` table, 30 days) | **Kept** | Separate table matches pgledger; 30 days matches Stripe v2 and exceeds Stripe v1 and MT (24 h); request hash and stored rejections match Stripe, TB and FO. Note: duplicates in flight must serialize on the key. After review: the table stays **unpartitioned**, pruned by batched `DELETE` (~1.8M keys/day at 100×), because daily partitions would bring back per-partition uniqueness; #3 measures the pruning cost. | [ST-API][st-v2], [ST-API][st-idem], [MT][mt-idem], [PG][pg-sql], [TB][tb-create], [FO][fo-idem] |
| Reverse once (`reversed_by_operation_id ... IS NULL`) | **Kept** | Same two-way link as MT and Formance; once-only matches Formance, Blnk and MT. Not moved to the idempotency table, because those keys expire after 30 days. | [MT][mt-ltx], [MT][mt-reversal], [FO][fo-revert-src], [BL][bl-refund] |
| Statement order (`seq = last_seq + 1`) | **Kept** | Square keeps a monotonic version per book; pgledger orders history by `account_version` because batch entries share `created_at`; Blnk keeps `version`. | [SQ][sq-books], [PG][pg-readme], [BL][bl-balances] |
| Zero-value movements (not written) | **Kept** | Not one of the seven questions. pgledger rejects zero amounts by constraint ([PG][pg-sql]); no other source was checked on this point. | [PG][pg-sql] |
| Partitioning (monthly, 24 online) | **Kept** | Time-based hot/cold split matches Uber (12 weeks hot) and Formance's time segmentation. | [UB][ub-migrate], [UB][ub-index], [FO][fo-scale] |
| Distribution (customer groups per database) | **Kept** | Formance recommends segmenting ledgers by a fixed group of users; Square namespaces tenants as "shelves". | [FO][fo-scale], [SQ][sq-books] |
| Double-entry with customer-side accounts | **New, adopted after review** (research suggested rejecting) | Ownership by the POS/ERP is not a reason to skip it: reconciliation needs the wallet's own independent record of cash per payment method and revenue. Every operation sums to zero across accounts. Counterpart accounts are per customer and have **no stored balance** on the write path (totals from entries or an off-path rollup), which avoids the hot counterpart row seen in MT, FO and BL. At ~15 writes/s per customer peak, performance alone would not have ruled it out. Cost: ~2× entry rows. | [MT][mt-throughput], [FO][fo-scale], [BL][bl-hot], [ST][st-ledger] |
| Primitive (`operation` + entry per wallet) | **New, kept as is** (recorded as a decision) | Same shape as MT ledger transaction/entries, Square journal/book entries, Stripe Treasury Transaction/TransactionEntry. | [MT][mt-ltx], [SQ][sq-books], [ST-API][st-treasury] |
| Pending state | **New, rejected** (recorded as a decision) | Every source's reason for pending is asynchronous external settlement; ours is synchronous and online. Revisit if multi-wallet payment or an async top-up processor comes in. | [MT][mt-immutable], [BL][bl-inflight], [ST-API][st-treasury], [TB][tb-2pc] |
| Closing balance at the archive boundary | **New, adopted** (changed after review) | Keeps `archived_balance + sum(online entries) = wallet.balance` checkable after a partition is archived, since the balance never expires. Stored as `wallet.archived_balance` and `wallet.archived_seq`, set when a month is archived, instead of one row per wallet per month: with 113M wallets and a median of 1 day of use, monthly rows would mostly repeat. No source covers the archive boundary itself. | [BL][bl-snap], [BL][bl-hist], [SQ][sq-books], [PG][pg-readme] |

### Review outcome (2026-11-17)

Reviewed with the project author. Changes from the research verdicts above:

- Double-entry flipped from rejected to adopted, with counterpart accounts that keep no stored balance. Revenue is tracked per customer, not per point of sale.
- Entries reference `account_id`: wallets and a new `ledger_account` table share one id space. `seq` is set only on wallet entries; counterpart entries order by `entry_id` (UUIDv7) so no counterpart row becomes hot.
- New invariant: every operation's entries sum to zero; per customer, sum of wallet balances + sum of counterpart entries = 0.
- #3's target is restated as **1,500 operations/s** (~3,000 entry rows/s), keeping the business load the same.
- Closing balance stored on `wallet` (`archived_balance`, `archived_seq`), not per month.
- Idempotency table unpartitioned, pruned by batched `DELETE`.
- Refund fee dropped from scope: no `fee_revenue` account, no `refund_fee` entry kind, no `tenant.refund_fee_pct`. Every operation in scope now has exactly two legs. Header + lines is kept for per-account statements, a single home for business data, and the likely multi-leg extensions; transfer rows would fit today's operations but not those.
- Open: which payment method a balance refund is paid through when the wallet was topped up with several.

## Unanswered / open points

1. **Q7 is only partly answered.** Time-based offload (Uber, Formance) and periodic balances (Blnk) each have sources. No source describes keeping balance continuity across an archive boundary, so the closing-balance decision is our own design and is not backed by prior art.
2. **Zero-value movements** have one source (pgledger rejects zero). This was not one of the seven questions, and the decision rests on #1's own data.
3. **Hot single-row throughput in Postgres** has only indirect numbers: Blnk's queued inflight benchmark (≈50/s on a hot balance) and pgledger's laptop run. Neither measures a synchronous conditional `UPDATE` at 70/s on one row. #3 has to measure it.
4. **Idempotency key retention** in the self-hosted ledgers (TB, Blnk, pgledger) is effectively "forever", because the key is the record. Only the hosted APIs (Stripe, MT) state a time window. Whether 30 days is enough for POS retry behaviour is a product question, not a prior-art one.
5. Airbnb's idempotency post could not be read (HTTP 403) and is not cited.

[tb-transfer]: https://docs.tigerbeetle.com/reference/transfer/
[tb-account]: https://docs.tigerbeetle.com/reference/account/
[tb-2pc]: https://docs.tigerbeetle.com/coding/two-phase-transfers/
[tb-reliable]: https://docs.tigerbeetle.com/coding/reliable-transaction-submission/
[tb-create]: https://docs.tigerbeetle.com/reference/requests/create_transfers/
[tb-model]: https://docs.tigerbeetle.com/coding/data-modeling/
[tb-correct]: https://docs.tigerbeetle.com/coding/recipes/correcting-transfers/
[tb-close]: https://docs.tigerbeetle.com/coding/recipes/close-account/
[tb-perf]: https://docs.tigerbeetle.com/concepts/performance/
[st-idem]: https://docs.stripe.com/api/idempotent_requests
[st-v2]: https://docs.stripe.com/api-v2-overview#idempotency
[st-btxn]: https://docs.stripe.com/api/balance_transactions/object
[st-cbtxn]: https://docs.stripe.com/api/customer_balance_transactions/object
[st-refund]: https://docs.stripe.com/api/refunds/create
[st-treasury]: https://docs.stripe.com/treasury/account-management/working-with-balances-and-transactions
[st-ledger]: https://stripe.dev/blog/ledger-stripe-system-for-tracking-and-validating-money-movement
[mt-throughput]: https://www.moderntreasury.com/journal/behind-the-scenes-how-we-built-ledgers-for-high-throughput
[mt-concurrency]: https://docs.moderntreasury.com/docs/handling-concurrency
[mt-optlock]: https://moderntreasury.com/journal/designing-ledgers-with-optimistic-locking
[mt-immutable]: https://moderntreasury.com/journal/enforcing-immutability-in-your-double-entry-ledger
[mt-ltx]: https://docs.moderntreasury.com/platform/reference/ledger-transaction-object
[mt-reversal]: https://docs.moderntreasury.com/platform/reference/create-ledger-transaction-reversal
[mt-idem]: https://docs.moderntreasury.com/platform/reference/idempotent-requests
[fo-tx]: https://docs.formance.com/v3.2/modules/ledger/core-concepts/transactions
[fo-accounts]: https://docs.formance.com/v3.2/modules/ledger/core-concepts/accounts
[fo-revert]: https://docs.formance.com/v3.2/modules/ledger/working-with/reverting-transactions
[fo-idem]: https://docs.formance.com/v3.2/modules/ledger/working-with/idempotency
[fo-scale]: https://docs.formance.com/v3.2/modules/ledger/advanced/architecting-for-scale
[fo-bitemp]: https://docs.formance.com/v3.2/modules/ledger/working-with/bi-temporality
[fo-revert-src]: https://github.com/formancehq/ledger/blob/32ac3735c418af1bc65fb273f6a05499a177fe8b/internal/domain/processing/processor_revert_transaction.go
[bl-balances]: https://docs.blnkfinance.com/balances/introduction
[bl-internal]: https://docs.blnkfinance.com/balances/internal-balances
[bl-inflight]: https://docs.blnkfinance.com/transactions/inflight/create-inflight
[bl-refund]: https://docs.blnkfinance.com/transactions/refunds
[bl-ref]: https://docs.blnkfinance.com/migrations/core/v13-2-migration
[bl-hot]: https://docs.blnkfinance.com/guides/hot-balances
[bl-bench]: https://docs.blnkfinance.com/operating/benchmarks
[bl-snap]: https://docs.blnkfinance.com/balances/balance-snapshots
[bl-hist]: https://docs.blnkfinance.com/balances/historical-balances
[sq-books]: https://developer.squareup.com/blog/books-an-immutable-double-entry-accounting-database-service/
[ub-index]: https://www.uber.com/us/en/blog/how-ledgerstore-supports-trillions-of-indexes/
[ub-migrate]: https://www.uber.com/us/en/blog/migrating-from-dynamodb-to-ledgerstore/
[pg-readme]: https://github.com/pgr0ss/pgledger/blob/fee1aa05630f5af8cb3196749aa4d998162a9862/README.md
[pg-sql]: https://github.com/pgr0ss/pgledger/blob/fee1aa05630f5af8cb3196749aa4d998162a9862/pgledger.sql
