# FerrumLink Server — Docker Deployment

Self-host a **FerrumLink relay server** in minutes. This repo is a ready-made
Docker bundle: PostgreSQL + Redis + the relay, with optional HTTPS (nginx) and
TURN (coturn). The desktop/CLI apps connect to whatever relay you run here.

> **What is the relay?** FerrumLink is a zero-trust remote-control platform. The
> relay is *only* a signaling + fallback server — it is **never** a trusted
> authority. All session content is end-to-end encrypted; the relay sees
> ciphertext and metadata, never your screen or keystrokes. Running your own
> relay means no third party is in the path at all.

---

## Requirements

- A Linux host (VPS or your own box) with a public IP or LAN address
- [Docker Engine](https://docs.docker.com/engine/install/) + the Docker Compose v2 plugin
- `openssl` (for secret generation — preinstalled on most systems)
- For HTTPS: a domain name pointing at the host, and ports **80/443** open
- For plain/LAN use: port **8080** open

---

## Quick start (LAN / plain HTTP)

```bash
git clone https://github.com/<you>/FerrumLinkServerDocker.git
cd FerrumLinkServerDocker
./install.sh
```

That's it. `install.sh` generates a `.env` with strong random secrets, pulls the
images, and starts the stack. Verify:

```bash
curl http://localhost:8080/health      # → {"status":"ok", ...}
```

Point the FerrumLink app at `http://<this-host-ip>:8080`.

> ⚠ Plain HTTP is fine for a trusted LAN. **For anything over the internet, use
> the HTTPS setup below** — tokens and signaling should never cross the network
> in the clear.

---

## Production (HTTPS + your domain)

1. Point a DNS A/AAAA record at the host (e.g. `relay.example.com`).
2. Get a TLS certificate (Let's Encrypt, free):

   ```bash
   ./scripts/obtain-cert.sh relay.example.com you@example.com
   ```

   This drops `certs/fullchain.pem` + `certs/privkey.pem` in place.
3. Bring the stack up with the nginx TLS proxy:

   ```bash
   ./install.sh --domain relay.example.com --with-tls
   ```

The relay is now reachable at `https://relay.example.com` (and `wss://…` for the
WebSocket signaling channel). Point the app at `wss://relay.example.com`.

Behind nginx you normally don't want the raw relay port exposed — set
`RELAY_PORT=127.0.0.1:8080` in `.env` (bind to loopback only) and re-run
`docker compose --profile tls up -d`.

---

## Bootstrap the first account

A fresh relay has no users. Create the first **owner** account (this also creates
your organization). It's a single REST call to `/auth/register`:

```bash
curl -sX POST https://relay.example.com/auth/register \
  -H 'content-type: application/json' \
  -d '{
        "email": "you@example.com",
        "password": "a-long-strong-password",
        "display_name": "Your Name",
        "organization_name": "Your Org"
      }'
```

The response contains `access_token` / `refresh_token` and your `user_id` /
`organization_id`. From here on, log in from the FerrumLink app with that email +
password. The first user is the org `owner`; additional users/devices are managed
through the app and API.

> On a public relay you may want to register your owner account first, then put
> the relay behind a firewall / disable open registration. (Open-registration
> hardening is on the roadmap.)

---

## Day-2 operations

**Status / logs**
```bash
docker compose ps
docker compose logs -f relay
```

**Update to a newer relay release**
```bash
docker compose pull
docker compose up -d            # add --profile tls / --profile turn if you use them
```
DB migrations are embedded in the relay binary and apply automatically on start.

**Stop / start**
```bash
docker compose stop
docker compose up -d
```

**Back up the database**
```bash
docker compose exec postgres pg_dump -U ferrum ferrum > backup-$(date +%F).sql
```

**Restore**
```bash
cat backup-YYYY-MM-DD.sql | docker compose exec -T postgres psql -U ferrum -d ferrum
```

**Rotate secrets** — `./install.sh --force` regenerates `.env` with new secrets.
Rotating `JWT_SECRET` invalidates every issued token (everyone re-logs in).

---

## Configuration

All settings live in `.env` (generated from [`.env.example`](.env.example)).
The important ones:

| Variable            | Default                              | Meaning |
| ------------------- | ------------------------------------ | ------- |
| `POSTGRES_PASSWORD` | *(random)*                           | DB password; also woven into `DATABASE_URL`. |
| `JWT_SECRET`        | *(random, ≥32 chars)*                | Signs access/refresh tokens. Keep secret. |
| `RELAY_IMAGE`       | `ghcr.io/ferrumlink/ferrumlink-relay:latest` | Relay image to run. |
| `RELAY_PORT`        | `8080`                               | Host port for plain HTTP. Use `127.0.0.1:8080` behind nginx. |
| `DOMAIN`            | `relay.example.com`                  | Public hostname (tls profile only). |
| `RUST_LOG`          | `info`                               | Log verbosity. |
| token/security vars | see `.env.example`                   | Token lifetimes, login lockout, WS heartbeat/timeout. |

### Profiles

| Command                              | Brings up |
| ------------------------------------ | --------- |
| `docker compose up -d`               | postgres + redis + relay (plain HTTP) |
| `docker compose --profile tls up -d` | + nginx HTTPS reverse proxy on 443 |
| `docker compose --profile turn up -d`| + coturn TURN server (optional; for future WebRTC P2P) |

`install.sh` wires these up for you via `--with-tls` / `--with-turn`.

---

## Running a locally built image (no published image yet)

Until the official image is published to GHCR, build it from the **main
FerrumLink repo** and point this stack at your local tag:

```bash
# in the FerrumLink workspace repo:
docker build -f docker/Dockerfile.relay -t ferrumlink-relay:local .

# here, in .env:
RELAY_IMAGE=ferrumlink-relay:local
```
Then `docker compose up -d`.

---

## Security notes

- `.env` is `chmod 600` and gitignored — it holds your JWT secret and DB password.
- The relay sees only **ciphertext + metadata**. E2E keys never reach it.
- The relay's auth endpoints are rate-limited per-IP; nginx forwards the real
  client IP via `X-Forwarded-For` so limits work behind the proxy.
- Use HTTPS for any non-LAN deployment. Keep ports 5432/6379 unpublished
  (this compose keeps them on the internal network only).
- Keep the host patched and the relay image up to date.

---

## Layout

```
.
├── install.sh                 # one-shot installer (secrets + up)
├── docker-compose.yml         # postgres + redis + relay (+ tls/turn profiles)
├── .env.example               # documented config template
├── nginx/templates/           # HTTPS reverse-proxy config (envsubst ${DOMAIN})
├── coturn/turnserver.conf     # optional TURN config
├── certs/                     # TLS cert + key live here (gitignored)
└── scripts/obtain-cert.sh     # Let's Encrypt helper
```

---

## Troubleshooting

| Symptom | Fix |
| ------- | --- |
| `relay` restarts / can't reach DB | `docker compose logs relay` — usually wrong/empty `JWT_SECRET` or `POSTGRES_PASSWORD`. Re-run `./install.sh`. |
| nginx won't start | Missing `certs/fullchain.pem`/`privkey.pem`. Run `./scripts/obtain-cert.sh`. |
| certbot fails | Port 80 must be free and DNS must already point at this host. |
| `/health` works locally but not remotely | Firewall/security-group: open 8080 (LAN) or 80+443 (TLS). |
| Tokens suddenly invalid after redeploy | `JWT_SECRET` changed. Don't `--force` unless you mean to rotate. |

---

*Part of the FerrumLink project. The relay is signaling-only and never a trusted
authority — see the main project for the agent, client, and SDK.*
