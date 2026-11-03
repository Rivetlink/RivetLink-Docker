# RivetLink Relay — Docker deployment

Run your own **RivetLink relay** on a small Ubuntu VPS. With it, you can reach
your Linux Home Node from anywhere, including its login screen, when you are
not on the same network.

The relay is **not trusted** with your screen or keystrokes:

- The app and the host run the same end-to-end encrypted session as on the LAN
  (hybrid X25519 + ML-KEM handshake, host key pinned).
- The relay only forwards the ciphertext.
- A relay that lies about a host's key is refused by the handshake.

The stack:

| Service    | Role                                                              | Reachable from |
|------------|-------------------------------------------------------------------|----------------|
| `caddy`    | HTTPS/WSS on 80/443, gets and renews the Let's Encrypt certificate | internet       |
| `relay`    | the RivetLink relay                                               | Caddy only     |
| `postgres` | accounts, devices, audit log                                      | relay only     |

---

## What you need

- **A VPS running Ubuntu 24.04 or newer.** 1 vCPU and 1 GB RAM are enough.
  The relay forwards a stream; it does not encode one.
- **A domain name** you can add a DNS record to, for example
  `relay.example.com`.
- **An e-mail address** for Let's Encrypt expiry notices.
- **SSH access** as a normal user with `sudo`.

---

## 1. Point your domain at the VPS

At your DNS provider, add **only an A record** first:

```
relay.example.com.   A      203.0.113.10
```

Add an **AAAA** record only after IPv6 works on the VPS. Run this on the VPS;
it must print the VPS's IPv6 address:

```bash
curl -6 https://ifconfig.co
```

Let's Encrypt prefers IPv6 when an AAAA record exists. An AAAA record for a
VPS whose IPv6 does not work makes the certificate request fail. Some hosts,
for example Scaleway Dedibox, ship IPv6 switched off until you activate it in
their console.

```
relay.example.com.   AAAA   2001:db8::10
```

Wait until it resolves to your VPS. Run this on any machine:

```bash
dig +short relay.example.com
```

Caddy can only get a certificate once the name points at this server.

## 2. Prepare the VPS

Log in over SSH, then run:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl python3 ufw

# Docker Engine + the Compose plugin (Docker's official install script)
curl -fsSL https://get.docker.com | sudo sh

# Run docker without sudo. Note: the docker group is root-equivalent.
sudo usermod -aG docker "$USER"
```

Log out and back in so the group change applies. Then check:

```bash
docker compose version
```

Optional check that the CPU has AES instructions (AES-NI). Any number above 0
means TLS will not be the bottleneck:

```bash
grep -c aes /proc/cpuinfo
```

## 3. Firewall

Open only SSH and the web ports:

```bash
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status
```

Port 80 must stay open: Let's Encrypt uses it to prove the domain, and Caddy
uses it to redirect to HTTPS.

The relay and Postgres are **not published** to the host. Docker-published
ports bypass ufw, so this stack publishes only Caddy.

## 4. Install the relay

```bash
git clone https://github.com/Rivetlink/RivetLink-Docker.git
cd RivetLink-Docker
./install.sh --domain relay.example.com --email you@example.com
```

`install.sh` does the following:

- creates `.env` with strong random secrets (`chmod 600`);
- pulls the images and starts the stack;
- waits until `https://relay.example.com/health` answers, which means the
  certificate is in place.

Check it from your own computer:

```bash
curl https://relay.example.com/health
```

`install.sh` is safe to run again. It keeps existing secrets and never changes
the database password. Use it after changing `.env`.

## 5. Create your account

Registration over the internet is switched off: Caddy answers `403` on
`/auth/register`. Create accounts on the VPS itself:

```bash
./scripts/create-account.sh
```

The script asks for your e-mail, name, an organization name and a password of
at least 12 characters. The password is not echoed.

Use **this one account** on the Home Node and on every device you connect
from. Devices see each other only inside the same organization.

## 6. Connect the apps

Do this on **both** the Linux Home Node and the laptop or desktop you control
it from:

