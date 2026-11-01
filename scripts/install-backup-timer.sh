#!/usr/bin/env bash
#
# Install a systemd timer that runs scripts/backup.sh every day.
#
# The backup runs as the user who called sudo (they must be in the docker
# group), so the backups and the ssh key for BACKUP_REMOTE are that user's.
# A missed run (server off at night) runs at the next boot. Safe to re-run.
#
# Usage:
#   sudo ./scripts/install-backup-timer.sh
#   systemctl list-timers rivetlink-backup.timer     # next run
#   sudo journalctl -u rivetlink-backup.service      # past runs
#
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $EUID -eq 0 ]] || { echo "ERROR: run with sudo." >&2; exit 1; }
dir="$(pwd -P)"
[[ "$dir" =~ ^[A-Za-z0-9._/-]+$ ]] \
  || { echo "ERROR: move the repository to a path without spaces or special characters." >&2; exit 1; }
user="${SUDO_USER:-root}"

cat > /etc/systemd/system/rivetlink-backup.service <<EOF
[Unit]
Description=RivetLink relay database backup
Wants=docker.service
After=docker.service

[Service]
Type=oneshot
# A hung offsite copy must not block every later run.
TimeoutStartSec=1h
User=${user}
WorkingDirectory=${dir}
ExecStart=${dir}/scripts/backup.sh
EOF

cat > /etc/systemd/system/rivetlink-backup.timer <<'EOF'
[Unit]
Description=Daily RivetLink relay database backup

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now rivetlink-backup.timer
echo "✓ daily backup installed (runs as ${user}). Test it now with:"
echo "  sudo systemctl start rivetlink-backup.service && sudo journalctl -u rivetlink-backup.service -n 20"
