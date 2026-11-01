#!/usr/bin/env bash
#
# Back up the relay database, with the .env that belongs to it.
#
# Writes backups/rivet-YYYY-MM-DD_HHMM.sql.gz and backups/rivet-YYYY-MM-DD_HHMM.env
# (directory 700, files 600), deletes local backups older than
# BACKUP_RETENTION_DAYS (default 14), and copies the new pair to
# BACKUP_REMOTE (an rsync/scp target such as user@host:rivetlink-backups/)
# when that is set in .env. Any failure exits non-zero, so a systemd timer or
# cron job reports it.
#
# Usage:
#   ./scripts/backup.sh
#   sudo ./scripts/install-backup-timer.sh     # run it every day
#
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "ERROR: .env not found — run ./install.sh first." >&2; exit 1; }

# Value of KEY in .env without surrounding quotes, empty when missing.
env_var() {
  grep -m1 "^$1=" .env | cut -d= -f2- | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/" || true
}

RETENTION_DAYS="$(env_var BACKUP_RETENTION_DAYS)"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] \
  || { echo "ERROR: BACKUP_RETENTION_DAYS must be a whole number of days." >&2; exit 1; }
REMOTE="$(env_var BACKUP_REMOTE)"

umask 077
mkdir -p backups
chmod 700 backups

name="backups/rivet-$(date +%F_%H%M)"
dump="${name}.sql.gz"
partial="${dump}.partial"
trap 'rm -f "$partial"' EXIT

# Right after boot (a missed timer run) postgres may still be starting.
for _ in $(seq 30); do
  docker compose exec -T postgres pg_isready -qU rivet -d rivet 2>/dev/null && break
  sleep 5
done

# A partial file never gets the final name, so a failed dump is never kept as
# if it were good.
docker compose exec -T postgres pg_dump -U rivet rivet | gzip > "$partial"
mv "$partial" "$dump"
cp .env "${name}.env"
chmod 600 "$dump" "${name}.env"
echo "✓ wrote $dump and ${name}.env"

find backups -maxdepth 1 -type f \( -name 'rivet-*.sql.gz' -o -name 'rivet-*.env' \) \
  -mtime "+${RETENTION_DAYS}" -print -delete

if [[ -n "$REMOTE" ]]; then
  # Never wait for a password, and give up on a dead link instead of hanging.
  SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=4"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a -e "ssh ${SSH_OPTS}" "$dump" "${name}.env" "$REMOTE"
  else
    # shellcheck disable=SC2086 # SSH_OPTS is a list of options
    scp -pq ${SSH_OPTS} "$dump" "${name}.env" "$REMOTE"
  fi
  echo "✓ copied to $REMOTE"
fi
