#!/usr/bin/env bash
#
# Restore the relay database from a dump made by scripts/backup.sh.
#
# DESTRUCTIVE: every account, device and audit row is replaced by the dump.
# The dump is first loaded into a separate database in one transaction, so a
# broken dump leaves the current database untouched. Only then is the relay
# stopped for the swap and started again.
# This does not put back the .env from the backup; on a new server, do that
# first (README, Backups).
#
# Usage:
#   ./scripts/restore.sh backups/rivet-YYYY-MM-DD_HHMM.sql.gz
#
set -eEuo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <dump.sql.gz>" >&2; exit 1; }
dump="$(realpath -e -- "$1")" || { echo "ERROR: $1 not found." >&2; exit 1; }
cd "$(dirname "$0")/.."

gzip -t "$dump" || { echo "ERROR: $1 is not a readable .gz dump." >&2; exit 1; }
[[ -n "$(docker compose ps -q --status running postgres)" ]] \
  || { echo "ERROR: postgres is not running — run ./install.sh first." >&2; exit 1; }

echo "This REPLACES the relay database with $1."
echo "Accounts, devices and audit rows made after that backup are lost."
read -rp "Type 'restore' to continue: " answer
[[ "$answer" == "restore" ]] || { echo "Aborted; nothing changed."; exit 1; }

pg() { docker compose exec -T postgres psql -U rivet -v ON_ERROR_STOP=1 -q "$@"; }
trap 'echo "ERROR: restore failed. Check: docker compose ps; docker compose logs relay" >&2' ERR

pg -d postgres -c 'DROP DATABASE IF EXISTS rivet_restore' -c 'CREATE DATABASE rivet_restore OWNER rivet'
gunzip -c "$dump" | pg -1 -d rivet_restore

docker compose stop relay
pg -d postgres -c 'DROP DATABASE rivet WITH (FORCE)' -c 'ALTER DATABASE rivet_restore RENAME TO rivet'
docker compose up -d --wait --wait-timeout 120 relay
echo "✓ restored $1; the relay is running again."
