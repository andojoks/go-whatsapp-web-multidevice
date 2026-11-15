# GOWA OTP API on a bare Ubuntu VPS

Production setup for **`https://api.whatsapp.ktorganicshop.com`**, a
GOWA (`go-whatsapp-web-multidevice`) instance whose only job is to send OTP
messages. It runs directly on an Ubuntu VPS without Docker and shares one Caddy
instance with PayConnect (`api.payconnect.ktorganicshop.com`):

- **Caddy is shared.** The base `/etc/caddy/Caddyfile` imports
  `/etc/caddy/sites-enabled/*.caddy`; this repository owns only
  `/etc/caddy/sites-enabled/gowa-otp.caddy`.
- **systemd** runs the static `gowa` binary as the unprivileged `gowa` user on
  `127.0.0.1:8081`. PayConnect already uses 8080, so the ports never collide.
- **PostgreSQL** stores the WhatsApp session and encryption keys, so a restart or
  redeploy does not require pairing the phone again.
- **Chat/message history is in memory only.** No message, chat, scheduled-send, or
  device-registry row is written to local disk. History is lost on restart by
  design.
- **HTTP Basic Auth** protects every API route except `/health`.
- The browser dashboard and MCP are disabled.

The GitHub Actions workflow builds the binary, uploads it with the deployment
scripts, configures the VPS, restarts the service, and verifies the public URL.

## Contents

