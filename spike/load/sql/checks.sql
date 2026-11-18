-- Invariant checks (design doc, How it works > Invariants). Every count must be 0.
-- Run with no load, or accept that a single snapshot is checked.
\timing on
SET work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
BEGIN ISOLATION LEVEL REPEATABLE READ;

CREATE TEMP TABLE online_wallet_entry ON COMMIT DROP AS
SELECT e.account_id, e.seq, e.amount, e.balance_after, e.operation_id
FROM entry e JOIN wallet w ON w.wallet_id = e.account_id
WHERE e.seq IS NOT NULL AND e.seq > w.archived_seq;

CREATE TEMP TABLE result (invariant text, violations bigint) ON COMMIT DROP;

-- 1. A wallet's balance never goes below -credit_limit (stored, and at every entry).
INSERT INTO result
SELECT '1a balance below -credit_limit (wallet)', count(*)
FROM wallet WHERE balance < -credit_limit;
INSERT INTO result
SELECT '1b balance below -credit_limit (any entry)', count(*)
FROM online_wallet_entry e JOIN wallet w ON w.wallet_id = e.account_id
WHERE e.balance_after < -w.credit_limit;

-- 2. seq 1, 2, 3... with no gap or duplicate; balance_after chains.
INSERT INTO result
SELECT '2a seq gap or duplicate', count(*)
FROM wallet w
LEFT JOIN (SELECT account_id, count(*) n, count(DISTINCT seq) nd, min(seq) lo, max(seq) hi
           FROM online_wallet_entry GROUP BY account_id) s ON s.account_id = w.wallet_id
WHERE coalesce(s.n, 0) <> w.last_seq - w.archived_seq
   OR coalesce(s.nd, 0) <> coalesce(s.n, 0)
   OR (s.n > 0 AND (s.lo <> w.archived_seq + 1 OR s.hi <> w.last_seq));
INSERT INTO result
SELECT '2b balance_after does not chain', count(*)
FROM (SELECT e.balance_after, e.amount,
             coalesce(lag(e.balance_after) OVER (PARTITION BY e.account_id ORDER BY e.seq),
                      w.archived_balance) AS previous
      FROM online_wallet_entry e JOIN wallet w ON w.wallet_id = e.account_id) c
WHERE c.balance_after <> c.previous + c.amount;

-- 3. archived_balance + online entries = balance.
INSERT INTO result
SELECT '3 archived_balance + entries <> balance', count(*)
FROM wallet w
LEFT JOIN (SELECT account_id, sum(amount) s FROM online_wallet_entry GROUP BY account_id) e
       ON e.account_id = w.wallet_id
WHERE w.archived_balance + coalesce(e.s, 0) <> w.balance;

-- 4. Each operation's entries sum to zero; completed ones have two legs, rejected ones none.
INSERT INTO result
SELECT '4a operation entries do not sum to zero', count(*)
FROM (SELECT operation_id FROM entry GROUP BY operation_id HAVING sum(amount) <> 0) x;
INSERT INTO result
SELECT '4b operation with wrong number of entries', count(*)
FROM operation o
LEFT JOIN (SELECT operation_id, count(*) n FROM entry GROUP BY operation_id) e USING (operation_id)
WHERE (o.status = 'completed' AND coalesce(e.n, 0) <> 2)
   OR (o.status = 'rejected' AND coalesce(e.n, 0) <> 0);

-- 5. Per customer, wallet balances + counterpart entries (online and archived) = 0.
INSERT INTO result
SELECT '5 customer does not sum to zero', count(*)
FROM tenant t
LEFT JOIN (SELECT tenant_id, sum(balance) s FROM wallet GROUP BY tenant_id) w USING (tenant_id)
LEFT JOIN (SELECT tenant_id, sum(archived_total) s FROM ledger_account GROUP BY tenant_id) a USING (tenant_id)
LEFT JOIN (SELECT e.tenant_id, sum(e.amount) s FROM entry e, archive_state st
           WHERE e.seq IS NULL AND e.created_at >= st.online_from GROUP BY e.tenant_id) c USING (tenant_id)
WHERE coalesce(w.s, 0) + coalesce(a.s, 0) + coalesce(c.s, 0) <> 0;

-- 6. Reversed at most once; one operation per idempotency key.
INSERT INTO result
SELECT '6a operation reversed more than once', count(*)
FROM (SELECT reverses_operation_id FROM operation
      WHERE kind = 'reversal' AND status = 'completed'
      GROUP BY reverses_operation_id HAVING count(*) > 1) x;
INSERT INTO result
SELECT '6b reversal link not mutual', count(*)
FROM operation r
LEFT JOIN operation o ON o.operation_id = r.reverses_operation_id
WHERE r.kind = 'reversal' AND r.status = 'completed'
  AND o.operation_id IS NOT NULL AND o.reversed_by_operation_id IS DISTINCT FROM r.operation_id;
INSERT INTO result
SELECT '6c idempotency key with more than one operation', count(*)
FROM (SELECT tenant_id, idempotency_key FROM operation
      GROUP BY tenant_id, idempotency_key HAVING count(*) > 1) x;

SELECT * FROM result ORDER BY invariant;
COMMIT;
