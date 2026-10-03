#!/usr/bin/env bash
#
# install-wg-easy.sh
# --------------------------------------------------------------------------
# One-shot, fully non-interactive installer for:
#   * Docker Engine + Compose plugin on Ubuntu 24.04 (official Docker repo)
#   * wg-easy v15 (WireGuard + web UI) in Docker
#   * Caddy v2 reverse proxy with automatic HTTPS in front of the wg-easy UI
#
# Layout created under $WG_DIR (default /opt/wg-easy):
#   .env          -> all configuration values (chmod 600)
#   compose.yml   -> wg-easy + caddy, single project
#   Caddyfile     -> reverse proxy config for the UI domain
#
# Usage:
#   sudo ./install-wg-easy.sh vpn.example.com
#   sudo WG_DOMAIN=vpn.example.com WG_ADMIN_PASSWORD='...' ./install-wg-easy.sh
#
# Everything is driven by environment variables / CLI flags, never by prompts.
# The script is idempotent: re-running it reuses the existing .env (same admin
# password, same domain) and just converges the containers.
# --------------------------------------------------------------------------

set -Eeuo pipefail

# ------------------------------ configuration ------------------------------

# Prescan for --dir so an existing install can be found before loading .env.
_wg_dir_cli=""
_argv=("$@")
_i=0
while (( _i < ${#_argv[@]} )); do
	case "${_argv[_i]}" in
		--dir)    _wg_dir_cli="${_argv[_i + 1]:-}"; _i=$((_i + 2)) ;;
		--dir=*)  _wg_dir_cli="${_argv[_i]#--dir=}"; _i=$((_i + 1)) ;;
		*)        _i=$((_i + 1)) ;;
	esac
done

WG_DIR="${_wg_dir_cli:-${WG_DIR:-/opt/wg-easy}}"

# Reuse the previous install's values as defaults (keeps the admin password).
if [[ -f "$WG_DIR/.env" ]]; then
	# shellcheck disable=SC1091
	{ set -a; . "$WG_DIR/.env"; set +a; } 2>/dev/null || true
fi

WG_DOMAIN="${WG_DOMAIN:-}"                                        # UI FQDN, e.g. vpn.example.com
WG_HOST="${WG_HOST:-}"                                            # endpoint clients dial (default: WG_DOMAIN)
WG_PORT="${WG_PORT:-51820}"                                       # public UDP port for WireGuard
WG_SUBNET="${WG_SUBNET:-10.89.89.0/24}"                           # internal docker network (also TRUSTED_PROXIES)
WG_ADMIN_USER="${WG_ADMIN_USER:-admin}"                           # wg-easy admin username
WG_ADMIN_PASSWORD="${WG_ADMIN_PASSWORD:-}"                        # empty => generated
WG_DNS="${WG_DNS:-1.1.1.1,8.8.8.8}"                               # DNS pushed to VPN clients
ACME_EMAIL="${ACME_EMAIL:-}"                                      # default: admin@$WG_DOMAIN
WG_TLS="${WG_TLS:-letsencrypt}"                                   # letsencrypt | internal
WGE_IMAGE="${WGE_IMAGE:-ghcr.io/wg-easy/wg-easy:15}"              # never use :latest (that is v14)
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2.10-alpine}"
WG_CONFIG_ONLY="${WG_CONFIG_ONLY:-0}"                             # 1 = render config files, do not install/start
WG_SKIP_DNS_CHECK="${WG_SKIP_DNS_CHECK:-0}"
WG_FORCE="${WG_FORCE:-0}"                                         # 1 = continue past failed preflight checks

# -------------------------------- utilities --------------------------------

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