1. Open RivetLink → **Settings → Servers → Add server**.
2. Enter `https://relay.example.com` and activate it.
3. Sign in with the account from step 5.

The app builds the secure `wss://relay.example.com/ws` connection itself.

### Make the Home Node reachable through the relay

On the Linux Home Node:

1. Open **Settings → Ubuntu physical console**.
2. Choose **Set up physical console**, or **Update / reconfigure** if it is
   already set up.
3. Turn on **Via relay**. You can keep **Local network** on too.
4. Paste the public key of your controlling laptop or desktop. You find it on
   that device under **Settings → Security**.
5. Confirm with your Ubuntu password when asked.

The console service on the Home Node registers itself with the relay under
your account and stays connected.

### Connect from outside your network

On the controlling device, press **Connect** on the saved Home Node:

- On the same LAN, the app connects directly.
- Elsewhere, the app finds the same host (matched by its public key) at the
  relay and opens an encrypted tunnel to it.

You get the login screen before sign-in, and the live desktop after it.

The first time the app reaches a host through a given relay, it pins that
host's key. If the key ever changes, the app refuses to connect. Remove and
re-add the host only when you rotated its identity on purpose.

---

## Day-to-day

### Status and logs

```bash
docker compose ps
docker compose logs -f relay
docker compose logs -f caddy      # certificate problems show up here
```

### Updating

The relay image is pinned in `.env`, so an update is a choice you make:

```
RELAY_IMAGE=gtheunissen/rivetlink-relay:<version>
```

To update:

1. Run `git pull` to get the latest stack files.
2. Set the new `<version>` in `.env`.
3. Run `./install.sh`, which pulls the image and restarts.

To roll back, put the previous version back in `.env` and run `./install.sh`
again.

Remote console through the relay needs relay image **0.1.105 or newer**, and
RivetLink **v0.1.105 or newer** on both the Home Node and the controlling
device.

### Backups

A small VPS usually has a single disk without RAID. If that disk or the VPS
is lost, everything on it is gone, backups in `backups/` included. Keep a copy
**off the VPS**.

Back up `.env` together with the database:

- The database volume only opens with the `POSTGRES_PASSWORD` it was created
  with. Without that `.env`, the database on the server cannot be used.
- A new `JWT_SECRET` signs every app out.

The dump is not encrypted, and `.env` holds both secrets. Anyone who has
`.env` can sign tokens for your relay, so store both somewhere private.

Make a backup:

```bash
./scripts/backup.sh
```

This writes `backups/rivet-YYYY-MM-DD_HHMM.sql.gz` and a copy of `.env` next
to it (only your user can read them). It deletes local backups older than
`BACKUP_RETENTION_DAYS` (default 14 days).

Run it every day with a systemd timer:

```bash
sudo ./scripts/install-backup-timer.sh
systemctl list-timers rivetlink-backup.timer
```

If the VPS was off at backup time, the backup runs after the next boot.
Failures show up in `sudo journalctl -u rivetlink-backup.service`.

**Offsite copy.** Set `BACKUP_REMOTE` in `.env` to an rsync/scp target, for
example `user@backuphost:rivetlink-backups/`. Every backup is then also copied
there. Your user on the VPS needs an ssh key that logs in to that host
without a prompt. If rsync is installed on the VPS, the remote host needs
rsync too; otherwise scp is used. Old copies on the remote are not deleted. Without
`BACKUP_REMOTE`, copy the files off yourself:

```bash
scp 'user@relay.example.com:RivetLink-Docker/backups/*' ./rivetlink-backup/
```

**Restore** (this replaces the whole database):

```bash
./scripts/restore.sh backups/rivet-YYYY-MM-DD_HHMM.sql.gz
```

The dump is loaded into a separate database first. If it is broken, the
current database stays as it is. The relay is only stopped for the switch.

On a fresh VPS:

1. Put back the `.env` from the backup, as `.env`.
2. Run `./install.sh`.
3. Run `./scripts/restore.sh` with the dump.

### Signing everyone out

```bash
./install.sh --rotate-jwt
```

