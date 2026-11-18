#!/usr/bin/env bash
# The spike's load scenarios. Usage: scripts/scenario.sh <scenario>
#   warmup     organic mix, 1,500/s, 60 s
#   sustained  organic mix, 1,500/s, 300 s, plus the batch wallet at 70 writes/s and lock-wait sampling
#   burst      organic mix, 1,500/s, 90 s, plus 6,100/s more on 12 connections from 40 s to 50 s (7,600/s total)
#   ceiling    organic mix, unthrottled, 64 clients, 60 s
#   race       near-limit wallets and in-flight duplicate keys only, unthrottled, 32 clients, 60 s
#   prune      organic mix, 1,500/s, 180 s, deleting expired idempotency keys in batches from 60 s
#   archive    organic mix, 1,500/s, 240 s, archiving and dropping August from 60 s
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p "results/${1:?scenario}"

MIX="-f /bench/payment.sql@60 -f /bench/topup.sql@22 -f /bench/transfer.sql@5 -f /bench/reversal.sql@4
     -f /bench/retry.sql@5 -f /bench/dup.sql@2 -f /bench/race_payment.sql@1 -f /bench/race_topup.sql@1"
NAMES=payment,topup,transfer,reversal,retry,dup,race_pay,race_topup
RUN=$(date +%s)
psql_db() { docker exec -i tourist-spike-db psql -U wallet -d wallet -v ON_ERROR_STOP=1 "$@"; }
organic() { scripts/pgbench.sh "$1" organic "$RUN" $MIX -c 32 -j 4 "${@:2}"; }

case $1 in
  warmup)
    organic warmup -R 1500 -T 60 > results/warmup/pgbench.txt 2>&1 || true
    ;;
  sustained)
    D=sustained; mkdir -p results/$D
    scripts/waits.sh $D 3000 &
    scripts/pgbench.sh $D hot $((RUN + 1)) -f /bench/hot_payment.sql@1 -f /bench/hot_topup.sql@1 \
      -c 8 -j 1 -R 70 -T 300 > results/$D/hot.txt 2>&1 &
    organic $D -R 1500 -T 300 > results/$D/organic.txt 2>&1
    wait
    ;;
  burst)
    D=burst; mkdir -p results/$D
    organic $D -R 1500 -T 90 > results/$D/organic.txt 2>&1 &
    sleep 40
    scripts/pgbench.sh $D burst $((RUN + 1)) $MIX -c 12 -j 4 -R 6100 -T 10 > results/$D/burst.txt 2>&1
    wait
    ;;
  ceiling)
    D=ceiling; mkdir -p results/$D
    organic $D -c 64 -j 8 -T 60 > results/$D/organic.txt 2>&1
    ;;
  race)
    D=race; mkdir -p results/$D
    scripts/pgbench.sh $D race "$RUN" -D dpool=20 -f /bench/race_payment.sql@4 -f /bench/race_topup.sql@3 \
      -f /bench/dup.sql@3 -c 32 -j 4 -T 60 > results/$D/race.txt 2>&1
    ;;
  prune)
    D=prune; mkdir -p results/$D
    organic $D -R 1500 -T 180 > results/$D/organic.txt 2>&1 &
    sleep 60
    psql_db -q < sql/prune_keys.sql > results/$D/prune.txt 2>&1
    wait
    ;;
  archive)
    D=archive; mkdir -p results/$D
    organic $D -R 1500 -T 240 > results/$D/organic.txt 2>&1 &
    sleep 60
    scripts/archive.sh 2026-08-01 > results/$D/archive.txt 2>&1
    wait
    ;;
  *) echo "unknown scenario $1" >&2; exit 2 ;;
esac
echo "$NAMES" > results/$1/scripts.txt
date -u +%FT%TZ > results/$1/finished_at.txt
