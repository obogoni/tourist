#!/usr/bin/env bash
# Run pgbench against the spike database from its own container.
# Usage: scripts/pgbench.sh <result-dir> <app-name> <run-id> [pgbench args...]
# Per-transaction logs land in results/<result-dir>/<app-name>.*; the latency
# in them counts from the scheduled start, so it includes queueing under -R.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=$1 APP=$2 RUN=$3; shift 3
mkdir -p "results/$DIR"
exec docker run --rm --user "$(id -u):$(id -g)" --network container:tourist-spike-db \
  -e PGPASSWORD=wallet -e PGAPPNAME="$APP" \
  -v "$PWD/bench:/bench:ro" -v "$PWD/results/$DIR:/out" -w /out \
  postgres:17 pgbench -h 127.0.0.1 -U wallet -d wallet -n -M prepared \
  -D nw=1000000 -D nt=100 -D run="$RUN" -D n=0 -D dpool=50000 \
  -D pt=1 -D pw=1000000 -D pamt=100 -D pn=0 -D last_op=0 \
  -l --log-prefix="$APP" "$@"
