#!/usr/bin/env bash
# Archive one month (D7): wallet balances, counterpart totals, then detach and
# drop its partitions. Exporting the rows to cold storage is out of scope.
# Usage: scripts/archive.sh 2026-08-01
set -euo pipefail
M=$1
P=$(date -d "$M" +%Y%m)
docker exec -i tourist-spike-db psql -U wallet -d wallet -v ON_ERROR_STOP=1 <<SQL
\timing on
\echo step 1: wallet balances
CALL archive_wallet_balances('$M');
\echo step 2: counterpart totals
CALL archive_counterparts('$M');
\echo step 3: detach
ALTER TABLE entry DETACH PARTITION entry_$P CONCURRENTLY;
ALTER TABLE operation DETACH PARTITION operation_$P CONCURRENTLY;
\echo step 4: drop
DROP TABLE entry_$P;
DROP TABLE operation_$P;
SQL