usage() {
	awk 'NR==1 {next} /^set -Eeuo pipefail/ {exit} {sub(/^# ?/, ""); print}' "$0"
	cat <<'EOF'

Flags (environment variable equivalents in brackets):
  --domain FQDN        UI domain, e.g. vpn.example.com            [WG_DOMAIN]
  --host HOST          endpoint clients dial, default = domain    [WG_HOST]
  --port N             public WireGuard UDP port (default 51820)   [WG_PORT]
  --admin-user NAME    UI admin username (default admin)          [WG_ADMIN_USER]
  --admin-password PW  UI admin password (default: generated)     [WG_ADMIN_PASSWORD]
  --dns A,B            DNS pushed to clients                      [WG_DNS]
  --subnet CIDR        internal docker subnet (default 10.89.89.0/24) [WG_SUBNET]
  --email ADDR         ACME account email                         [ACME_EMAIL]
  --tls MODE           letsencrypt | internal                     [WG_TLS]
  --dir PATH           install directory (default /opt/wg-easy)   [WG_DIR]
  --config-only        only render .env/compose.yml/Caddyfile     [WG_CONFIG_ONLY=1]
  --skip-dns-check     do not verify that the domain points here  [WG_SKIP_DNS_CHECK=1]
  --force              continue despite preflight warnings        [WG_FORCE=1]
  -h, --help           this help
EOF
	exit "${1:-0}"
}

# ----------------------------------- args ----------------------------------

while (($#)); do
	case "$1" in
		--domain)         WG_DOMAIN="$2"; shift 2 ;;
		--domain=*)       WG_DOMAIN="${1#--domain=}"; shift ;;
		--host)           WG_HOST="$2"; shift 2 ;;
		--host=*)         WG_HOST="${1#--host=}"; shift ;;
		--port)           WG_PORT="$2"; shift 2 ;;
		--port=*)         WG_PORT="${1#--port=}"; shift ;;
		--admin-user)     WG_ADMIN_USER="$2"; shift 2 ;;
		--admin-user=*)   WG_ADMIN_USER="${1#--admin-user=}"; shift ;;
		--admin-password) WG_ADMIN_PASSWORD="$2"; shift 2 ;;
		--admin-password=*) WG_ADMIN_PASSWORD="${1#--admin-password=}"; shift ;;
		--dns)            WG_DNS="$2"; shift 2 ;;
		--dns=*)          WG_DNS="${1#--dns=}"; shift ;;
		--subnet)         WG_SUBNET="$2"; shift 2 ;;
		--subnet=*)       WG_SUBNET="${1#--subnet=}"; shift ;;
		--email)          ACME_EMAIL="$2"; shift 2 ;;
		--email=*)        ACME_EMAIL="${1#--email=}"; shift ;;
		--tls)            WG_TLS="$2"; shift 2 ;;
		--tls=*)          WG_TLS="${1#--tls=}"; shift ;;
		--dir)            WG_DIR="$2"; shift 2 ;;
		--dir=*)          WG_DIR="${1#--dir=}"; shift ;;
		--config-only)    WG_CONFIG_ONLY=1; shift ;;
		--skip-dns-check) WG_SKIP_DNS_CHECK=1; shift ;;
		--force)          WG_FORCE=1; shift ;;
		-h|--help)        usage 0 ;;
		-*)               die "unknown flag: $1 (try --help)" ;;
		*)                [[ -z "$WG_DOMAIN" ]] || die "unexpected argument: $1"; WG_DOMAIN="$1"; shift ;;
	esac
done

[[ -n "$WG_DOMAIN" ]] || die "no domain given: pass it as the first argument or set WG_DOMAIN=<fqdn> (see --help)"
[[ -n "$WG_HOST" ]] || WG_HOST="$WG_DOMAIN"
[[ -n "$ACME_EMAIL" ]] || ACME_EMAIL="admin@${WG_DOMAIN}"
case "$WG_TLS" in letsencrypt|internal) ;; *) die "WG_TLS must be 'letsencrypt' or 'internal' (got '$WG_TLS')" ;; esac
[[ "$WG_PORT" =~ ^[0-9]+$ && "$WG_PORT" -ge 1 && "$WG_PORT" -le 65535 ]] || die "invalid WG_PORT: $WG_PORT"
[[ "$WG_SUBNET" =~ ^[0-9a-fA-F:.]+/[0-9]{1,3}$ ]] || die "invalid WG_SUBNET: $WG_SUBNET"

