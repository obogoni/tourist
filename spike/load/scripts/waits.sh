#!/usr/bin/env bash
# Sample backends every 100 ms: how many wait on a lock, by application name.
# Usage: scripts/waits.sh <result-dir> <samples>
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p "results/$1"
docker exec -i tourist-spike-db psql -U wallet -d wallet -At -F, > "results/$1/waits.csv" <<SQL

SELECT extract(epoch FROM clock_timestamp())::numeric(16,3),
       count(*) FILTER (WHERE state = 'active'),
       count(*) FILTER (WHERE wait_event_type = 'Lock'),
       count(*) FILTER (WHERE wait_event_type = 'Lock' AND application_name = 'hot'),
       count(*) FILTER (WHERE application_name = 'hot' AND state = 'active'),
       string_agg(DISTINCT wait_event, '|') FILTER (WHERE wait_event_type = 'Lock')
FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
\\watch interval=0.1 count=$2
SQL