This makes a new token secret. Every app has to sign in again; Home Nodes
reconnect by themselves.

---

## Configuration (`.env`)

| Key                  | Meaning                                                                    |
|----------------------|----------------------------------------------------------------------------|
| `DOMAIN`             | public name of the relay; Caddy gets its certificate                       |
| `ACME_EMAIL`         | e-mail for Let's Encrypt                                                   |
| `POSTGRES_PASSWORD`  | generated; **never change it after the first start** (the database keeps the old one) |
| `JWT_SECRET`         | generated; rotate with `./install.sh --rotate-jwt`                         |
| `RELAY_IMAGE`        | relay image and version; pin it                                            |
| `RUST_LOG`           | relay log level (`info`, `debug`)                                          |
| `BACKUP_RETENTION_DAYS` | days `scripts/backup.sh` keeps local backups (default 14)               |
| `BACKUP_REMOTE`      | optional rsync/scp target for an offsite copy of every backup              |
| other `*_SECS` keys  | token lifetimes, login lockout, heartbeat; the defaults are fine           |

After a change, run `./install.sh` again.

### Direct connections (optional)

Without extra setup every session runs through the relay over HTTPS port 443.
That always works. With a STUN server the apps first try to connect the two
computers directly, so the picture does not pass through your VPS: lower
latency and less VPS traffic. Sessions stay end-to-end encrypted either way.

1. Start coturn as STUN server. This also sets `STUN_SERVER` in `.env`:

   ```bash
   ./install.sh --with-turn
   ```

2. Open UDP port 3478, in ufw and in your VPS provider's firewall:

   ```bash
   sudo ufw allow 3478/udp
   ```

   That is the only port coturn needs. It runs as STUN only (`stun-only`), so
   it never relays traffic and needs no TURN port range.

3. Use relay image 0.1.108 or newer (`RELAY_IMAGE`).

The apps pick the route by themselves. If a direct path cannot be made (for
example behind a strict company firewall) they fall back to the relay. To turn
it off again, empty `STUN_SERVER` in `.env` and run `./install.sh`.

---

## Security notes

- Only Caddy is published. The relay and Postgres live on the private Docker
  network.
- Caddy passes the real client address to the relay and drops any
  client-supplied `X-Forwarded-For`, so the login rate limit cannot be dodged.
- Registration is closed to the internet. Accounts are created on the server
  only.
- The relay container drops all Linux capabilities and cannot gain new
  privileges.
- Keep the VPS patched: `sudo apt update && sudo apt upgrade`. Consider
  `unattended-upgrades`.

---

## Troubleshooting

**`install.sh` waits for `/health` and gives up.**
Run `docker compose logs caddy`. The usual causes are:

- DNS does not point at this VPS yet;
- port 80 or 443 is blocked by ufw or by the VPS provider's own firewall;
- Let's Encrypt rate limits after many failed tries. Wait an hour.

**The app says "host identity changed; refusing the relay connection".**
The relay reports a different key for the host than the one pinned before.
This happens when the Home Node was reinstalled, and also when someone tampers
with the relay. If you reinstalled it yourself, remove the host in the app and
add it again.

**The Home Node does not show up as online.**

- On the Home Node, check **Settings → Ubuntu physical console**: is
  **Via relay** on, and is the app signed in to the same account?
- On the VPS, run `docker compose logs relay`. Look for the device's
  authentication.

**"relay tunnel did not open in time" from outside, while it works on the LAN.**
The relay image is older than 0.1.105 (check `RELAY_IMAGE` in `.env`), the
Home Node or the app is older than v0.1.105, or the Home Node is offline.
Update what is old and check that the Home Node shows as online.

**I lost `.env`.**
You cannot recover the database password from the data. Restore `.env` from
your backup. Without it, start over with a fresh volume:

```bash
docker compose down -v
./install.sh --domain ... --email ...
```

`down -v` deletes all accounts and devices. If you have a dump, load it
afterwards with `./scripts/restore.sh`. Everyone has to sign in again, because
the new `.env` has a new `JWT_SECRET`.
