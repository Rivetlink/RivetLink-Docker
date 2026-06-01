#!/usr/bin/env bash
#
# Obtain a Let's Encrypt certificate for the relay's domain using certbot in
# standalone mode, then copy it into ./certs where the nginx profile expects it.
#
# Requires port 80 to be free (stop the nginx profile first if it's running).
#
# Usage:
#   ./scripts/obtain-cert.sh relay.example.com you@example.com
#
set -euo pipefail
cd "$(dirname "$0")/.."

DOMAIN="${1:?usage: obtain-cert.sh <domain> <email>}"
EMAIL="${2:?usage: obtain-cert.sh <domain> <email>}"

mkdir -p certs certbot/etc certbot/var

echo "→ stopping nginx (frees port 80) if running…"
docker compose --profile tls stop nginx 2>/dev/null || true

echo "→ requesting certificate for ${DOMAIN}…"
docker run --rm \
  -p 80:80 \
  -v "$PWD/certbot/etc:/etc/letsencrypt" \
  -v "$PWD/certbot/var:/var/lib/letsencrypt" \
  certbot/certbot certonly --standalone \
    --non-interactive --agree-tos \
    --email "$EMAIL" \
    -d "$DOMAIN"

echo "→ copying cert into ./certs…"
cp "certbot/etc/live/${DOMAIN}/fullchain.pem" certs/fullchain.pem
cp "certbot/etc/live/${DOMAIN}/privkey.pem"   certs/privkey.pem

echo "✓ certs/fullchain.pem and certs/privkey.pem are ready."
echo "  Bring TLS up:   docker compose --profile tls up -d"
echo
echo "Renewal (cron, ~monthly):"
echo "  ./scripts/obtain-cert.sh ${DOMAIN} ${EMAIL} && docker compose --profile tls restart nginx"
