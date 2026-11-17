-- Write path: top-up, payment, reversal and transfer, each one transaction.
-- Every function takes p_at (default now()) so tests can write into any month.

-- D4: claim the key before touching a wallet. A concurrent duplicate blocks on
-- the unique index until the first transaction ends, then reads its response.
-- Returns NULL when the key is new, otherwise the response to give back.
CREATE FUNCTION claim_key(p_tenant int, p_key text, p_hash bytea, p_operation bigint, p_at timestamptz)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  k idempotency_key;
  r jsonb;
BEGIN
  INSERT INTO idempotency_key (tenant_id, key, request_hash, operation_id, operation_created_at, created_at)
  VALUES (p_tenant, p_key, p_hash, p_operation, p_at, p_at)
  ON CONFLICT (tenant_id, key) DO NOTHING;
  IF FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO k FROM idempotency_key WHERE tenant_id = p_tenant AND key = p_key;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'idempotency key % pruned while claiming it; retry', p_key;
  END IF;
  IF k.request_hash <> p_hash THEN
    RETURN jsonb_build_object('status', 'refused', 'reason', 'key_reused_with_different_request');
  END IF;
  SELECT response INTO r FROM operation
  WHERE operation_id = k.operation_id AND created_at = k.operation_created_at;
  RETURN r || '{"replayed": true}';
END $$;

