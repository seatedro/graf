#!/usr/bin/env bash
# Local Postgres 17 + pgvector for graf development and integration tests.
#
#   nix run .#devdb            start (same as "up")
#   nix run .#devdb -- down    stop
#   scripts/devdb.sh <cmd>     without Nix, if initdb/pg_ctl and pgvector are installed
#
# Commands: up | down | status | env | psql | reset
# Data lives in $GRAF_DEVDB_DIR (default ./.graf/devdb); port is $GRAF_DEVDB_PORT (default 54329).
set -euo pipefail

root="${GRAF_DEVDB_DIR:-$PWD/.graf/devdb}"
port="${GRAF_DEVDB_PORT:-54329}"
data="$root/data"
log="$root/postgres.log"

url() { echo "postgres://graf@127.0.0.1:$port/$1"; }

running() { pg_ctl -D "$data" status >/dev/null 2>&1; }

print_env() {
  echo "export GRAF_DATABASE_URL=$(url graf)"
  echo "export GRAF_TEST_DATABASE_URL=$(url graf_test)"
}

up() {
  if [ ! -f "$data/PG_VERSION" ]; then
    mkdir -p "$root"
    initdb -D "$data" -U graf --auth=trust --encoding=UTF8 --no-locale >/dev/null
  fi
  if ! running; then
    pg_ctl -D "$data" -l "$log" -w \
      -o "-p $port -c listen_addresses=127.0.0.1 -k $root" start >/dev/null
  fi
  for db in graf graf_test; do
    if ! psql "$(url postgres)" -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1; then
      psql "$(url postgres)" -qc "CREATE DATABASE $db" >/dev/null
    fi
  done
  echo "Postgres is up on 127.0.0.1:$port (data: $data). Add to your shell:" >&2
  print_env
}

down() {
  if running; then pg_ctl -D "$data" -m fast -w stop >/dev/null; fi
  echo "Postgres stopped." >&2
}

case "${1:-up}" in
  up) up ;;
  down) down ;;
  status) if running; then echo "running on 127.0.0.1:$port"; else echo "stopped"; exit 1; fi ;;
  env) print_env ;;
  psql) shift; exec psql "$(url graf)" "$@" ;;
  reset) down; rm -rf "$root"; up ;;
  *) echo "usage: devdb.sh [up|down|status|env|psql|reset]" >&2; exit 2 ;;
esac
