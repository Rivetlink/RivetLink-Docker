#!/usr/bin/env bash
#
# FerrumLink relay server installer.
#
# Generates a .env with strong random secrets, pulls the images, and brings the
# stack up. Idempotent: an existing .env is kept unless you pass --force.
#
# Usage:
#   ./install.sh                       # core stack (postgres + redis + relay) on :8080
#   ./install.sh --domain relay.acme.com --with-tls
#   ./install.sh --with-turn
#   ./install.sh --force               # regenerate .env (NEW secrets — invalidates old tokens)
#
set -euo pipefail

cd "$(dirname "$0")"

FORCE=0
WITH_TLS=0
WITH_TURN=0
DOMAIN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)      FORCE=1; shift ;;
    --with-tls)   WITH_TLS=1; shift ;;
    --with-turn)  WITH_TURN=1; shift ;;
    --domain)     DOMAIN="${2:-}"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ── Preflight ───────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not installed. See https://docs.docker.com/engine/install/" >&2; exit 1; }
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: 'docker compose' plugin not found. Install Docker Compose v2." >&2
  exit 1
fi
command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl required to generate secrets." >&2; exit 1; }

# ── Generate .env ───────────────────────────────────────────────────────────
if [[ -f .env && $FORCE -eq 0 ]]; then
  echo "✓ .env already exists — keeping it (pass --force to regenerate)."
else
  [[ -f .env && $FORCE -eq 1 ]] && { cp .env ".env.bak.$(date +%s)"; echo "↪ backed up old .env"; }

  POSTGRES_PASSWORD="$(openssl rand -hex 24)"
  JWT_SECRET="$(openssl rand -base64 32)"

  # Start from the template, then inject secrets and any provided domain.
  cp .env.example .env
  # Use a non-/ delimiter for sed since base64 can contain '/'.
  sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|" .env
  sed -i "s|^JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET}|" .env
  [[ -n "$DOMAIN" ]] && sed -i "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" .env

  chmod 600 .env
  echo "✓ wrote .env with fresh random POSTGRES_PASSWORD and JWT_SECRET (chmod 600)."
fi

# ── Compose profiles ────────────────────────────────────────────────────────
PROFILES=()
[[ $WITH_TLS -eq 1 ]]  && PROFILES+=(--profile tls)
[[ $WITH_TURN -eq 1 ]] && PROFILES+=(--profile turn)

if [[ $WITH_TLS -eq 1 ]]; then
  if [[ ! -s certs/fullchain.pem || ! -s certs/privkey.pem ]]; then
    echo
    echo "⚠  TLS profile selected but certs/fullchain.pem + certs/privkey.pem are missing."
    echo "   Obtain them first:   ./scripts/obtain-cert.sh \"\$DOMAIN\" you@email"
    echo "   (nginx will fail to start without them.)"
  fi
fi

# ── Launch ──────────────────────────────────────────────────────────────────
echo
echo "→ pulling images…"
docker compose "${PROFILES[@]}" pull
echo "→ starting stack…"
docker compose "${PROFILES[@]}" up -d

echo
echo "✓ FerrumLink relay is up."
docker compose "${PROFILES[@]}" ps
echo
if [[ $WITH_TLS -eq 1 ]]; then
  echo "Relay URL for the app:   wss://$(grep '^DOMAIN=' .env | cut -d= -f2)"
else
  echo "Relay URL for the app:   http://<this-host-ip>:$(grep -E '^RELAY_PORT=' .env | cut -d= -f2 || echo 8080)"
fi
echo "Health check:            curl http://localhost:$(grep -E '^RELAY_PORT=' .env | cut -d= -f2 || echo 8080)/health"
echo
echo "Next: create the first owner account — see README.md ➜ 'Bootstrap the first account'."
