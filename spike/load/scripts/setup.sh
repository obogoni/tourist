#!/usr/bin/env bash
# Recreate the database from scratch: schema, write path, seed, indexes.
# Usage: scripts/setup.sh [wallets] [tenants]
set -euo pipefail
cd "$(dirname "$0")/.."
WALLETS=${1:-1000000}
TENANTS=${2:-100}

docker compose down -v >/dev/null 2>&1 || true
docker compose up -d
until docker exec tourist-spike-db pg_isready -U wallet -d wallet -q; do sleep 1; done
sleep 2

psql_db() { docker exec -i tourist-spike-db psql -U wallet -d wallet -v ON_ERROR_STOP=1 "$@"; }
psql_db -q < sql/01_schema.sql
psql_db -q < sql/02_operations.sql
psql_db -q < sql/05_maintenance.sql
psql_db -v wallets="$WALLETS" -v tenants="$TENANTS" < sql/03_seed.sql
psql_db < sql/04_indexes.sql
psql_db -c "SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) FROM pg_class WHERE relname IN ('wallet','idempotency_key') OR relname LIKE 'entry\_2%' OR relname LIKE 'operation\_2%' ORDER BY relname;"