1. [Architecture](#architecture)
2. [What is stored where](#what-is-stored-where)
3. [Prerequisites](#prerequisites)
4. [DNS](#1-dns)
5. [PostgreSQL](#2-postgresql)
6. [Configure `.env`](#3-configure-env)
7. [GitHub secrets](#4-github-secrets)
8. [Deploy](#5-deploy)
9. [Pair the WhatsApp number](#6-pair-the-whatsapp-number)
10. [External OTP site integration](#7-external-otp-site-integration)
11. [Operations](#8-operations)
12. [Security notes](#9-security-notes)
13. [Troubleshooting](#10-troubleshooting)
14. [Remove the deployment](#11-remove-the-deployment)

## Architecture

```text
External OTP site (server-side only)
        |
        | HTTPS + HTTP Basic Auth
        v
https://api.whatsapp.ktorganicshop.com          (DNS: A -> VPS IPv4)
        |
        v
/etc/caddy/Caddyfile                            (shared base)
  + /etc/caddy/sites-enabled/gowa-otp.caddy     (this repo)
  + /etc/caddy/sites-enabled/payconnect.caddy   (other repo)
        |
        | HTTP, loopback only
        v
   127.0.0.1:8081  ->  gowa rest  (systemd service "gowa")
        |
        +--> PostgreSQL: WhatsApp session + encryption keys
        |
        +--> RAM: chat/message history (SQLite shared in-memory database)
        |
        +--> WhatsApp servers (paired companion device)
```

The deploy pipeline is:

```text
git push origin main
        |
        v
GitHub Actions (ubuntu-latest)
  go test -tags purego ./...
  CGO_ENABLED=0 GOOS=linux go build -tags purego
        |
        | SSH + tar
        v
VPS /tmp/gowa-deploy
        |
        | vps-scripts/setup-vps.sh (root)
        v
/opt/gowa/bin/gowa + /opt/gowa/.env + /etc/systemd/system/gowa.service
/etc/caddy/sites-enabled/gowa-otp.caddy         (base stays untouched)
        |
        v
systemctl restart gowa  ->  caddy validate  ->  systemctl reload caddy
        |
        v
GET https://api.whatsapp.ktorganicshop.com/health
```

### Repository layout

| Path | Purpose |
| --- | --- |
| `.env.example` | Root sample configuration, including VPS-only `VPS_*` keys. |
| `.github/workflows/deploy-vps.yaml` | Test, build, upload, install, verify. |
| `vps-scripts/setup-vps.sh` | On-VPS installer; validates config, installs the service, publishes the route. |
| `vps-scripts/deploy.sh` | Manual alternative to the workflow, run from your machine. |
| `vps-scripts/systemd/gowa.service` | Hardened systemd unit template. |
| `vps-scripts/lib/caddy.sh` | Shared-Caddy helpers: base config, snippet rendering, validate/reload, rollback. |
| `vps-scripts/caddy/site.caddy.template` | Reverse-proxy snippet template for this app. |
| `vps-scripts/caddy/install-base.sh` | One-time shared base provisioner (safe to re-run). |
| `vps-scripts/caddy/apply-site.sh` | Routing-only publisher, usable from other repositories. |
| `vps-scripts/caddy/sudoers.template` | Scoped sudo rules for a non-root deploy user. |
| `src/cmd/root.go` | Reads `CHAT_STORAGE_URI` and `CHAT_STORAGE_MAX_OPEN_CONNS`. |
| `docs/neon.md` | Managed-PostgreSQL notes that also apply to other providers. |

## What is stored where

| Data | Location | Survives restart? |
| --- | --- | --- |
| WhatsApp session + encryption keys | PostgreSQL from `DB_URI` | Yes |
| Device registry (slot names, webhooks) | In-memory SQLite (`CHAT_STORAGE_URI`) | No |
| Chat/message history | In-memory SQLite | No |
| Scheduled sends | In-memory SQLite | No |
| Downloaded media / uploads | Not downloaded; `WHATSAPP_AUTO_DOWNLOAD_MEDIA=false` | n/a |
| Logs | journald (`journalctl -u gowa`) | Until journal rotation |
| Runtime `.env` | `/opt/gowa/.env`, mode `0600` | Yes |

PostgreSQL is used **only for the WhatsApp session store**. GOWA's chat storage
is SQLite-only upstream, so this deployment points it at a shared in-memory
database. That is why the root `.env.example` sets:

```dotenv
CHAT_STORAGE_URI=file::memory:?cache=shared
CHAT_STORAGE_MAX_OPEN_CONNS=1
```

The deploy scripts force both values and reject a file-backed chat database.

> **Single-device addressing.** On a fresh database there is no device at all, so
> device-scoped routes return `DEVICE_ID_REQUIRED` until you create a slot with
> `POST /devices` (section 6.2). The slot name lives in the in-memory registry, so
> after a restart the WhatsApp session is rediscovered from PostgreSQL and becomes
> the default/only device. Permanent integrations should omit `X-Device-Id`
> instead of pinning the temporary slot name. If you need a named slot that
> survives restarts, use a persistent chat storage file instead of the in-memory
> URI (not recommended for an OTP-only deployment).

## Prerequisites

- Ubuntu 22.04 or 24.04 LTS VPS, `amd64` or `arm64`.
- Root SSH access, or a sudo-capable user with passwordless sudo. The current
  deployment uses `azureuser` on the shared VPS with `sudo -n`.
- A phone number for OTP sending. It must have WhatsApp installed and be able to
  approve a linked device. A dedicated number is recommended so OTP traffic is not
  mixed with personal chats; the phone can stay online, but do not log out or remove
  the linked device.
- A domain you control: `api.whatsapp.ktorganicshop.com`.
- PostgreSQL 14+ either on the VPS (loopback) or reachable over TLS from it.
  Managed providers such as Neon, Supabase, Amazon RDS, DigitalOcean, or a
  separate database VPS all work.
- Go is **not** required on the VPS. The binary is built by GitHub Actions.
- Accurate VPS clock. Run `timedatectl set-ntp true` once; pairing and message
  signing depend on it.

Ports on the shared VPS:

| Port | Exposure | Purpose |
| --- | --- | --- |
| `22` (or your SSH port) | Public, restrict to your IP if possible | SSH / deploy |
| `80` | Public | Let's Encrypt HTTP-01 and HTTP→HTTPS redirects |
| `443` | Public | OTP API |
| `8081` | Loopback only | GOWA behind Caddy |
| `8080` | Loopback only | PayConnect behind Caddy (not GOWA) |
| `5432` | **Not public** | PostgreSQL; loopback or TLS-only from the VPS |

## 1. DNS

Create this record at your DNS provider (the shared VPS uses Namecheap DNS):

| Type | Name | Value | Proxy |
| --- | --- | --- | --- |
| `A` | `api.whatsapp` | VPS IPv4 (the same address as PayConnect) | DNS only |
| `AAAA` | `api.whatsapp` | VPS IPv6, if the VPS has one | DNS only |

Wait for propagation, then check from your machine:

```bash
dig +short api.whatsapp.ktorganicshop.com
```

Caddy obtains a Let's Encrypt certificate automatically over HTTP-01. Keep the
record **DNS only** for the first deployment. If you later put Cloudflare in front,
use **Full (strict)** so Cloudflare validates Caddy's certificate; do not use
Flexible mode.

> The app and the Caddy route can be deployed **before** DNS exists. In that case
> `/health` is available on `127.0.0.1:8081`, and Caddy serves the HTTP→HTTPS
> redirect but cannot issue a certificate until the record points at the VPS.
> Re-run the deploy (or `sudo systemctl reload caddy`) after DNS propagates.

## 2. PostgreSQL

GOWA creates and upgrades its own `whatsmeow_*` tables at startup. The database
user therefore needs to create and alter tables in its schema.

### Option A: PostgreSQL on the VPS (current deployment)

This keeps the session database on the same machine and avoids an external
dependency. It is safe on a small VPS: GOWA only stores session/key rows.

```bash
sudo apt-get update -y
sudo apt-get install -y postgresql

sudo -u postgres psql <<'SQL'
CREATE ROLE gowa LOGIN PASSWORD 'replace-with-a-long-random-password';
CREATE DATABASE gowa OWNER gowa;
REVOKE ALL ON DATABASE gowa FROM PUBLIC;

\connect gowa
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO gowa;
SQL
```

Use a loopback URI with TLS disabled (traffic never leaves the host):

```dotenv
DB_URI=postgres://gowa:URL_ENCODED_PASSWORD@127.0.0.1:5432/gowa?sslmode=disable
```

The deploy scripts detect the active local PostgreSQL service and log that the
loopback database is in use. They do not install PostgreSQL themselves.

### Option B: managed PostgreSQL

1. Create a dedicated database and role for GOWA. Do not reuse an application
   database.
2. Copy the **direct** connection string (no pooler) and make it look like:

   ```dotenv
   DB_URI=postgres://gowa:URL_ENCODED_PASSWORD@db.example.com:5432/gowa?sslmode=verify-full
   ```

3. Convert the scheme from `postgresql://` to `postgres://`. The deploy scripts
   require the `postgres://` prefix.
4. Remove `channel_binding=require` if the provider adds it; GOWA's `lib/pq`
   supports SCRAM-SHA-256 without channel binding.
5. Percent-encode special characters in the password (`@`, `:`, `/`, `?`, `#`,
   `%`). For example, `p@ss:word` becomes `p%40ss%3Aword`.
6. Keep `sslmode=verify-full`. GOWA defaults remote connections to `verify-full`
   when `sslmode` is omitted, but set it explicitly.
7. Leave `DB_KEYS_URI=` blank so encryption keys use the same database.

Neon-specific steps are in [`docs/neon.md`](docs/neon.md). Use the direct hostname,
not the `-pooler` hostname.

### Option C: PostgreSQL on another VPS

Run the SQL from Option A as a superuser, then enable TLS and restrict access:

```conf
# postgresql.conf
listen_addresses = '*'
ssl = on
ssl_cert_file = '/etc/postgresql/server.crt'
ssl_key_file  = '/etc/postgresql/server.key'
```

```conf
# pg_hba.conf: only the GOWA VPS may connect, and only with TLS + SCRAM
hostssl gowa gowa 203.0.113.10/32 scram-sha-256
```

Reload PostgreSQL (`systemctl reload postgresql`), allow TCP `5432` only from the
GOWA VPS in the database host's firewall, and verify:

```bash
psql "postgres://gowa:PASSWORD@db.example.com:5432/gowa?sslmode=verify-full" \
  -c 'select current_database(), current_user, ssl from pg_stat_ssl where pid = pg_backend_pid();'
```

If the database uses a private CA, add `sslrootcert=/path/to/ca.pem` to `DB_URI`
and place that file on the VPS, or use a provider with a publicly trusted CA. GOWA
does not copy CA files for you.

### Verify after the first deploy

```bash
sudo -u postgres psql -d gowa -c "\dt whatsmeow_*"
```

After pairing you should see `whatsmeow_device` and the related key tables. Never
print those rows: they contain private key material.

## 3. Configure `.env`

From the repository root:

```bash
cp .env.example .env
chmod 600 .env
```

Edit `.env` and replace every `CHANGE_ME` value. `.env` is gitignored and stripped
of `VPS_*` keys before upload.

### Public entry point and auth

```dotenv
PUBLIC_BASE_URL=https://api.whatsapp.ktorganicshop.com
APP_PORT=8081
GOWA_CADDY_SITE_ID=gowa-otp
APP_BASIC_AUTH=otp:LONG_RANDOM_PASSWORD
APP_TRUSTED_PROXIES=127.0.0.1/32
APP_ALLOW_UNAUTHENTICATED=false
```

`APP_PORT` and `GOWA_CADDY_SITE_ID` must be unique on the VPS. The defaults are
already unique next to PayConnect (`8081`, `gowa-otp`).

Generate the Basic Auth password with:

```bash
openssl rand -hex 32
```

Rules for `APP_BASIC_AUTH`:

- Format is `user:password`. GOWA splits on `:` and requires exactly one colon, so
  **do not use `:` in the username or password**.
- Multiple credentials may be comma-separated, for example
  `otp:pass1,admin:pass2`; every pair must still have exactly one colon.
- Use only this credential from server-side code. Never embed it in a browser or
  mobile app.

### Database

```dotenv
DB_URI=postgres://gowa:URL_ENCODED_PASSWORD@127.0.0.1:5432/gowa?sslmode=disable
DB_KEYS_URI=
CHAT_STORAGE_URI=file::memory:?cache=shared
CHAT_STORAGE_MAX_OPEN_CONNS=1
```

Use `sslmode=verify-full` instead of `disable` for a remote database.

### API-only surface

```dotenv
APP_UI_ENABLED=false
APP_UI_AUTO_UPDATE=false
MCP_ENABLED=false
CHATWOOT_ENABLED=false
APP_DEBUG=false
```

### OTP-sender behaviour

```dotenv
WHATSAPP_AUTO_DOWNLOAD_MEDIA=false
WHATSAPP_IGNORE_STATUS_MEDIA=true
WHATSAPP_AUTO_REJECT_CALL=true
WHATSAPP_ACCOUNT_VALIDATION=true
WHATSAPP_PRESENCE_ON_CONNECT=unavailable
WHATSAPP_PRESENCE_PULSE_ENABLED=false
WHATSAPP_WEBHOOK=
```

Set `WHATSAPP_WEBHOOK` only if your OTP service needs `message.ack` delivery
receipts. Leave it empty otherwise.

### Shared Caddy (optional overrides)

```dotenv
# GOWA_CADDY_UPSTREAM=127.0.0.1:8081
# GOWA_CADDY_EXTRA_HOSTS=www.whatsapp.ktorganicshop.com
# GOWA_CADDY_TAKEOVER=false
```

See [`vps-scripts/caddy/README.md`](vps-scripts/caddy/README.md) for the shared
base, mirroring, Docker, and scoped-sudo notes.

### VPS connection keys

These keys are used only by the deploy process and are **stripped from the bundle
before upload**:

```dotenv
VPS_HOST=203.0.113.10
VPS_SSH_PORT=22
VPS_SSH_USER=azureuser
VPS_SSH_KEY_PATH=~/.ssh/gowa_vps
VPS_SSH_KEY=
VPS_GOARCH=amd64
VPS_ACME_EMAIL=ops@ktorganicshop.com
```

- Use `VPS_SSH_KEY_PATH` for a local private-key file, or `VPS_SSH_KEY` for the key
  content. The workflow path uses the `VPS_SSH_KEY` secret.
- If `VPS_SSH_USER` is empty or `root`, the deploy connects as root. If it is set to
  another user, that user must have **passwordless sudo** (`sudo -n` is used).
- `VPS_GOARCH` must match the VPS: `amd64` for x86_64, `arm64` for ARM.
- `VPS_ACME_EMAIL` is optional but recommended for Let's Encrypt expiry notices.
  The shared base may already define one (from the PayConnect deploy).

Do not commit `.env`. It is already covered by `.gitignore`.

## 4. GitHub secrets

The workflow reads repository secrets and writes them into the runtime `.env`. It
maps each key in `.env.example` to a secret with the same name, or a `PROD_<KEY>` /
`<KEY>_PROD` variant.

Add these under **Settings → Secrets and variables → Actions → New repository
secret**:

| Secret | Required | Example |
| --- | --- | --- |
| `VPS_HOST` | Yes | `4.221.33.178` |
| `VPS_SSH_KEY` | Yes | Full private key, including BEGIN/END lines |
| `VPS_SSH_USER` | No | `azureuser` or `root` |
| `VPS_SSH_PORT` | No | `22` |
| `VPS_GOARCH` | No | `amd64` |
| `VPS_ACME_EMAIL` | No | `ops@ktorganicshop.com` |
| `PUBLIC_BASE_URL` | Yes | `https://api.whatsapp.ktorganicshop.com` |
| `DB_URI` | Yes | `postgres://...` |
| `APP_BASIC_AUTH` | Yes | `otp:<random>` |
| `APP_PORT` | No | `8081` (unique per app) |
| `GOWA_CADDY_SITE_ID` | No | `gowa-otp` (unique per app) |
| `GOWA_CADDY_UPSTREAM` | No | `127.0.0.1:8081` |
| `GOWA_CADDY_EXTRA_HOSTS` | No | Comma-separated extra hosts |
| `APP_TRUSTED_PROXIES` | No | `127.0.0.1/32` |
| `APP_DEBUG` | No | `false` |
| `APP_UI_ENABLED` | No | `false` |
| `MCP_ENABLED` | No | `false` |
| `CHATWOOT_ENABLED` | No | `false` |
| `WHATSAPP_WEBHOOK` | No | Empty |
| `WHATSAPP_WEBHOOK_SECRET` | No | Empty |

Any other key from `.env.example` can be added as a secret with the same name; the
workflow writes only the keys that exist. Keys with safe application defaults may
be omitted.

### Alternative: one `APP_ENV_FILE` secret

Instead of one secret per key, create a secret named `APP_ENV_FILE` containing the
entire production `.env` file (without `VPS_*` keys). When present, it wins over
the per-key mapping. This is easier for complex values and multi-line settings.

The workflow still forces the loopback bind, the app port, in-memory chat storage,
and validates `PUBLIC_BASE_URL`, `DB_URI`, and `APP_BASIC_AUTH`.

### SSH key

```bash
ssh-keygen -t ed25519 -C "gowa-deploy" -f ~/.ssh/gowa_vps -N ""
ssh-copy-id -i ~/.ssh/gowa_vps.pub azureuser@203.0.113.10
ssh azureuser@203.0.113.10 'sudo -n true'
```

Paste the **private** key (`~/.ssh/gowa_vps`) into the `VPS_SSH_KEY` secret. Do not
paste the `.pub` file. The current shared VPS accepts the existing deploy key
(`EASYPAY_key.pem` on the operator workstation) for `azureuser`.

## 5. Deploy

### Option A: GitHub Actions (recommended)

Push to `main` (changes under `src/`, `vps-scripts/`, `.env.example`, or the
workflow file trigger a deploy), or run **Actions → Deploy VPS → Run workflow**.

```bash
git add .env.example .github/workflows/deploy-vps.yaml vps-scripts DEPLOYMENT.md src/cmd/root.go src/.env.example
git commit -m "ci: deploy OTP API to shared Caddy on the VPS"
git push origin main
```

The job:

1. Validates `VPS_HOST` and `VPS_SSH_KEY`.
2. Runs `go test -tags purego ./...`.
3. Builds a static Linux binary with `CGO_ENABLED=0` and `-tags purego`.
4. Builds the deployment `.env` from secrets and strips `VPS_*`.
5. Uploads the binary, scripts, and `.env` to `/tmp/gowa-deploy`.
6. Runs `vps-scripts/setup-vps.sh` as root (or via passwordless sudo).
7. Checks `127.0.0.1:<APP_PORT>/health` on the VPS, then the public `/health` and
   an authenticated `GET /app/info` from the runner.
8. Removes the remote staging directory and the local temporary SSH key.

The first deploy installs Caddy if needed, creates/keeps the shared base, creates
`/opt/gowa`, the `gowa` user, the `gowa.service` unit, and publishes
`/etc/caddy/sites-enabled/gowa-otp.caddy`. It never touches PayConnect's file.

Caddy may need a minute to obtain the certificate on the very first run. If the
public check reports "not reachable yet", confirm DNS and ports 80/443, then run
the workflow again or check the logs on the VPS.

### Option B: manual deploy from your machine

Use Git Bash, WSL, macOS, or Linux:

```bash
bash vps-scripts/deploy.sh
```

It reads `.env`, builds the same pure-Go binary, uploads the bundle, runs the same
installer, and performs the same health checks. It needs `go`, `ssh`, `tar`, and
`curl` locally. Set `GOWA_ENV_FILE` to use a `.env` other than the repository root.

### What the installer enforces

`vps-scripts/setup-vps.sh` refuses to continue unless:

- it runs as root;
- `DB_URI` is present and starts with `postgres://`;
- `DB_URI` does not contain a `CHANGE_ME` placeholder;
- `APP_BASIC_AUTH` is present, has a colon, and does not contain `CHANGE_ME`;
- `CHAT_STORAGE_URI` is an in-memory SQLite URI (`:memory:` or `mode=memory`);
- `PUBLIC_BASE_URL` is an absolute `http(s)` origin with no path;
- `https://` is not used with a bare IP address (no certificate is possible);
- `APP_PORT` is numeric and `GOWA_CADDY_SITE_ID` is a safe lowercase id.

It then forces:

```dotenv
APP_HOST=127.0.0.1
APP_PORT=<APP_PORT>
APP_ALLOW_UNAUTHENTICATED=false
```

and sets safe defaults for the API-only, OTP-sender behaviour. Explicit values in
`.env` are preserved for the `env_set_default` keys.

## 6. Pair the WhatsApp number

Pairing is a one-time operation. The session is written to PostgreSQL and
reconnects automatically after restarts and redeploys.

Keep `BASE`, `AUTH`, and the phone number in shell variables:

```bash
BASE=https://api.whatsapp.ktorganicshop.com
AUTH='otp:YOUR_BASIC_AUTH_PASSWORD'
OTP_PHONE=628123456789
```

### 6.1 Confirm the API is healthy and authenticated

```bash
curl -fsS "$BASE/health"                 # public: OK
curl -fsS -u "$AUTH" "$BASE/app/info"    # authenticated metadata
```

`/health` is intentionally public. It returns `200 OK` when the device manager is
initialized and `503 Service Unavailable` while the app is starting or unhealthy.

On the VPS, the same checks without DNS/TLS are:

```bash
curl -fsS http://127.0.0.1:8081/health
curl -fsS -u "$AUTH" http://127.0.0.1:8081/app/info
```

### 6.2 Create a device slot and start pairing-code login

On a fresh deployment there is no device yet, so `/app/login-with-code` (and
every other device-scoped route) returns `400 DEVICE_ID_REQUIRED`. Create one
slot first. Its name is local to the in-memory registry; the WhatsApp session
itself is stored in PostgreSQL.

```bash
# 1. Create a slot named "otp" (returns results.id = "otp")
curl -fsS -u "$AUTH" -X POST "$BASE/devices" \
  -H 'Content-Type: application/json' \
  -d '{"device_id":"otp"}'

# 2. Ask WhatsApp for an 8-character pairing code for that slot
curl -fsS -u "$AUTH" -X POST \
  "$BASE/devices/otp/login/code?phone=$OTP_PHONE"
```

If the slot already exists, step 1 returns an error; reuse it and continue with
step 2.

The pairing response looks like:

```json
{
  "status": 200,
  "code": "SUCCESS",
  "message": "Login with code started",
  "results": {
    "device_id": "otp",
    "pair_code": "ABCD-1234"
  }
}
```

On the phone:

1. Open **WhatsApp → Settings → Linked devices → Link a device**.
2. Choose **Link with phone number instead**.
3. Enter the 8-character code.

The code is short-lived (about a minute). If it expires, call step 2 again to get
a new one. After successful pairing, confirm the state:

```bash
curl -fsS -u "$AUTH" "$BASE/devices/otp/status"
curl -fsS -u "$AUTH" "$BASE/devices"
```

`/devices/otp/status` returns `is_connected: true` and `is_logged_in: true`. In
`/devices`, the entry whose `phone_number`/`jid` matches the paired phone should
have `state` `connected` or `logged_in`. The response field is `id`, not
`device_id`.

For sending, **omit `X-Device-Id`**: GOWA resolves the default/only device. This
also keeps working after a restart, when the session is rediscovered from
PostgreSQL and the temporary `otp` slot name no longer exists.

### 6.3 QR alternative

If you prefer QR pairing, create the slot the same way and then request its QR:

```bash
curl -fsS -u "$AUTH" -X POST "$BASE/devices" \
  -H 'Content-Type: application/json' -d '{"device_id":"otp"}'
curl -fsS -u "$AUTH" "$BASE/devices/otp/login"
```

The response contains `qr_link`. Open it and scan it from
**WhatsApp → Linked devices → Link a device**. The QR image is served from
`/statics/qrcode/...` and is short-lived. (`GET /app/login` is the same flow for
the default/only device once one exists.)

### 6.4 If pairing is lost

Re-pair only when WhatsApp has actually logged the companion out (for example the
phone was reset, or the linked device was removed from the phone). First remove the
stale session:

```bash
# List devices, then remove the stale slot/JID:
curl -fsS -u "$AUTH" "$BASE/devices"
curl -fsS -u "$AUTH" -X DELETE "$BASE/devices/<id>"
```

Then repeat section 6.2. Do **not** delete the PostgreSQL database or run two
instances against the same session just to force a re-pair.

## 7. External OTP site integration

Your public website must **never** call this API from the browser: the Basic Auth
credential is a server secret, and a public endpoint without rate limiting can be
abused to send paid/spam messages. Put the call in your backend and authenticate
the end user there.

### 7.1 Configure the external site

Add these variables to the OTP site's server environment (names are suggestions):

```dotenv
WHATSAPP_OTP_URL=https://api.whatsapp.ktorganicshop.com
WHATSAPP_OTP_BASIC_AUTH=otp:LONG_RANDOM_PASSWORD
WHATSAPP_OTP_TIMEOUT_MS=15000
```

- `WHATSAPP_OTP_BASIC_AUTH` is exactly the `APP_BASIC_AUTH` value from the GOWA
  `.env` (`user:password`). Keep it in a secret manager, not in source control or
  the frontend bundle.
- Use the same credential for pairing only when you need to; day-to-day traffic
  only needs `POST /send/message`.
- If the OTP site runs in Docker/Kubernetes, inject the values as secrets and
  restart the service after changing them.

Retrieve the deployed credential on the VPS (never paste it into a browser or
chat):

```bash
sudo grep '^APP_BASIC_AUTH=' /opt/gowa/.env
```

### 7.2 Request format

```http
POST /send/message HTTP/1.1
Host: api.whatsapp.ktorganicshop.com
Authorization: Basic <base64("otp:password")>
Content-Type: application/json

{
  "phone": "628123456789",
  "message": "Your KtOrganic OTP is 482913. It expires in 5 minutes."
}
```

- `phone`: international number, digits only, no leading `0`, `+` optional.
- `message`: plain text; keep it short.
- Omit `X-Device-Id` for this single-device deployment.
- Success returns `200` with `results.message_id` and `results.status`.
- There is **no built-in deduplication or rate limiting**. Generate the OTP,
  store its hash/expiry in your own database, and throttle per phone/IP/session.

### 7.3 Node.js example

```js
const BASE = process.env.WHATSAPP_OTP_URL;
const AUTH = process.env.WHATSAPP_OTP_BASIC_AUTH; // "otp:..."
const TIMEOUT = Number(process.env.WHATSAPP_OTP_TIMEOUT_MS ?? 15000);

export async function sendOtp(phone, code) {
  const response = await fetch(`${BASE}/send/message`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${Buffer.from(AUTH).toString("base64")}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      phone,
      message: `Your KtOrganic OTP is ${code}. It expires in 5 minutes.`,
    }),
    signal: AbortSignal.timeout(TIMEOUT),
  });

  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(
      `WhatsApp OTP send failed (${response.status}): ${body.message ?? "unknown error"}`,
    );
  }
  return body.results;
}
```

### 7.4 PHP example

```php
<?php
$base = getenv('WHATSAPP_OTP_URL');
$auth = getenv('WHATSAPP_OTP_BASIC_AUTH');

$payload = json_encode([
    'phone' => $phone,
    'message' => "Your KtOrganic OTP is {$code}. It expires in 5 minutes.",
]);

$ch = curl_init("{$base}/send/message");
curl_setopt_array($ch, [
    CURLOPT_POST => true,
    CURLOPT_POSTFIELDS => $payload,
    CURLOPT_HTTPHEADER => ['Content-Type: application/json'],
    CURLOPT_USERPWD => $auth,
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_TIMEOUT => 15,
]);

$response = curl_exec($ch);
$status = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
if ($response === false || $status < 200 || $status >= 300) {
    error_log("WhatsApp OTP send failed ({$status}): " . curl_error($ch));
    curl_close($ch);
    throw new RuntimeException('OTP delivery failed');
}
curl_close($ch);
```

### 7.5 Python example

```python
import os
import requests

BASE = os.environ["WHATSAPP_OTP_URL"]
AUTH = tuple(os.environ["WHATSAPP_OTP_BASIC_AUTH"].split(":", 1))


def send_otp(phone: str, code: str) -> dict:
    response = requests.post(
        f"{BASE}/send/message",
        auth=AUTH,
        json={
            "phone": phone,
            "message": f"Your KtOrganic OTP is {code}. It expires in 5 minutes.",
        },
        timeout=15,
    )
    response.raise_for_status()
    return response.json()["results"]
```

### 7.6 Recommended OTP flow

1. Validate the phone number server-side and normalize it to E.164 digits.
2. Rate-limit requests per phone, IP, and session (for example 1 per minute, 5
   per hour) before calling GOWA.
3. Generate a 6–8 digit code with a CSPRNG; store only its hash, expiry, and
   attempt count.
4. Call `POST /send/message` with a 10–15 second timeout.
5. Treat `401` as a configuration error (wrong `APP_BASIC_AUTH`), `4xx` as a user
   or number problem, and `5xx`/timeouts as retryable with backoff (at most once
   or twice).
6. Verify the submitted code against the stored hash, enforce expiry, and
   invalidate it after a small number of failed attempts.
7. Never log the OTP, the Basic Auth header, or full phone numbers. Log a
   request id, a masked number, and the result.

### 7.7 Delivery receipts (optional)

Set `WHATSAPP_WEBHOOK` and `WHATSAPP_WEBHOOK_SECRET` on GOWA if the OTP site needs
`message.ack` events. GOWA signs webhook requests with `X-Hub-Signature-256`; verify
the signature over the raw body before trusting it. Keep
`WHATSAPP_WEBHOOK_EVENTS=message.ack` to avoid unrelated traffic.

### 7.8 Test from your machine

```bash
BASE=https://api.whatsapp.ktorganicshop.com
AUTH='otp:YOUR_BASIC_AUTH_PASSWORD'

curl -fsS -u "$AUTH" \
  -H 'Content-Type: application/json' \
  -X POST "$BASE/send/message" \
  -d '{"phone":"628123456789","message":"PayConnect OTP test"}'
```

A successful response means WhatsApp accepted the message for delivery; it is not
a guarantee that the handset displayed it.

## 8. Operations

### Status and logs

```bash
ssh azureuser@203.0.113.10

systemctl status gowa caddy
journalctl -u gowa -f
journalctl -u gowa --since "1 hour ago" --no-pager
journalctl -u caddy -n 100 --no-pager
```

The service runs as `gowa` from `/opt/gowa`:

```text
/opt/gowa/bin/gowa          binary, replaced on each deploy
/opt/gowa/.env              runtime configuration, mode 0600
/opt/gowa/statics/          QR images and runtime media scratch
/opt/gowa/storages/         empty for chat history; runtime scratch only
/etc/systemd/system/gowa.service
/etc/caddy/Caddyfile                          shared base; do not edit per app
/etc/caddy/sites-enabled/gowa-otp.caddy       this app's route
/etc/caddy/sites-enabled/payconnect.caddy     other app on the same VPS
```

### Health checks

```bash
curl -fsS https://api.whatsapp.ktorganicshop.com/health
curl -fsS http://127.0.0.1:8081/health            # on the VPS, direct to GOWA
```

Do **not** use `http://<VPS_IP>/health`: on a shared Caddy the bare IP may route to
PayConnect or another app. To test the route without DNS, use the public Host
header against loopback:

```bash
curl -fsS http://127.0.0.1/health -H 'Host: api.whatsapp.ktorganicshop.com'
```

`/health` returns `503` while the app starts or when the device manager is not
healthy. Restart and inspect the logs if it stays unavailable.

### Caddy operations

```bash
# What is routed on this VPS
ls -l /etc/caddy/sites-enabled/*.caddy

# Validate the whole shared configuration (base + all apps)
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

# Apply changes gracefully (zero downtime)
sudo systemctl reload caddy

# Remove only GOWA's route; PayConnect keeps running
bash vps-scripts/caddy/apply-site.sh --site-id gowa-otp --remove

# Roll back only GOWA
ls -1t /etc/caddy/sites-enabled/.backups/gowa-otp.*
sudo cp /etc/caddy/sites-enabled/.backups/gowa-otp.<timestamp> /etc/caddy/sites-enabled/gowa-otp.caddy
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && sudo systemctl reload caddy
```

The deploy validates the whole config before reloading and restores the previous
snippet if anything fails, so a broken GOWA deploy cannot take PayConnect offline.

### Update and rollback

- **Update:** push to `main` or run the workflow manually. The service restarts, the
  PostgreSQL session reconnects, and no pairing is needed.
- **Configuration change:** update the corresponding GitHub secret (or
  `APP_ENV_FILE`) and redeploy. Editing `/opt/gowa/.env` by hand works until the next
  deploy overwrites it.
- **Rollback:** re-run the last successful workflow (`gh run rerun <run-id>`) or
  revert the commit and push. The database schema is upgraded in place by GOWA; do
  not point the old binary at a database that a newer version has migrated unless
  the release notes say it is safe.

### Backups

Only PostgreSQL matters for recovery. Back up the `gowa` database with your
provider's PITR or:

```bash
pg_dump "postgres://gowa:PASSWORD@db.example.com:5432/gowa?sslmode=verify-full" \
  --format=custom --file=gowa-$(date +%F).dump
```

Treat the dump as a secret: it contains WhatsApp session keys that can impersonate
the linked device. Encrypt it at rest, restrict access, and never commit it.

The VPS itself has no message history to back up. `/opt/gowa/statics` contains only
short-lived QR images and scratch files, and `/opt/gowa/storages` is not used for
chat history in this configuration.

### Rotate the Basic Auth password

1. Generate a new password: `openssl rand -hex 32`.
2. Update the `APP_BASIC_AUTH` secret (keep the `otp:` prefix, no extra colon).
3. Redeploy and update the OTP service's credential.
4. Confirm `GET /app/info` with the new credential and that the old one returns
   `401`.

### Rotate the database password

1. Change the role password in PostgreSQL.
2. Percent-encode the new password and update `DB_URI` in the secret.
3. Redeploy. GOWA reconnects; the WhatsApp session remains valid.

### Remove or replace the phone

```bash
curl -fsS -u "$AUTH" "$BASE/devices"
curl -fsS -u "$AUTH" -X DELETE "$BASE/devices/<id>"
```

Then pair again as in section 6. Removing the device deletes its session rows from
PostgreSQL, so the phone is no longer linked after WhatsApp processes the logout.

## 9. Security notes

- **TLS only.** Caddy redirects the domain to HTTPS and obtains/renews certificates
  automatically. Do not expose port 8081.
- **Basic Auth on every API route.** `APP_ALLOW_UNAUTHENTICATED=false` is forced by
  the deploy scripts. `/health` is the only public route.
- **Strong credentials.** Use `openssl rand -hex 32` for the Basic Auth password.
  Avoid `:` in the username/password because GOWA's parser splits on it.
- **Database TLS.** Use `sslmode=verify-full` and a publicly trusted CA for a
  remote database, or mount the private CA and pass `sslrootcert`. Loopback may use
  `sslmode=disable`. Never use `sslmode=disable` for a remote database.
- **Least privilege.** The `gowa` database role owns only its own database/schema.
  It does not need superuser or access to other databases.
- **Firewall.** Public: SSH, 80, 443. Loopback only: 8080 (PayConnect) and 8081
  (GOWA). PostgreSQL: loopback or the VPS IP only. The installer opens 80/443 in UFW
  when UFW is active.
- **Shared Caddy isolation.** GOWA writes only `gowa-otp.caddy`; the base and other
  apps' files are read-only to it. Deploys are serialized with `flock`.
- **Do not log message bodies.** Keep `APP_DEBUG=false`. OTP messages and phone
  numbers are personal data; configure journald retention and access accordingly.
- **No browser or mobile calls.** The Basic Auth credential is a server secret. If a
  browser must trigger OTPs, put your own authenticated, rate-limited backend in
  front of GOWA.
- **One session, one instance.** Never run two GOWA instances against the same
  WhatsApp session/database. WhatsApp will churn or log the companion out.
- **Backups are secrets.** Session keys in a `pg_dump` can impersonate the linked
  device. Encrypt and restrict them.

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `https://.../health` fails after deploy | DNS not pointing at the VPS, port 80/443 blocked, or certificate not issued | Check `dig +short api.whatsapp.ktorganicshop.com`, provider firewall, `journalctl -u caddy`; keep the record DNS-only for the first run |
| `502 Bad Gateway` | GOWA is stopped or not listening on `127.0.0.1:8081` | `systemctl status gowa`; `ss -ltnp \| grep 8081`; read the GOWA log |
| `/health` returns `503` | Device manager not initialized, often a database connection failure | Check `journalctl -u gowa` for PostgreSQL/TLS errors; verify `DB_URI` from the VPS |
| Deploy fails with `duplicate site address` | Another app already uses `api.whatsapp.ktorganicshop.com` or the same extra host | Give this app a unique `PUBLIC_BASE_URL`/`GOWA_CADDY_EXTRA_HOSTS`; the failed snippet is rolled back |
| Deploy fails with `caddy validate failed` | The output names the file/line; usually the new snippet or another app's file | The previous GOWA snippet is restored automatically; fix the reported file and redeploy |
| `import` errors or `File to import not found: security_headers` | Base Caddyfile is foreign and does not define the shared snippet | Re-run `sudo bash vps-scripts/caddy/install-base.sh` or let the renderer inline headers; verify the base imports `sites-enabled/*.caddy` |
| `GOWA_CADDY_SITE_ID` contains invalid characters | Site id must be lowercase letters, digits, `.`, `_`, `-` | Use for example `gowa-otp` |
| `APP_PORT` already in use | Another app (for example PayConnect on 8080) uses the port | Pick a unique port (this deployment uses 8081) and redeploy |
| `unknown database type` at startup | `DB_URI` does not start with `postgres://` | Convert `postgresql://` to `postgres://` and redeploy |
| Deploy fails with `DB_URI must be a PostgreSQL URI` | Placeholder or wrong scheme in the secret | Use a real `postgres://` URI without `CHANGE_ME` |
| `401 Unauthorized` | Wrong Basic Auth credentials, or a colon in the password | Recheck `APP_BASIC_AUTH`; regenerate the password without `:` |
| `400 DEVICE_ID_REQUIRED` | No device exists yet, so no default device can be resolved | Create a slot with `POST /devices` (section 6.2), then pair it |
| `device not found` | Sent `X-Device-Id` with a slot alias that no longer exists after restart | Omit `X-Device-Id` for the default/only device, or read the current ID from `GET /devices` |
| Pairing code rejected/expired | Code is short-lived | Call `POST /devices/<id>/login/code?phone=...` again and enter the new code immediately |
| Pairing succeeds but sends fail | Session logged out, phone removed the linked device, or the phone has no WhatsApp | Check `GET /devices/<id>/status` and the `/devices` state; re-pair if WhatsApp shows the companion as removed |
| `database initialization error` / TLS error | Wrong password, URL-encoding, CA, or `sslmode` | Test the exact `DB_URI` with `psql` from the VPS; percent-encode the password |
| Certificate issuance fails | Port 80 blocked or a proxy intercepts HTTP-01 | Allow port 80; set the DNS record to DNS-only; retry Caddy |
| Deploy succeeds but the API is unreachable publicly | `PUBLIC_BASE_URL` origin mismatch or `VPS_HOST` is not the public IP | Confirm both secrets; check `gowa-otp.caddy` and `systemctl reload caddy` |

Useful on-VPS checks:

```bash
systemctl status gowa caddy --no-pager
journalctl -u gowa -n 100 --no-pager
journalctl -u caddy -n 100 --no-pager
ss -ltnp | grep -E ':(80|443|8080|8081)\b'
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
curl -v http://127.0.0.1:8081/health
curl -v http://127.0.0.1/health -H 'Host: api.whatsapp.ktorganicshop.com'
```

## 11. Remove the deployment

On the VPS, remove only this app; the shared Caddy instance and other apps stay:

```bash
# Delete this app's route, validate, and reload
bash vps-scripts/caddy/apply-site.sh --site-id gowa-otp --remove

systemctl disable --now gowa
rm -f /etc/systemd/system/gowa.service
systemctl daemon-reload
rm -rf /opt/gowa

# Only if this VPS no longer hosts any app:
# systemctl disable --now caddy
# apt-get remove -y caddy
# rm -f /etc/caddy/Caddyfile
```

Then delete the DNS record, revoke the database role, and remove the linked device
from WhatsApp (**Linked devices → Log out**) so the session is invalidated. Remove
the GitHub secrets and, if desired, the workflow file.
