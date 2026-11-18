-- Keys and indexes, created after the seed. These are every index the write path maintains.
\timing on

ALTER TABLE operation ADD PRIMARY KEY (operation_id, created_at);
ALTER TABLE entry ADD PRIMARY KEY (entry_id, created_at);

-- Statement in seq order (D5). Not unique: a unique index on a partitioned
-- table must include created_at, which would not stop a duplicate seq across
-- months. Gapless seq rests on the wallet row lock; invariant 2 checks it.
CREATE INDEX entry_wallet_seq ON entry (account_id, seq) WHERE seq IS NOT NULL;

-- A reversal reads the original's entries.
CREATE INDEX entry_operation ON entry (operation_id);

ALTER TABLE idempotency_key ADD PRIMARY KEY (tenant_id, key);
CREATE INDEX idempotency_key_created_at ON idempotency_key (created_at);

VACUUM (ANALYZE) tenant, payment_method, ledger_account, wallet, idempotency_key;
VACUUM (ANALYZE) operation;
VACUUM (ANALYZE) entry;
CHECKPOINT;
