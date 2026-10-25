#!/usr/bin/env bash
#
# RivetLink relay server installer.
#
# Writes a .env with strong random secrets, pulls the images and starts the
# stack. Caddy then fetches the HTTPS certificate for your domain by itself.
# Safe to re-run: an existing .env keeps its secrets.
#
# Usage:
#   ./install.sh --domain relay.example.com --email you@example.com
#   ./install.sh                     # re-run with the settings already in .env
#   ./install.sh --rotate-jwt        # new JWT_SECRET (everyone logs in again)
#   ./install.sh --with-turn         # also start coturn (STUN for direct connections)
#
set -euo pipefail

cd "$(dirname "$0")"

ROTATE_JWT=0
WITH_TURN=0
DOMAIN=""
EMAIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)     DOMAIN="${2:-}"; shift 2 ;;
    --email)      EMAIL="${2:-}"; shift 2 ;;
    --rotate-jwt) ROTATE_JWT=1; shift ;;
    --with-turn)  WITH_TURN=1; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ── Preflight ───────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not installed. See README step 2." >&2; exit 1; }
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: 'docker compose' plugin not found. See README step 2." >&2
  exit 1
fi
command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl required to generate secrets." >&2; exit 1; }

# Values end up in sed expressions and in the Caddyfile; keep them plain.
if [[ -n "$DOMAIN" && ! "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "ERROR: --domain must be a plain hostname like relay.example.com" >&2; exit 1
fi
if [[ -n "$EMAIL" && ! "$EMAIL" =~ ^[^[:space:]|]+@[^[:space:]|]+$ ]]; then
  echo "ERROR: --email must be an e-mail address" >&2; exit 1
fi

# Set KEY=VALUE in .env, adding the line if the template predates it.
set_var() {
  if grep -q "^$1=" .env; then
    sed -i "s|^$1=.*|$1=$2|" .env
  else
    printf '%s=%s\n' "$1" "$2" >> .env
  fi
}

# ── Generate / update .env ──────────────────────────────────────────────────
if [[ -f .env ]]; then
  echo "✓ .env already exists — keeping its secrets."
else
  if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
    echo "ERROR: first run needs --domain and --email (see README step 4)." >&2; exit 1
  fi
  cp .env.example .env
  chmod 600 .env
  set_var POSTGRES_PASSWORD "$(openssl rand -hex 24)"
  set_var JWT_SECRET "$(openssl rand -base64 32)"
  echo "✓ wrote .env with fresh random POSTGRES_PASSWORD and JWT_SECRET (chmod 600)."
fi
[[ -n "$DOMAIN" ]] && set_var DOMAIN "$DOMAIN"
[[ -n "$EMAIL" ]] && set_var ACME_EMAIL "$EMAIL"
if [[ $ROTATE_JWT -eq 1 ]]; then
  cp .env ".env.bak.$(date +%s)"
  set_var JWT_SECRET "$(openssl rand -base64 32)"
  echo "✓ new JWT_SECRET (old .env backed up). Everyone has to log in again."
fi

DOMAIN="$(grep '^DOMAIN=' .env | cut -d= -f2)"
if [[ -z "$DOMAIN" || "$DOMAIN" == "relay.example.com" ]]; then
  echo "ERROR: set your domain: ./install.sh --domain relay.yourdomain.com" >&2; exit 1
fi
if [[ -z "$(grep '^ACME_EMAIL=' .env | cut -d= -f2)" ]]; then
  echo "ERROR: set an e-mail for Let's Encrypt: ./install.sh --email you@example.com" >&2; exit 1
fi

# ── TURN config (--with-turn) ───────────────────────────────────────────────
# coturn/turnserver.conf is a committed template; render the real config with a
# per-install secret into coturn/turnserver.local.conf (gitignored), which is
# what docker-compose mounts. The secret is kept in .env so re-runs are stable.
PROFILES=()
if [[ $WITH_TURN -eq 1 ]]; then
  if ! grep -qE '^TURN_SECRET=.+' .env; then
    set_var TURN_SECRET "$(openssl rand -hex 32)"
    echo "✓ generated TURN_SECRET in .env."
  fi
  TURN_SECRET="$(grep '^TURN_SECRET=' .env | cut -d= -f2)"
  sed -e "s|^static-auth-secret=.*|static-auth-secret=${TURN_SECRET}|" \
      -e "s|^realm=.*|realm=${DOMAIN}|" \
      coturn/turnserver.conf > coturn/turnserver.local.conf
  # 644, not 600: the coturn image runs as `nobody` and must read the mount.
  chmod 644 coturn/turnserver.local.conf
  echo "✓ wrote coturn/turnserver.local.conf (realm=${DOMAIN})."
  if ! grep -qE '^STUN_SERVER=.+' .env; then
    set_var STUN_SERVER "${DOMAIN}:3478"
    echo "✓ set STUN_SERVER=${DOMAIN}:3478 (open UDP 3478 in your firewall)."
  fi
  PROFILES+=(--profile turn)
fi

# ── Launch ──────────────────────────────────────────────────────────────────
echo
echo "→ pulling images…"
docker compose "${PROFILES[@]}" pull
echo "→ starting stack…"
docker compose "${PROFILES[@]}" up -d

echo
echo "→ waiting for https://${DOMAIN}/health (Caddy is fetching the certificate)…"
for _ in $(seq 60); do
  if curl -fsS "https://${DOMAIN}/health" >/dev/null 2>&1; then
    echo "✓ RivetLink relay is up at https://${DOMAIN}"
    echo
    echo "Next: create your account — ./scripts/create-account.sh  (README step 5)"
    exit 0
  fi
  sleep 3
done
echo "⚠  https://${DOMAIN}/health did not answer within 3 minutes."
echo "   Check that DNS for ${DOMAIN} points here and ports 80/443 are open,"
echo "   then look at: docker compose logs caddy relay"
exit 1
