# wg-easy installer

Two ways to get a working [WireGuard](https://www.wireguard.com/) VPN with the
[wg-easy](https://github.com/wg-easy/wg-easy) web UI behind **Caddy**
(automatic HTTPS) on a fresh Ubuntu 24.04 host:

| Track | Use it when | Entry point |
|---|---|---|
| **Shell script** | One host, one shot, no tooling | [`install-wg-easy.sh`](install-wg-easy.sh) |
| **Ansible role** | Many hosts, a repo, or you want drift-free re-runs | [`ansible/`](ansible/) |

Both produce **the same stack and the same config files** — the Ansible
templates are verified against the script's `--config-only` output.

## What gets installed

| Component | Detail |
|---|---|
| **Docker Engine + Compose plugin** | Official Docker apt repo (conflicting `docker.io`/`containerd`/`runc` packages are removed) |
| **wg-easy** | `ghcr.io/wg-easy/wg-easy:15` — pinned to the v15 major tag (`:latest` is still v14) |
| **Caddy v2** | `caddy:2.10-alpine`, terminates TLS and reverse-proxies the UI |

The UI container gets **no host port**; only Caddy talks to it. WireGuard is
published on `${WG_PORT}/udp`.

## Requirements

- **Ubuntu 24.04** (other releases work with `--force`; the Docker repo then uses your codename)
- **Root** (the script re-execs itself with `sudo`)
- A **public FQDN** pointing at the host for Let's Encrypt — or use the internal CA (see below)
- Inbound ports: **tcp/80, tcp/443, udp/443, udp/`$WG_PORT`** opened in your **cloud** firewall
- systemd (a normal host — not a container or WSL1)

---

## Track 1 — shell script

```bash
curl -fsSLO https://raw.githubusercontent.com/Warriorgiroro/wg-easy-installer/main/install-wg-easy.sh
chmod +x install-wg-easy.sh
sudo ./install-wg-easy.sh vpn.example.com
```

Preview the config without installing anything:

```bash
sudo ./install-wg-easy.sh vpn.example.com --config-only
```

### Options

| Flag | Env var | Default | Meaning |
|---|---|---|---|
| `--domain FQDN` | `WG_DOMAIN` | *(required)* | UI domain **or bare IP** |
| `--host HOST` | `WG_HOST` | `= domain` | Endpoint clients dial |
| `--port N` | `WG_PORT` | `51820` | Public WireGuard UDP port |
| `--admin-user NAME` | `WG_ADMIN_USER` | `admin` | Web UI admin username |
| `--admin-password PW` | `WG_ADMIN_PASSWORD` | *generated* | Web UI admin password |
| `--dns A,B` | `WG_DNS` | `1.1.1.1,8.8.8.8` | DNS pushed to VPN clients |
| `--subnet CIDR` | `WG_SUBNET` | `10.89.89.0/24` | Internal docker network **and** `TRUSTED_PROXIES` |
| `--email ADDR` | `ACME_EMAIL` | `admin@$WG_DOMAIN` | ACME account email |
| `--tls MODE` | `WG_TLS` | `letsencrypt` | `letsencrypt` or `internal` (Caddy's own CA) |
| `--dir PATH` | `WG_DIR` | `/opt/wg-easy` | Install directory |
| `--config-only` | `WG_CONFIG_ONLY=1` | `0` | Only render config files |
| `--skip-dns-check` | `WG_SKIP_DNS_CHECK=1` | `0` | Don't verify the domain resolves here |
| `--force` | `WG_FORCE=1` | `0` | Continue past preflight warnings |

---

## Track 2 — Ansible

No collections required (**ansible-core only**).

```bash
cd ansible
cp inventory.example.ini inventory.ini      # set ansible_host / ansible_user
$EDITOR inventory.ini group_vars/all.yml    # FQDN or IP, ports, TLS mode

ansible-playbook site.yml                   # apply
ansible-playbook site.yml --check --diff    # dry run
ansible-playbook site.yml -e wg_easy_port=50000 -e wg_easy_tls=internal
```

Example for a bare-IP install with a non-default WireGuard port:

```yaml
# group_vars/all.yml
wg_easy_domain: 203.0.113.10   # the IP clients use
wg_easy_tls: internal          # no domain -> Caddy issues its own cert
wg_easy_port: 50000            # udp/50000 for WireGuard
```

Key variables (full list in `ansible/group_vars/all.yml`):

| Variable | Default | Meaning |
|---|---|---|
| `wg_easy_domain` | *(required)* | FQDN **or bare IP** for the UI |
| `wg_easy_tls` | `letsencrypt` | `internal` = Caddy's own CA (no DNS needed) |
| `wg_easy_port` | `51820` | Public WireGuard UDP port |
| `wg_easy_host` | `= domain` | Endpoint clients dial |
| `wg_easy_admin_password` | *generated once* | Kept in `<dir>/.admin_password` |
| `wg_easy_manage_ufw` | `true` | Open the ports when ufw is already active |
| `wg_easy_force` | `false` | Skip the port preflight failure |

The role is **idempotent**: the admin password is generated once and stored on
the target, and WireGuard state lives in a docker volume, so re-runs converge
instead of resetting.

### What both tracks create

```
/opt/wg-easy/
  .env          # all config values      (chmod 600)
  compose.yml   # wg-easy + caddy        (one compose project)
  Caddyfile     # reverse proxy / TLS
  README.txt    # credentials + operator notes (chmod 600)
```

## Bare IP / no domain (and the SNI trap)

Let's Encrypt cannot issue for an IP, and ports 80/443 are often closed on VPS
providers. Use `--tls internal` (or `wg_easy_tls: internal`) and point the
domain at the IP.

Caddy picks its certificate **by SNI**, but a client that dials a bare IP sends
**no SNI** — so the handshake dies with:

```
curl: (35) OpenSSL ... error:0A000438:SSL routines::tlsv1 alert internal error
```

Both tracks therefore emit a Caddyfile with the workaround already in place:

```
{
    local_certs
    default_sni  <the IP>
}

http://<the IP>  { redir https://{host}{uri} permanent }
https://<the IP> { reverse_proxy wg-easy:80 }
```

The **`https://` prefix is required**: without it Caddy skips the global TLS
options entirely and `default_sni` is silently dropped
([caddyserver/caddy#7325](https://github.com/caddyserver/caddy/issues/7325)).
Caddy's own logs then show the cert being obtained, while every handshake still
fails — which is exactly the confusing part.

To silence browser warnings, trust Caddy's root CA:

```bash
docker compose -f /opt/wg-easy/compose.yml exec caddy \
  cat /data/caddy/pki/authorities/local/root.crt > caddy-root.crt
# then import caddy-root.crt into your OS/browser trust store
```

## Hardening / notes

- **Delete the plaintext password after first login.** wg-easy only reads
  `INIT_*` on the very first start:

  ```bash
  cd /opt/wg-easy && sed -i '/^WG_ADMIN_PASSWORD=/d' .env
  ```

- Changing the admin password via `--admin-password` / `wg_easy_admin_password`
  on an **existing** install has no effect (wg-easy ignores `INIT_*` after
  setup) — change it in the UI instead.
- Let's Encrypt failures are almost always DNS: the domain must resolve to the
  host and tcp/80 + tcp/443 must be reachable from the internet.
- Neither track edits global Docker config; `ufw` is only touched when it is
  already active.
- The WireGuard port is the one thing clients need open: `udp/<wg_easy_port>`.

## License

Not specified — add one if you plan to redistribute.