# ------------------------------- root and OS -------------------------------

if [[ "$WG_CONFIG_ONLY" != "1" && $EUID -ne 0 ]]; then
	command -v sudo >/dev/null 2>&1 || die "must run as root"
	log "re-executing with sudo"
	exec sudo -E bash "$0" "$@"
fi

if [[ "$WG_CONFIG_ONLY" != "1" ]]; then
	# shellcheck disable=SC1091
	. /etc/os-release
	if [[ "${ID:-}" != "ubuntu" ]]; then
		[[ "$WG_FORCE" == "1" ]] || die "this installer targets Ubuntu (detected ID=${ID:-unknown}); use --force to override"
		warn "not Ubuntu (ID=${ID:-unknown}) — continuing because --force was given"
	elif [[ "${VERSION_ID%%.*}" != "24" ]]; then
		[[ "$WG_FORCE" == "1" ]] || die "expected Ubuntu 24.x, got ${VERSION_ID:-?}; use --force to override"
		warn "Ubuntu ${VERSION_ID} (not 24.x) — Docker repo will use codename ${UBUNTU_CODENAME:-$VERSION_CODENAME}"
	fi
	command -v systemctl >/dev/null 2>&1 || die "systemd not available — this installer needs a normal Ubuntu host (not a container/WSL1)"
	command -v apt-get >/dev/null 2>&1 || die "apt-get not found"
fi

# ------------------------------ docker install -----------------------------

