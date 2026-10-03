# wg-easy installer

One-shot, **fully non-interactive** installer that turns a fresh Ubuntu 24.04 host into a working
[WireGuard](https://www.wireguard.com/) VPN with the [wg-easy](https://github.com/wg-easy/wg-easy) web UI
behind **Caddy** (automatic HTTPS).

Everything is driven by CLI flags / environment variables — **there are no prompts**, so it is safe to run
from cloud-init, Ansible, or an SSH one-liner.

## What it installs

| Component | Detail |
|---|---|
| **Docker Engine + Compose plugin** | Official Docker apt repo (conflicting `docker.io`/`containerd`/`runc` packages are removed) |
| **wg-easy** | `ghcr.io/wg-easy/wg-easy:15` — pinned to the v15 major tag (`:latest` is still v14) |
| **Caddy v2** | `caddy:2.10-alpine`, terminates TLS and reverse-proxies the UI |

The UI container gets **no host port**; only Caddy talks to it. WireGuard itself is published on
`${WG_PORT}/udp`.

## Requirements

- **Ubuntu 24.04** (other releases work with `--force`, but the Docker repo then uses your codename)
- **Root** (the script re-execs itself with `sudo`)
- A **public FQDN** pointing at the host, for Let's Encrypt
- Inbound ports open in your provider firewall: **tcp/80, tcp/443, udp/443, udp/51820**
- systemd (i.e. a normal host — **not** a container or WSL1)

## Quick start

```bash
curl -fsSLO https://raw.githubusercontent.com/Warriorgiroro/wg-easy-installer/main/install-wg-easy.sh
chmod +x install-wg-easy.sh
sudo ./install-wg-easy.sh vpn.example.com
```

The admin password is **generated** if you don't pass one, and printed at the end.

Want to preview the generated config without installing anything?

```bash
sudo ./install-wg-easy.sh vpn.example.com --config-only
```

## Options

| Flag | Env var | Default | Meaning |
|---|---|---|---|
| `--domain FQDN` | `WG_DOMAIN` | *(required)* | UI domain, e.g. `vpn.example.com` |
| `--host HOST` | `WG_HOST` | `= domain` | Endpoint clients dial |
| `--port N` | `WG_PORT` | `51820` | Public WireGuard UDP port |
| `--admin-user NAME` | `WG_ADMIN_USER` | `admin` | Web UI admin username |
| `--admin-password PW` | `WG_ADMIN_PASSWORD` | *generated* | Web UI admin password |
| `--dns A,B` | `WG_DNS` | `1.1.1.1,8.8.8.8` | DNS pushed to VPN clients |
| `--subnet CIDR` | `WG_SUBNET` | `10.89.89.0/24` | Internal docker network **and** `TRUSTED_PROXIES` |
| `--email ADDR` | `ACME_EMAIL` | `admin@$WG_DOMAIN` | ACME account email |
| `--tls MODE` | `WG_TLS` | `letsencrypt` | `letsencrypt` or `internal` (Caddy local CA, for labs) |
| `--dir PATH` | `WG_DIR` | `/opt/wg-easy` | Install directory |
| `--config-only` | `WG_CONFIG_ONLY=1` | `0` | Only render config files, install/start nothing |
| `--skip-dns-check` | `WG_SKIP_DNS_CHECK=1` | `0` | Don't verify the domain resolves here |
| `--force` | `WG_FORCE=1` | `0` | Continue past preflight warnings |

## What it creates

```
/opt/wg-easy/
  .env          # all config values      (chmod 600)
  compose.yml   # wg-easy + caddy        (one compose project)
  Caddyfile     # reverse proxy / TLS
  README.txt    # credentials + operator notes (chmod 600)
```

`/opt/wg-easy` is **idempotent**: re-running the installer reuses the existing `.env` (same admin password,
same domain) and just converges the containers.

## Common operations

```bash
cd /opt/wg-easy
docker compose ps
docker compose logs -f wg-easy
docker compose logs -f caddy
docker compose pull && docker compose up -d   # update images
docker compose down                           # stop (volumes are kept)
```

## Hardening / notes

- **Delete the plaintext password after first login.** wg-easy only reads `INIT_*` on the very first start:

  ```bash
  cd /opt/wg-easy
  sed -i '/^WG_ADMIN_PASSWORD=/d' .env
  ```

- `WG_TLS=internal` issues a **local CA** — clients must trust it. Use it for labs/private DNS only.
- Let's Encrypt failures are almost always DNS: the domain must resolve to this host and tcp/80+tcp/443
  must be reachable from the internet.
- The script never edits global Docker config and never touches your firewall beyond `ufw` rules for the
  four ports above (only when `ufw` is already active).

## License

Not specified — add one if you plan to redistribute.
