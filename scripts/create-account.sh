#!/usr/bin/env bash
#
# Create a RivetLink account (with its own organization) on this relay.
#
# Registration is closed to the internet (Caddy answers 403), so accounts are
# made here, on the server, by talking to the relay over the private Docker
# network. The password is read without echo and never appears on a command
# line.
#
# Usage:
#   ./scripts/create-account.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required (apt install python3)." >&2; exit 1; }
docker compose ps --status running relay | grep -q rivetlink-relay \
  || { echo "ERROR: the relay is not running — run ./install.sh first." >&2; exit 1; }

read -rp "E-mail:            " RL_EMAIL
read -rp "Your name:         " RL_NAME
read -rp "Organization name: " RL_ORG
read -rsp "Password (12+ characters): " RL_PASSWORD; echo
read -rsp "Password again:            " RL_PASSWORD2; echo
if [[ "$RL_PASSWORD" != "$RL_PASSWORD2" ]]; then
  echo "ERROR: passwords do not match." >&2; exit 1
fi
if [[ ${#RL_PASSWORD} -lt 12 ]]; then
  echo "ERROR: use at least 12 characters." >&2; exit 1
fi
export RL_EMAIL RL_NAME RL_ORG RL_PASSWORD

python3 -c '
import json, os
print(json.dumps({
    "email": os.environ["RL_EMAIL"],
    "password": os.environ["RL_PASSWORD"],
    "display_name": os.environ["RL_NAME"],
    "organization_name": os.environ["RL_ORG"],
}))' | docker run --rm -i --network rivetlink-server_default curlimages/curl:8.23.0 \
  -fsS -o /dev/null -w '%{http_code}' -X POST http://relay:8080/auth/register \
  -H 'content-type: application/json' --data-binary @- \
  && echo " ✓ account created for ${RL_EMAIL}. Log in with it in the RivetLink app." \
  || { echo " ERROR: the relay refused the account (e-mail already used?). See: docker compose logs relay" >&2; exit 1; }
