\timing on
CALL prune_idempotency_keys(now() - interval '30 days');