install_docker() {
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		log "Docker + compose plugin already present ($(docker --version))"
		return 0
	fi

	step "Installing Docker Engine and the Compose plugin (official Docker apt repo)"
	export DEBIAN_FRONTEND=noninteractive
	local apt_opts=(-y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confnew)

	apt-get update "${apt_opts[@]}"
	apt-get install "${apt_opts[@]}" ca-certificates curl gnupg

	install -m 0755 -d /etc/apt/keyrings
	curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
	chmod a+r /etc/apt/keyrings/docker.asc

	local arch codename
	arch="$(dpkg --print-architecture)"
	# shellcheck disable=SC1091
	codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
	echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
		> /etc/apt/sources.list.d/docker.list

	apt-get update "${apt_opts[@]}"

	# Drop packages that conflict with docker-ce (Ubuntu's docker.io etc.).
	local conflicts=() p
	for p in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
		if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed'; then
			conflicts+=("$p")
		fi
	done
	if ((${#conflicts[@]})); then
		warn "removing conflicting packages: ${conflicts[*]}"
		apt-get "${apt_opts[@]}" remove "${conflicts[@]}"
	fi

	apt-get install "${apt_opts[@]}" \
		docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

	systemctl enable --now docker
	systemctl enable --now containerd 2>/dev/null || true

	local login_user="${SUDO_USER:-}"
	if [[ -z "$login_user" || "$login_user" == "root" ]]; then
		login_user="$(getent passwd | awk -F: '$3>=1000 && $3<60000 {print $1; exit}')"
	fi
	if [[ -n "$login_user" && "$login_user" != "root" ]]; then
		usermod -aG docker "$login_user"
		log "added '$login_user' to the docker group (log out/in for it to take effect)"
	fi

	docker --version
	docker compose version
}

# -------------------------------- preflight --------------------------------

port_in_use() { # proto port -> 0 if something listens
	local proto="$1" port="$2"
	if [[ "$proto" == "tcp" ]]; then
		[[ -n "$(ss -Hltnp "sport = :${port}" 2>/dev/null || true)" ]]
	else
		[[ -n "$(ss -Hlunp "sport = :${port}" 2>/dev/null || true)" ]]
	fi
}

preflight() {
	step "Preflight checks"

	local own_caddy=0
	# No pipe into `grep -q` here: under `set -o pipefail` an early-exiting grep
	# gives the pipeline a SIGPIPE status and the condition would be wrong.
	if [[ " $(docker ps --format '{{.Names}}' 2>/dev/null || true) " == *" wg-caddy "* ]]; then
		own_caddy=1
		log "found our own wg-caddy container — port checks for 80/443 skipped (idempotent re-run)"
	fi

	if ((!own_caddy)); then
		local busy=0 pair
		for pair in tcp:80 tcp:443 "udp:${WG_PORT}"; do
			if port_in_use "${pair%%:*}" "${pair##*:}"; then
				warn "port ${pair##*:}/${pair%%:*} is already in use by the host"
				ss -Hltnup "sport = :${pair##*:}" 2>/dev/null || true
				busy=1
			fi
		done
		if ((busy)); then
			[[ "$WG_FORCE" == "1" ]] || die "free ports 80, 443 and ${WG_PORT}/udp (or use --force) — nginx/apache/another VPN probably owns them"
		fi
	fi

	if [[ "$WG_TLS" == "internal" ]]; then
		warn "WG_TLS=internal: Caddy will use its own CA; clients must trust it (good for labs, not for public DNS)"
	elif [[ "$WG_SKIP_DNS_CHECK" != "1" ]]; then
		local public_ip resolved
		public_ip="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
		resolved="$(getent ahostsv4 "$WG_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
		if [[ -z "$resolved" ]]; then
			warn "$WG_DOMAIN does not resolve yet — Let's Encrypt will fail until DNS points to this host"
		elif [[ -n "$public_ip" && " $resolved " != *" $public_ip "* ]]; then
			warn "$WG_DOMAIN resolves to [$resolved] but this host's public IP looks like $public_ip"
			warn "certificate issuance will fail unless DNS (or a proxy/CDN) points here"
		else
			log "$WG_DOMAIN resolves to $resolved (matches this host)"
		fi
		warn "make sure your provider firewall allows inbound tcp/80, tcp/443, udp/443 and udp/${WG_PORT}"
	fi

	[[ "$WG_FORCE" == "1" ]] && warn "--force given: continuing despite any warning above"
	return 0
}

# ------------------------------- render files ------------------------------

generate_password() {
	# 24 hex chars = 96 bits of entropy from the kernel CSPRNG.
	# (No `tr | head` pipeline: SIGPIPE would abort the script under pipefail.)
	local raw
	raw="$(openssl rand -hex 16 2>/dev/null || od -An -tx1 -N 16 /dev/urandom | tr -d ' \n')"
	printf '%s' "${raw:0:24}"
}

render_configs() {
	step "Writing configuration to $WG_DIR"
	install -m 0700 -d "$WG_DIR"

	if [[ -z "$WG_ADMIN_PASSWORD" ]]; then
		WG_ADMIN_PASSWORD="$(generate_password)"
	fi

	umask 077
	cat > "$WG_DIR/.env" <<EOF
# Generated by install-wg-easy.sh — compose reads this file automatically.
# Keep chmod 600. Values are interpolated into compose.yml / Caddyfile.

# UI / TLS
WG_DOMAIN="$WG_DOMAIN"
ACME_EMAIL="$ACME_EMAIL"
WG_TLS="$WG_TLS"

# WireGuard endpoint advertised to clients
WG_HOST="$WG_HOST"
WG_PORT="$WG_PORT"
WG_DNS="$WG_DNS"
WG_SUBNET="$WG_SUBNET"

# wg-easy unattended first-run setup (v15)
WG_ADMIN_USER="$WG_ADMIN_USER"
WG_ADMIN_PASSWORD="$WG_ADMIN_PASSWORD"

# Images (pin the major tag; :latest is still v14)
WGE_IMAGE="$WGE_IMAGE"
CADDY_IMAGE="$CADDY_IMAGE"
EOF
	chmod 600 "$WG_DIR/.env"

	# compose.yml: single-quoted heredoc -> ${...} stays literal for compose.
	cat > "$WG_DIR/compose.yml" <<'YAML'
# Generated by install-wg-easy.sh — do not edit by hand, re-run the installer.
name: wg-easy

services:
  # WireGuard + web UI. No host port for the UI: only Caddy talks to it.
  wg-easy:
    image: ${WGE_IMAGE}
    container_name: wg-easy
    hostname: wg-easy
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    environment:
      # Listen on 80 inside the container; Caddy terminates TLS and proxies here.
      PORT: "80"
      HOST: "0.0.0.0"
      DISABLE_IPV6: "true"
      # Trust Caddy's X-Forwarded-* headers (whole docker subnet).
      TRUSTED_PROXIES: "${WG_SUBNET}"
      # Non-interactive first-run setup (only honoured on the very first start).
      INIT_ENABLED: "true"
      INIT_USERNAME: "${WG_ADMIN_USER}"
      INIT_PASSWORD: "${WG_ADMIN_PASSWORD}"
      INIT_HOST: "${WG_HOST}"
      INIT_PORT: "${WG_PORT}"
      INIT_DNS: "${WG_DNS}"
    volumes:
      - wg-easy-data:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    ports:
      # WireGuard: container always listens on 51820/udp, published as ${WG_PORT}.
      - "${WG_PORT}:51820/udp"
    networks:
      - wgnet

  # TLS front door for the web UI.
  caddy:
    image: ${CADDY_IMAGE}
    container_name: wg-caddy
    hostname: caddy
    restart: unless-stopped
    depends_on:
      - wg-easy
    ports:
      - "80:80/tcp"
      - "443:443/tcp"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    networks:
      - wgnet

networks:
  wgnet:
    name: wgnet
    driver: bridge
    ipam:
      config:
        - subnet: "${WG_SUBNET}"

volumes:
  wg-easy-data:
  caddy-data:
  caddy-config:
YAML
	chmod 644 "$WG_DIR/compose.yml"

	if [[ "$WG_TLS" == "internal" ]]; then
		cat > "$WG_DIR/Caddyfile" <<EOF
# Generated by install-wg-easy.sh
{
	# Local CA — clients must trust it (lab / private DNS only).
	local_certs
	# A client that dials a bare IP sends NO SNI, so Caddy cannot pick a
	# certificate and aborts the handshake with "tlsv1 alert internal error".
	# default_sni gives those clients a certificate. The https:// prefix on the
	# site block below is REQUIRED: without it Caddy skips the global TLS
	# options entirely (caddyserver/caddy#7325).
	default_sni ${WG_DOMAIN}
}

http://${WG_DOMAIN} {
	redir https://{host}{uri} permanent
}

https://${WG_DOMAIN} {
	encode zstd gzip
	log
	reverse_proxy wg-easy:80
}
EOF
	else
		cat > "$WG_DIR/Caddyfile" <<EOF
# Generated by install-wg-easy.sh
{
	email ${ACME_EMAIL}
}

${WG_DOMAIN} {
	encode zstd gzip
	log
	reverse_proxy wg-easy:80
}
EOF
	fi
	chmod 644 "$WG_DIR/Caddyfile"

	# Audit note for the operator.
	cat > "$WG_DIR/README.txt" <<EOF
wg-easy + Caddy, installed by install-wg-easy.sh

  UI            https://${WG_DOMAIN}
  admin user    ${WG_ADMIN_USER}
  admin pass    ${WG_ADMIN_PASSWORD}
  WG endpoint   ${WG_HOST}:${WG_PORT}/udp
  client DNS    ${WG_DNS}

Common commands (run inside ${WG_DIR}):

  docker compose ps
  docker compose logs -f wg-easy
  docker compose logs -f caddy
  docker compose pull && docker compose up -d     # update images
  docker compose down                             # stop (keeps volumes)

After the first successful login the INIT_* variables in .env are no longer
needed (wg-easy ignores them once setup is done) — delete those two lines to
stop keeping the plaintext password on disk:

  sed -i '/^WG_ADMIN_PASSWORD=/d' .env
  sed -i 's/^\( *INIT_PASSWORD: \).*/\1""/' compose.yml   # optional
EOF
	chmod 600 "$WG_DIR/README.txt"
}

# --------------------------------- firewall --------------------------------

configure_firewall() {
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
		step "Opening ports in ufw"
		ufw allow 80/tcp  >/dev/null 2>&1 || true
		ufw allow 443/tcp >/dev/null 2>&1 || true
		ufw allow 443/udp >/dev/null 2>&1 || true
		ufw allow "${WG_PORT}/udp" >/dev/null 2>&1 || true
		log "ufw rules added (80/tcp 443/tcp 443/udp ${WG_PORT}/udp)"
	else
		log "ufw not active — nothing to open here (check your cloud firewall)"
	fi
}

# ------------------------------- start & verify -----------------------------

start_stack() {
	step "Starting containers"
	cd "$WG_DIR"
	docker compose --env-file "$WG_DIR/.env" up -d

	step "Waiting for wg-easy to answer through Caddy"
	local code="" _
	for _ in $(seq 1 30); do
		code="$(curl -k -sS -o /dev/null -w '%{http_code}' --max-time 5 \
			--resolve "${WG_DOMAIN}:443:127.0.0.1" "https://${WG_DOMAIN}/" 2>/dev/null || true)"
		if [[ "$code" =~ ^(200|301|302|307|308)$ ]]; then
			log "https://${WG_DOMAIN}/ answered with HTTP $code"
			break
		fi
		sleep 2
	done

	echo
	docker compose --env-file "$WG_DIR/.env" ps || true
	echo

	if [[ ! "$code" =~ ^(200|301|302|307|308)$ ]]; then
		warn "the web UI did not answer yet (last curl code: ${code:-none})"
		warn "right after a fresh start this is normal for 30-90s while Caddy requests the certificate"
		warn "check:  docker compose -f ${WG_DIR}/compose.yml logs --tail=50 caddy"
		if [[ "$WG_TLS" != "internal" ]]; then
			warn "certificate problems are almost always DNS: ${WG_DOMAIN} must resolve to this host and tcp/80+tcp/443 must be reachable from the internet"
		else
			warn "WG_TLS=internal: import Caddy's root CA into your client, or you will get a TLS warning"
		fi
	fi
}

summary() {
	local base="https://${WG_DOMAIN}"
	cat <<EOF

$(printf '\033[1;36m%s\033[0m' '──────────────── wg-easy is deployed ────────────────')

  Web UI        ${base}
  Admin user    ${WG_ADMIN_USER}
  Admin pass    ${WG_ADMIN_PASSWORD}

  VPN endpoint  ${WG_HOST}:${WG_PORT}/udp   (add clients in the UI)
  Client DNS    ${WG_DNS}
  Config dir    ${WG_DIR}

  Files         ${WG_DIR}/.env (chmod 600), compose.yml, Caddyfile, README.txt

Next:
  1. Log in, create a client, scan the QR code with the WireGuard app.
  2. Make sure inbound udp/${WG_PORT} (plus tcp/80, tcp/443, udp/443) is open
     in your cloud/provider firewall.
  3. Delete the plaintext password from ${WG_DIR}/.env once you are logged in.

EOF
}

# ----------------------------------- main ----------------------------------

if [[ "$WG_CONFIG_ONLY" == "1" ]]; then
	render_configs
	log "config-only mode: rendered $WG_DIR/{.env,compose.yml,Caddyfile,README.txt} — nothing installed or started"
	exit 0
fi

install_docker
preflight
render_configs
configure_firewall
start_stack
summary