-- A rejection is an operation without entries, kept as the key's response.
CREATE FUNCTION reject(p_operation bigint, p_tenant int, p_kind text, p_key text, p_hash bytea,
                       p_at timestamptz, p_reason text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_resp jsonb := jsonb_build_object('operation_id', p_operation, 'status', 'rejected',
                                     'kind', p_kind, 'reason', p_reason);
BEGIN
  INSERT INTO operation (operation_id, created_at, tenant_id, kind, status, idempotency_key, request_hash, response)
  VALUES (p_operation, p_at, p_tenant, p_kind, 'rejected', p_key, p_hash, v_resp);
  RETURN v_resp;
END $$;

-- Why a conditional debit matched no row. Read without a lock: it only names the reason.
CREATE FUNCTION debit_rejection(p_tenant int, p_wallet bigint, p_amount bigint, p_day date)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN w.wallet_id IS NULL OR w.tenant_id <> p_tenant THEN 'wallet_not_found'
    WHEN w.status <> 'active' THEN 'wallet_not_active'
    WHEN w.balance - p_amount + w.credit_limit < 0 THEN 'insufficient_funds'
    WHEN p_day IS NOT NULL AND w.daily_limit IS NOT NULL THEN 'daily_limit_exceeded'
    ELSE 'concurrent_change'
  END
  FROM (SELECT 1) one LEFT JOIN wallet w ON w.wallet_id = p_wallet
$$;

CREATE FUNCTION topup(p_tenant int, p_wallet bigint, p_method int, p_amount bigint, p_key text,
                      p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op      bigint := nextval('operation_id_seq');
  v_hash    bytea  := decode(md5(concat_ws('|', 'topup', p_wallet, p_method, p_amount)), 'hex');
  v_prior   jsonb;
  v_cash    bigint;
  v_balance bigint;
  v_seq     bigint;
  v_resp    jsonb;
BEGIN
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'amount must be positive';
  END IF;
  v_prior := claim_key(p_tenant, p_key, v_hash, v_op, p_at);
  IF v_prior IS NOT NULL THEN
    RETURN v_prior;
  END IF;

  SELECT account_id INTO v_cash FROM ledger_account
  WHERE tenant_id = p_tenant AND kind = 'cash' AND method_id = p_method;
  IF NOT FOUND THEN
    RETURN reject(v_op, p_tenant, 'topup', p_key, v_hash, p_at, 'invalid_payment_method');
  END IF;

  UPDATE wallet SET balance = balance + p_amount, last_seq = last_seq + 1
  WHERE wallet_id = p_wallet AND tenant_id = p_tenant AND status = 'active'
  RETURNING balance, last_seq INTO v_balance, v_seq;
  IF NOT FOUND THEN
    RETURN reject(v_op, p_tenant, 'topup', p_key, v_hash, p_at, debit_rejection(p_tenant, p_wallet, 0, NULL));
  END IF;

  v_resp := jsonb_build_object('operation_id', v_op, 'status', 'completed', 'kind', 'topup',
                               'wallet_id', p_wallet, 'balance', v_balance, 'seq', v_seq);
  INSERT INTO operation (operation_id, created_at, tenant_id, kind, status, idempotency_key, request_hash, response)
  VALUES (v_op, p_at, p_tenant, 'topup', 'completed', p_key, v_hash, v_resp);
  INSERT INTO entry (entry_id, created_at, operation_id, tenant_id, account_id, amount, seq, balance_after) VALUES
    (nextval('entry_id_seq'), p_at, v_op, p_tenant, p_wallet,  p_amount, v_seq, v_balance),
    (nextval('entry_id_seq'), p_at, v_op, p_tenant, v_cash,   -p_amount, NULL,  NULL);
  RETURN v_resp;
END $$;

CREATE FUNCTION payment(p_tenant int, p_wallet bigint, p_amount bigint, p_key text,
                        p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op      bigint := nextval('operation_id_seq');
  v_hash    bytea  := decode(md5(concat_ws('|', 'payment', p_wallet, p_amount)), 'hex');
  v_prior   jsonb;
  v_revenue bigint;
  v_day     date;
  v_balance bigint;
  v_seq     bigint;
  v_resp    jsonb;
BEGIN
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'amount must be positive';
  END IF;
  v_prior := claim_key(p_tenant, p_key, v_hash, v_op, p_at);
  IF v_prior IS NOT NULL THEN
    RETURN v_prior;
  END IF;

  SELECT a.account_id, (p_at AT TIME ZONE t.timezone)::date INTO v_revenue, v_day
  FROM ledger_account a JOIN tenant t USING (tenant_id)
  WHERE a.tenant_id = p_tenant AND a.kind = 'revenue';

  -- D3: the limit, the daily limit and the status are decided by the statement that writes the balance.
  UPDATE wallet
  SET balance     = balance - p_amount,
      last_seq    = last_seq + 1,
      spent_today = CASE WHEN spent_day = v_day THEN spent_today ELSE 0 END + p_amount,
      spent_day   = v_day
  WHERE wallet_id = p_wallet AND tenant_id = p_tenant AND status = 'active'
    AND balance - p_amount + credit_limit >= 0
    AND (daily_limit IS NULL
         OR CASE WHEN spent_day = v_day THEN spent_today ELSE 0 END + p_amount <= daily_limit)
  RETURNING balance, last_seq INTO v_balance, v_seq;
  IF NOT FOUND THEN
    RETURN reject(v_op, p_tenant, 'payment', p_key, v_hash, p_at,
                  debit_rejection(p_tenant, p_wallet, p_amount, v_day));
  END IF;

  v_resp := jsonb_build_object('operation_id', v_op, 'status', 'completed', 'kind', 'payment',
                               'wallet_id', p_wallet, 'balance', v_balance, 'seq', v_seq);
  INSERT INTO operation (operation_id, created_at, tenant_id, kind, status, idempotency_key, request_hash, response)
  VALUES (v_op, p_at, p_tenant, 'payment', 'completed', p_key, v_hash, v_resp);
  INSERT INTO entry (entry_id, created_at, operation_id, tenant_id, account_id, amount, seq, balance_after) VALUES
    (nextval('entry_id_seq'), p_at, v_op, p_tenant, p_wallet, -p_amount, v_seq, v_balance),
    (nextval('entry_id_seq'), p_at, v_op, p_tenant, v_revenue, p_amount, NULL,  NULL);
  RETURN v_resp;
END $$;

-- D3: both wallets are locked in wallet_id order before either is written.
CREATE FUNCTION transfer(p_tenant int, p_from bigint, p_to bigint, p_amount bigint, p_key text,
                         p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op       bigint := nextval('operation_id_seq');
  v_hash     bytea  := decode(md5(concat_ws('|', 'transfer', p_from, p_to, p_amount)), 'hex');
  v_prior    jsonb;
  v_dest     wallet;
  v_from_bal bigint;
  v_from_seq bigint;
  v_to_bal   bigint;
  v_to_seq   bigint;
  v_resp     jsonb;
BEGIN
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'amount must be positive';
  END IF;
  v_prior := claim_key(p_tenant, p_key, v_hash, v_op, p_at);
  IF v_prior IS NOT NULL THEN
    RETURN v_prior;
  END IF;
  IF p_from = p_to THEN
    RETURN reject(v_op, p_tenant, 'transfer', p_key, v_hash, p_at, 'same_wallet');
  END IF;

  PERFORM 1 FROM wallet WHERE wallet_id IN (p_from, p_to) ORDER BY wallet_id FOR UPDATE;

  SELECT * INTO v_dest FROM wallet WHERE wallet_id = p_to;
  IF NOT FOUND OR v_dest.tenant_id <> p_tenant THEN
    RETURN reject(v_op, p_tenant, 'transfer', p_key, v_hash, p_at, 'destination_not_found');
  ELSIF v_dest.status <> 'active' THEN
    RETURN reject(v_op, p_tenant, 'transfer', p_key, v_hash, p_at, 'destination_not_active');
  END IF;

  UPDATE wallet SET balance = balance - p_amount, last_seq = last_seq + 1
  WHERE wallet_id = p_from AND tenant_id = p_tenant AND status = 'active'
    AND balance - p_amount + credit_limit >= 0
  RETURNING balance, last_seq INTO v_from_bal, v_from_seq;
  IF NOT FOUND THEN
    RETURN reject(v_op, p_tenant, 'transfer', p_key, v_hash, p_at,
                  debit_rejection(p_tenant, p_from, p_amount, NULL));
  END IF;

  UPDATE wallet SET balance = balance + p_amount, last_seq = last_seq + 1
  WHERE wallet_id = p_to
  RETURNING balance, last_seq INTO v_to_bal, v_to_seq;

  v_resp := jsonb_build_object('operation_id', v_op, 'status', 'completed', 'kind', 'transfer',
                               'wallet_id', p_from, 'balance', v_from_bal, 'seq', v_from_seq);
  INSERT INTO operation (operation_id, created_at, tenant_id, kind, status, idempotency_key, request_hash, response)
  VALUES (v_op, p_at, p_tenant, 'transfer', 'completed', p_key, v_hash, v_resp);
  INSERT INTO entry (entry_id, created_at, operation_id, tenant_id, account_id, amount, seq, balance_after) VALUES
    (nextval('entry_id_seq'), p_at, v_op, p_tenant, p_from, -p_amount, v_from_seq, v_from_bal),
    (nextval('entry_id_seq'), p_at, v_op, p_tenant, p_to,    p_amount, v_to_seq,   v_to_bal);
  RETURN v_resp;
END $$;

-- Full reversal of a top-up or payment, at most once (D4). The original
-- operation row is locked first, so two reversals of it serialize there.
-- The original is found by id without its month, so every online partition is probed.
CREATE FUNCTION reversal(p_tenant int, p_original bigint, p_key text, p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op      bigint := nextval('operation_id_seq');
  v_hash    bytea  := decode(md5(concat_ws('|', 'reversal', p_original)), 'hex');
  v_prior   jsonb;
  v_orig    operation;
  v_wleg    entry;
  v_cleg    entry;
  v_balance bigint;
  v_seq     bigint;
  v_resp    jsonb;
BEGIN
  v_prior := claim_key(p_tenant, p_key, v_hash, v_op, p_at);
  IF v_prior IS NOT NULL THEN
    RETURN v_prior;
  END IF;

  SELECT * INTO v_orig FROM operation
  WHERE operation_id = p_original AND tenant_id = p_tenant
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN reject(v_op, p_tenant, 'reversal', p_key, v_hash, p_at, 'original_not_found');
  ELSIF v_orig.status <> 'completed' OR v_orig.kind NOT IN ('topup', 'payment') THEN
    RETURN reject(v_op, p_tenant, 'reversal', p_key, v_hash, p_at, 'original_not_reversible');
  ELSIF v_orig.reversed_by_operation_id IS NOT NULL THEN
    RETURN reject(v_op, p_tenant, 'reversal', p_key, v_hash, p_at, 'already_reversed');
  END IF;

  SELECT * INTO v_wleg FROM entry
  WHERE operation_id = p_original AND created_at = v_orig.created_at AND seq IS NOT NULL;
  SELECT * INTO v_cleg FROM entry
  WHERE operation_id = p_original AND created_at = v_orig.created_at AND seq IS NULL;

  -- Reversing a top-up debits the wallet, so it is subject to the limit (D3).
  UPDATE wallet SET balance = balance - v_wleg.amount, last_seq = last_seq + 1
  WHERE wallet_id = v_wleg.account_id AND status = 'active'
    AND (v_wleg.amount < 0 OR balance - v_wleg.amount + credit_limit >= 0)
  RETURNING balance, last_seq INTO v_balance, v_seq;
  IF NOT FOUND THEN
    RETURN reject(v_op, p_tenant, 'reversal', p_key, v_hash, p_at,
                  debit_rejection(p_tenant, v_wleg.account_id, v_wleg.amount, NULL));
  END IF;

  UPDATE operation SET reversed_by_operation_id = v_op
  WHERE operation_id = p_original AND created_at = v_orig.created_at;

  v_resp := jsonb_build_object('operation_id', v_op, 'status', 'completed', 'kind', 'reversal',
                               'wallet_id', v_wleg.account_id, 'balance', v_balance, 'seq', v_seq,
                               'reverses_operation_id', p_original);
  INSERT INTO operation (operation_id, created_at, tenant_id, kind, status, idempotency_key, request_hash,
                         response, reverses_operation_id)
  VALUES (v_op, p_at, p_tenant, 'reversal', 'completed', p_key, v_hash, v_resp, p_original);
  INSERT INTO entry (entry_id, created_at, operation_id, tenant_id, account_id, amount, seq, balance_after) VALUES
    (nextval('entry_id_seq'), p_at, v_op, p_tenant, v_wleg.account_id, -v_wleg.amount, v_seq, v_balance),
    (nextval('entry_id_seq'), p_at, v_op, p_tenant, v_cleg.account_id, -v_cleg.amount, NULL,  NULL);
  RETURN v_resp;
END $$;
