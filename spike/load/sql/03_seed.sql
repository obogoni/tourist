-- Seed: customers, counterpart accounts, wallets and a consistent history.
-- psql variables: tenants (default 100), wallets (default 1000000).
-- Wallet i (0-based) has wallet_id 1000000 + i and tenant i % tenants + 1, so
-- the load scripts can pick a wallet and its customer without a lookup.
-- Wallet index `wallets` is the hot batch wallet; the next 20 are near their limit.

\if :{?tenants}
\else
  \set tenants 100
\endif
\if :{?wallets}
\else
  \set wallets 1000000
\endif

\timing on
SET synchronous_commit = off;

SELECT create_month_partitions('2026-08-01', '2027-02-01');
INSERT INTO archive_state (online_from) VALUES ('2026-08-01');

INSERT INTO tenant (tenant_id) SELECT g FROM generate_series(1, :tenants) g;

INSERT INTO payment_method (method_id, tenant_id, name, is_refundable)
SELECT t * 10 + m, t, CASE m WHEN 1 THEN 'cash' ELSE 'card' END, true
FROM generate_series(1, :tenants) t, generate_series(1, 2) m;

INSERT INTO ledger_account (tenant_id, kind, method_id)
SELECT tenant_id, kind, method_id FROM (
  SELECT tenant_id, k.kind, method_id FROM payment_method, (VALUES ('cash'), ('refunds_paid')) k(kind)
  UNION ALL
  SELECT tenant_id, 'revenue', NULL FROM tenant
) a ORDER BY tenant_id, kind, method_id;

-- ~98% of day-use wallets are postpaid with a credit limit.
INSERT INTO wallet (wallet_id, tenant_id, kind, credit_limit, daily_limit)
SELECT 1000000 + i, i % :tenants + 1,
       CASE WHEN r < 0.98 THEN 'postpaid' ELSE 'prepaid' END,
       CASE WHEN r < 0.98 THEN 50000 ELSE 0 END,
       CASE WHEN r2 < 0.10 THEN 200000 END
FROM (SELECT i, random() r, random() r2 FROM generate_series(0, :wallets - 1) i) s;

-- The batch wallet: never limited, so every one of its writes lands.
INSERT INTO wallet (wallet_id, tenant_id, kind, credit_limit)
VALUES (1000000 + :wallets, :wallets % :tenants + 1, 'postpaid', 1000000000000);

-- Wallets close to their limit, for the concurrent-payment race.
INSERT INTO wallet (wallet_id, tenant_id, kind, credit_limit)
SELECT 1000000 + i, i % :tenants + 1, 'postpaid', 1000
FROM generate_series(:wallets + 1, :wallets + 20) i;

SELECT setval('account_id_seq', 1000000 + :wallets + 1000);

-- History: each wallet is used on one day between August and yesterday, with
-- 1 to 5 pairs of top-up then payment (p50 of 6 movements per wallet).
CREATE UNLOGGED TABLE seed_pair AS
SELECT w.wallet_id, w.tenant_id, w.method_id, p AS pair,
       w.use_at + (p - 1) * interval '20 minutes' AS topup_at,
       (1000 + floor(random() * 19000))::bigint AS topup_amount,
       random() AS pay_ratio
FROM (SELECT wallet_id, tenant_id,
             timestamptz '2026-08-01' + random() * (timestamptz '2026-11-16 20:00' - timestamptz '2026-08-01') AS use_at,
             1 + floor(random() * 5)::int AS pairs,
             tenant_id * 10 + 1 + floor(random() * 2)::int AS method_id
      FROM wallet WHERE wallet_id < 1000000 + :wallets) w,
     LATERAL generate_series(1, w.pairs) p;

CREATE UNLOGGED TABLE seed_op AS
SELECT row_number() OVER (ORDER BY at, wallet_id, seq) AS operation_id,
       s.*,
       sum(amount) OVER (PARTITION BY wallet_id ORDER BY seq) AS balance_after
FROM (
  SELECT wallet_id, tenant_id, method_id, 2 * pair - 1 AS seq, topup_at AS at, 'topup' AS kind,
         topup_amount AS amount
  FROM seed_pair
  UNION ALL
  SELECT wallet_id, tenant_id, NULL, 2 * pair, topup_at + interval '7 minutes', 'payment',
         -greatest(1, floor(topup_amount * pay_ratio))::bigint
  FROM seed_pair
) s;

INSERT INTO operation (operation_id, created_at, tenant_id, kind, status, idempotency_key, request_hash, response)
SELECT operation_id, at, tenant_id, kind, 'completed', md5('seed' || operation_id)::uuid::text,
       decode(md5('seed' || operation_id), 'hex'),
       jsonb_build_object('operation_id', operation_id, 'status', 'completed', 'kind', kind,
                          'wallet_id', wallet_id, 'balance', balance_after, 'seq', seq)
FROM seed_op;

INSERT INTO entry (entry_id, created_at, operation_id, tenant_id, account_id, amount, seq, balance_after)
SELECT 2 * operation_id - 1, at, operation_id, tenant_id, wallet_id, amount, seq, balance_after
FROM seed_op;

INSERT INTO entry (entry_id, created_at, operation_id, tenant_id, account_id, amount)
SELECT 2 * o.operation_id, o.at, o.operation_id, o.tenant_id, a.account_id, -o.amount
FROM seed_op o
JOIN ledger_account a
  ON a.tenant_id = o.tenant_id
 AND ((o.kind = 'topup' AND a.kind = 'cash' AND a.method_id = o.method_id)
   OR (o.kind = 'payment' AND a.kind = 'revenue'));

UPDATE wallet w
SET balance = s.balance, last_seq = s.last_seq, created_at = s.first_at
FROM (SELECT wallet_id, sum(amount) AS balance, max(seq) AS last_seq, min(at) AS first_at
      FROM seed_op GROUP BY wallet_id) s
WHERE w.wallet_id = s.wallet_id;

SELECT setval('operation_id_seq', (SELECT max(operation_id) FROM seed_op));
SELECT setval('entry_id_seq', (SELECT 2 * max(operation_id) FROM seed_op));

-- Idempotency keys: the history's last 30 days, plus filler at the 100x rate
-- (~1.8M keys/day, issue #2): one expired day to prune and 8M live keys.
INSERT INTO idempotency_key (tenant_id, key, request_hash, operation_id, operation_created_at, created_at)
SELECT tenant_id, md5('seed' || operation_id)::uuid::text, decode(md5('seed' || operation_id), 'hex'),
       operation_id, at, at
FROM seed_op WHERE at >= now() - interval '30 days';

INSERT INTO idempotency_key (tenant_id, key, request_hash, operation_id, operation_created_at, created_at)
SELECT 1 + (g % :tenants), gen_random_uuid()::text, '\x00', 0, ts, ts
FROM (SELECT g, now() - interval '31 days' + random() * interval '1 day' AS ts
      FROM generate_series(1, 1800000) g) s;

INSERT INTO idempotency_key (tenant_id, key, request_hash, operation_id, operation_created_at, created_at)
SELECT 1 + (g % :tenants), gen_random_uuid()::text, '\x00', 0, ts, ts
FROM (SELECT g, now() - random() * interval '29 days' AS ts
      FROM generate_series(1, 8000000) g) s;

DROP TABLE seed_pair, seed_op;
