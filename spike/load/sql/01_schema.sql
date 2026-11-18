-- Wallet core schema for the load spike (#3), from .design/wallet-core.md.
-- Tables are created bare; 03_indexes.sql adds keys and indexes after the seed.

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE TABLE tenant (
  tenant_id int  PRIMARY KEY,
  timezone  text NOT NULL DEFAULT 'America/Sao_Paulo'
);

CREATE TABLE payment_method (
  method_id     int     PRIMARY KEY,
  tenant_id     int     NOT NULL REFERENCES tenant,
  name          text    NOT NULL,
  is_refundable boolean NOT NULL
);

-- Wallets and counterpart accounts share one id space (D1).
CREATE SEQUENCE account_id_seq;

-- Counterpart accounts keep no balance (D2). archived_total is written only by
-- the archive job, once per archived month, so it never becomes a hot row.
CREATE TABLE ledger_account (
  account_id     bigint PRIMARY KEY DEFAULT nextval('account_id_seq'),
  tenant_id      int    NOT NULL REFERENCES tenant,
  kind           text   NOT NULL CHECK (kind IN ('cash', 'revenue', 'refunds_paid')),
  method_id      int    REFERENCES payment_method,
  archived_total bigint NOT NULL DEFAULT 0,
  UNIQUE NULLS NOT DISTINCT (tenant_id, kind, method_id)
);

-- No CHECK on balance >= -credit_limit on purpose: D3 enforces it in the
-- conditional UPDATE, and the spike must be able to see a violation.
CREATE TABLE wallet (
  wallet_id        bigint      PRIMARY KEY DEFAULT nextval('account_id_seq'),
  tenant_id        int         NOT NULL REFERENCES tenant,
  kind             text        NOT NULL CHECK (kind IN ('prepaid', 'postpaid')),
  status           text        NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'blocked', 'inactive')),
  credit_limit     bigint      NOT NULL DEFAULT 0 CHECK (credit_limit >= 0),
  daily_limit      bigint,
  balance          bigint      NOT NULL DEFAULT 0,
  last_seq         bigint      NOT NULL DEFAULT 0,
  spent_day        date,
  spent_today      bigint      NOT NULL DEFAULT 0,
  archived_balance bigint      NOT NULL DEFAULT 0,
  archived_seq     bigint      NOT NULL DEFAULT 0,
  created_at       timestamptz NOT NULL DEFAULT now()
) WITH (fillfactor = 80);  -- room for HOT updates: balance is not indexed

-- CACHE: nextval locks the sequence page; uncached it was the top LWLock wait.
-- Ids are then not in commit order across sessions; wallets order by seq.
CREATE SEQUENCE operation_id_seq CACHE 100;
CREATE SEQUENCE entry_id_seq CACHE 100;

CREATE TABLE operation (
  operation_id             bigint      NOT NULL,
  created_at               timestamptz NOT NULL,
  tenant_id                int         NOT NULL,
  kind                     text        NOT NULL CHECK (kind IN ('topup', 'payment', 'reversal', 'transfer')),
  status                   text        NOT NULL CHECK (status IN ('completed', 'rejected')),
  idempotency_key          text        NOT NULL,
  request_hash             bytea       NOT NULL,
  response                 jsonb       NOT NULL,
  reverses_operation_id    bigint,
  reversed_by_operation_id bigint
) PARTITION BY RANGE (created_at);

CREATE TABLE entry (
  entry_id      bigint      NOT NULL,
  created_at    timestamptz NOT NULL,
  operation_id  bigint      NOT NULL,
  tenant_id     int         NOT NULL,
  account_id    bigint      NOT NULL,
  amount        bigint      NOT NULL CHECK (amount <> 0),  -- D6
  seq           bigint,                                    -- wallet entries only (D5)
  balance_after bigint,
  CHECK ((seq IS NULL) = (balance_after IS NULL))
) PARTITION BY RANGE (created_at);

-- Unpartitioned, so the unique key holds across months (D4).
CREATE TABLE idempotency_key (
  tenant_id            int         NOT NULL,
  key                  text        NOT NULL,
  request_hash         bytea       NOT NULL,
  operation_id         bigint      NOT NULL,
  operation_created_at timestamptz NOT NULL,
  created_at           timestamptz NOT NULL
);

-- Start of the online window: counterpart entries older than this were
-- archived and are summed in ledger_account.archived_total.
CREATE TABLE archive_state (
  one         boolean     PRIMARY KEY DEFAULT true CHECK (one),
  online_from timestamptz NOT NULL
);

CREATE FUNCTION create_month_partitions(p_from date, p_to date) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  m date := date_trunc('month', p_from);
BEGIN
  WHILE m <= p_to LOOP
    EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF operation FOR VALUES FROM (%L) TO (%L)',
                   'operation_' || to_char(m, 'YYYYMM'), m::timestamptz, (m + interval '1 month')::timestamptz);
    EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF entry FOR VALUES FROM (%L) TO (%L)',
                   'entry_' || to_char(m, 'YYYYMM'), m::timestamptz, (m + interval '1 month')::timestamptz);
    m := m + interval '1 month';
  END LOOP;
END $$;
