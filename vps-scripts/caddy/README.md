# Shared Caddy: one VPS, many apps

GOWA does not own `/etc/caddy/Caddyfile`. Every app publishes one small file
into a directory that Caddy imports:

```
/etc/caddy/
  Caddyfile                 # base: global options + snippets + import (stable)
  sites-enabled/
    payconnect.caddy        # owned by the PayConnect repository
    gowa-otp.caddy          # owned by this repository
    .backups/               # automatic rollback copies (not imported)
```

The base file is written **once** and then left alone. A deploy only creates or
overwrites its own `<site-id>.caddy`, so GOWA and PayConnect cannot break each
other's routes. Before a reload the entire configuration is validated with
`caddy validate`; if validation fails the previous snippet is restored and Caddy
keeps serving the old config.

## Files

| Path | Purpose |
| --- | --- |
| `site.caddy.template` | Reverse-proxy snippet for one app (rendered on deploy) |
| `install-base.sh` | Provision/validate the shared base Caddyfile once per VPS |
| `apply-site.sh` | Standalone routing-only publisher (usable from other repos) |
| `sudoers.template` | Scoped sudo rules for a non-root routing-only deploy user |

## Base config (once per VPS)

The first deploy does this automatically. The PayConnect deploy already created
the same layout on the shared VPS, in which case GOWA leaves that base file and
its `(security_headers)` snippet untouched:

```bash
sudo bash vps-scripts/caddy/install-base.sh --email ops@example.com
```

A foreign hand-written base is **not** replaced: add this line to its global
section instead, or force a replacement with `--takeover` (a timestamped backup
is always kept):

```
import /etc/caddy/sites-enabled/*.caddy
```

## What GOWA controls

| Setting | Default | Purpose |
| ------- | ------- | ------- |
| `PUBLIC_BASE_URL` | required | Public origin. `https://host` gets automatic TLS; `http://host` serves plain HTTP |
| `GOWA_CADDY_SITE_ID` | `gowa-otp` | Filename: `/etc/caddy/sites-enabled/<id>.caddy`. **Unique per app** |
| `APP_PORT` | `8081` | Loopback port GOWA listens on. **Unique per app** (PayConnect uses 8080) |
| `GOWA_CADDY_UPSTREAM` | `127.0.0.1:<APP_PORT>` | `reverse_proxy` target, e.g. a container name for Docker |
| `GOWA_CADDY_EXTRA_HOSTS` | empty | Comma-separated additional hostnames |
| `VPS_ACME_EMAIL` | empty | Written to the base global block (first run only) |

Two apps must never share a site id, a public origin, or a port. If they do,
`caddy validate` fails with a duplicate-address error and the deploy is rolled
back — nothing else goes offline.

For containerised or custom-supervised Caddy, `GOWA_CADDY_VALIDATE_CMD` and
`GOWA_CADDY_RELOAD_CMD` override the local `caddy` and `systemctl` calls.

## Standalone publisher

```bash
bash vps-scripts/caddy/apply-site.sh \
  --site-id gowa-otp \
  --public-url https://api.whatsapp.ktorganicshop.com \
  --upstream 127.0.0.1:8081
```

Useful flags:

```bash
--extra-host www.whatsapp.ktorganicshop.com   # repeatable
--acme-email ops@example.com                  # only with --ensure-base
--ensure-base                                 # create/repair the base file (root)
--owner deploy:caddy                          # with --ensure-base: let CI write snippets
--dry-run                                     # print the rendered snippet and exit
--remove                                      # delete this app's route, validate, reload
```

## Operations

```bash
# What is loaded right now (shared with other apps)
ls -l /etc/caddy/sites-enabled/*.caddy

# Validate the whole config (all apps)
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

# Apply changes gracefully (zero downtime)
sudo systemctl reload caddy

# Remove GOWA's route without touching PayConnect
bash vps-scripts/caddy/apply-site.sh --site-id gowa-otp --remove

# Roll back GOWA only (copies are kept automatically)
ls -1t /etc/caddy/sites-enabled/.backups/gowa-otp.*
cp /etc/caddy/sites-enabled/.backups/gowa-otp.<timestamp> /etc/caddy/sites-enabled/gowa-otp.caddy
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && sudo systemctl reload caddy
```

`caddy validate` never mutates the running service, so it is always safe to run
before `systemctl reload caddy`.

See [`../../DEPLOYMENT.md`](../../DEPLOYMENT.md) for the full VPS, PostgreSQL,
pairing, OTP API, and troubleshooting instructions.
