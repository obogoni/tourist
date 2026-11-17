-- Maintenance jobs: pruning expired idempotency keys, and archiving a month (D7).

-- Batched DELETE from the unpartitioned key table, one commit per batch.
CREATE PROCEDURE prune_idempotency_keys(p_before timestamptz, p_batch int DEFAULT 5000)
LANGUAGE plpgsql AS $$
DECLARE
  n       bigint;
  total   bigint := 0;
  batches int := 0;
  started timestamptz := clock_timestamp();
BEGIN
  LOOP
    DELETE FROM idempotency_key
    WHERE ctid IN (SELECT ctid FROM idempotency_key WHERE created_at < p_before LIMIT p_batch);
    GET DIAGNOSTICS n = ROW_COUNT;
    total := total + n;
    batches := batches + 1;
    COMMIT;
    EXIT WHEN n < p_batch;
  END LOOP;
  RAISE NOTICE 'pruned % keys in % batches, % s', total, batches,
    round(extract(epoch FROM clock_timestamp() - started)::numeric, 1);
END $$;

-- Step 1 of archiving a month: each wallet with entries in it records the
-- balance and seq of its last entry there. Batches of wallets, one commit each.
-- Invariants 2 and 3 count only entries with seq > archived_seq, so they hold
-- before, during and after the partition is dropped.
CREATE PROCEDURE archive_wallet_balances(p_month date, p_batch int DEFAULT 10000)
LANGUAGE plpgsql AS $$
DECLARE
  part    text := 'entry_' || to_char(p_month, 'YYYYMM');
  lo      bigint := 0;
  hi      bigint;
  n       bigint;
  total   bigint := 0;
  started timestamptz := clock_timestamp();
BEGIN
  LOOP
    EXECUTE format('SELECT max(account_id) FROM (SELECT DISTINCT account_id FROM %I
                    WHERE seq IS NOT NULL AND account_id > $1 ORDER BY account_id LIMIT $2) x', part)
      INTO hi USING lo, p_batch;
    EXIT WHEN hi IS NULL;
    EXECUTE format('UPDATE wallet w SET archived_balance = x.balance_after, archived_seq = x.seq
                    FROM (SELECT DISTINCT ON (account_id) account_id, seq, balance_after FROM %I
                          WHERE seq IS NOT NULL AND account_id > $1 AND account_id <= $2
                          ORDER BY account_id, seq DESC) x
                    WHERE w.wallet_id = x.account_id AND w.archived_seq < x.seq', part)
      USING lo, hi;
    GET DIAGNOSTICS n = ROW_COUNT;
    total := total + n;
    COMMIT;
    lo := hi;
  END LOOP;
  RAISE NOTICE 'archived balances of % wallets, % s', total,
    round(extract(epoch FROM clock_timestamp() - started)::numeric, 1);
END $$;

-- Step 2: counterpart totals and the start of the online window move together,
-- so invariant 5 holds on either side of the commit.
CREATE PROCEDURE archive_counterparts(p_month date)
LANGUAGE plpgsql AS $$
DECLARE
  part text := 'entry_' || to_char(p_month, 'YYYYMM');
BEGIN
  PERFORM 1 FROM archive_state WHERE online_from = p_month FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'online window does not start at %', p_month;
  END IF;
  EXECUTE format('UPDATE ledger_account a SET archived_total = a.archived_total + s.total
                  FROM (SELECT account_id, sum(amount) AS total FROM %I
                        WHERE seq IS NULL GROUP BY account_id) s
                  WHERE a.account_id = s.account_id', part);
  UPDATE archive_state SET online_from = p_month + interval '1 month';
END $$;
