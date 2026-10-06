#!/usr/bin/env bash
set -Eeuo pipefail

# One-Shot n8n Installer
# Target: fresh Ubuntu 22.04 VPS with about 1 GiB RAM.
# Installs Docker + Compose, n8n + SQLite, Nginx, Let's Encrypt, swap,
# low-memory defaults, and lifecycle helpers.

STACK_DIR="/opt/one-shot-n8n"
DATA_DIR="/var/lib/one-shot-n8n"
BACKUP_DIR="/var/backups/one-shot-n8n"
ACME_WEBROOT="/var/www/one-shot-n8n"
NGINX_CONF="/etc/nginx/conf.d/one-shot-n8n.conf"
ENV_FILE="${STACK_DIR}/.env"
COMPOSE_FILE="${STACK_DIR}/compose.yaml"
HELPER_DIR="${STACK_DIR}/bin"
RAW_BASE="${ONE_SHOT_REPO_RAW:-https://raw.githubusercontent.com/7020227649/One-Shot-n8n-installer-on-1-gb-ram-vps-with-domain/main}"
MIN_RAM_MB=768
SWAP_SIZE_GB=2

log() { printf '\n[one-shot] %s\n' "$*"; }
die() { printf '\n[error] %s\n' "$*" >&2; exit 1; }
trap 'die "Installation failed at line $LINENO. Check: docker compose -f \"$COMPOSE_FILE\" logs --tail=100 n8n"' ERR

require_root() { [[ $EUID -eq 0 ]] || die "Run as root or with sudo."; }

check_system() {
  [[ -r /etc/os-release ]] || die "Cannot detect operating system."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 22.04 ]] || die "Ubuntu 22.04 is required; detected ${PRETTY_NAME:-unknown}."
  case "$(dpkg --print-architecture)" in amd64|arm64) ;; *) die "Only amd64 and arm64 are supported." ;; esac
  local ram_mb
  ram_mb="$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
  (( ram_mb >= MIN_RAM_MB )) || die "Detected ${ram_mb} MB RAM. A 1 GB-class VPS is required."
  log "Ubuntu 22.04 $(dpkg --print-architecture), ${ram_mb} MB RAM detected."
}

validate_args() {
  [[ $# -eq 2 ]] || die "Usage: $0 <domain> <email>"
  DOMAIN="$1"
  EMAIL="$2"
  [[ $DOMAIN =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "Invalid domain: $DOMAIN"
  [[ $EMAIL =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "Invalid email: $EMAIL"
}

check_ports() {
  apt-get update -y >/dev/null
  apt-get install -y iproute2 >/dev/null
  for port in 80 443; do
    if ss -ltn "( sport = :${port} )" | tail -n +2 | grep -q .; then
      die "TCP port ${port} is already in use. This installer expects a fresh VPS."
    fi
  done
}

configure_swap() {
  local swap_mb
  swap_mb="$(free -m | awk '/^Swap:/ {print $2}')"
  if (( swap_mb < 1024 )); then
    log "Creating ${SWAP_SIZE_GB} GB swap safety net..."
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    fallocate -l "${SWAP_SIZE_GB}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE_GB*1024)) status=progress
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -qE '^/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  else
    log "Existing swap: ${swap_mb} MB; keeping it."
  fi
  cat >/etc/sysctl.d/99-one-shot-n8n.conf <<'SYSCTL'
vm.swappiness=10
vm.vfs_cache_pressure=50
SYSCTL
  sysctl --system >/dev/null
}

install_docker_and_proxy() {
  export DEBIAN_FRONTEND=noninteractive
  log "Installing Nginx, Certbot and prerequisites..."
  apt-get install -y ca-certificates curl gnupg nginx certbot python3 >/dev/null

  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    log "Installing Docker Engine and Compose plugin..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    # shellcheck disable=SC1091
    source /etc/os-release
    cat >/etc/apt/sources.list.d/docker.sources <<DOCKER
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-jammy}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER
    apt-get update -y >/dev/null
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  fi
  systemctl enable --now docker
  docker version >/dev/null
  docker compose version >/dev/null
}

prepare_dirs() {
  install -d -m 0755 "$STACK_DIR" "$HELPER_DIR" "$DATA_DIR" "$BACKUP_DIR" "$ACME_WEBROOT"
  chown 1000:1000 "$DATA_DIR"
}

latest_stable() {
  curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: one-shot-n8n-installer' \
    'https://api.github.com/repos/n8n-io/n8n/releases?per_page=30' |
    python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if not r.get("draft") and not r.get("prerelease"):
        print(r["tag_name"].split("@", 1)[-1].lstrip("v"))
        break
else:
    raise SystemExit("No stable n8n release found")
'
}

write_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    [[ ${N8N_DOMAIN:-} == "$DOMAIN" ]] || die "An existing installation uses domain ${N8N_DOMAIN:-unknown}. Refusing to replace it."
    return
  fi
  log "Resolving the latest stable n8n release..."
  local version
  version="$(latest_stable)"
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Could not resolve a stable n8n version."
  cat >"$ENV_FILE" <<EOF_ENV
N8N_VERSION=$version
N8N_DOMAIN=$DOMAIN
N8N_EMAIL=$EMAIL
N8N_DATA_DIR=$DATA_DIR
N8N_TIMEZONE=UTC
N8N_CONCURRENCY=1
N8N_NODE_HEAP_MB=384
N8N_MEMORY_LIMIT_MB=700
N8N_MEMORY_SWAP_LIMIT_MB=900
N8N_EXECUTION_MAX_AGE_HOURS=168
N8N_EXECUTION_MAX_COUNT=2000
EOF_ENV
  chmod 600 "$ENV_FILE"
}

install_stack_files() {
  log "Installing Compose stack and management commands..."
  curl -fsSL "$RAW_BASE/compose.yaml" -o "$COMPOSE_FILE"
  local cmd
  for cmd in n8n-version n8n-status n8n-logs n8n-restart n8n-backup n8n-update n8n-restore n8n-uninstall; do
    curl -fsSL "$RAW_BASE/scripts/$cmd" -o "$HELPER_DIR/$cmd"
    chmod 0755 "$HELPER_DIR/$cmd"
    ln -sfn "$HELPER_DIR/$cmd" "/usr/local/bin/$cmd"
  done
  chmod 0600 "$COMPOSE_FILE"
}

write_nginx_http() {
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  cat >"$NGINX_CONF" <<EOF_NGX
map \$http_upgrade \$one_shot_connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 16m;

    location /.well-known/acme-challenge/ {
        root $ACME_WEBROOT;
        default_type text/plain;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF_NGX
  nginx -t >/dev/null
  systemctl enable --now nginx
  systemctl reload nginx
}

wait_ready() {
  local i
  for i in $(seq 1 100); do
    if curl -fsS --max-time 5 http://127.0.0.1:5678/healthz/readiness >/dev/null 2>&1; then return 0; fi
    sleep 3
  done
  return 1
}

start_stack() {
  log "Pulling n8n image and starting the stack..."
  (cd "$STACK_DIR" && docker compose pull n8n >/dev/null && docker compose up -d n8n >/dev/null)
  wait_ready || { docker compose -f "$COMPOSE_FILE" logs --tail=150 n8n >&2 || true; die "n8n did not become ready."; }
}

enable_https() {
  log "Requesting the Let's Encrypt certificate..."
  certbot certonly --webroot --webroot-path "$ACME_WEBROOT" --agree-tos --non-interactive --keep-until-expiring -m "$EMAIL" -d "$DOMAIN" >/dev/null

  cat >"$NGINX_CONF" <<EOF_NGX
map \$http_upgrade \$one_shot_connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 16m;
    location /.well-known/acme-challenge/ { root $ACME_WEBROOT; default_type text/plain; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    client_max_body_size 16m;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$one_shot_connection_upgrade;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_set_header Expect "";
    }
}
EOF_NGX
  nginx -t >/dev/null
  systemctl reload nginx
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/one-shot-n8n-nginx <<'HOOK'
#!/usr/bin/env bash
set -e
systemctl reload nginx
HOOK
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/one-shot-n8n-nginx
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
}

main() {
  require_root
  validate_args "$@"
  check_system
  check_ports
  configure_swap
  install_docker_and_proxy
  prepare_dirs
  write_env
  install_stack_files
  write_nginx_http
  start_stack
  enable_https
  wait_ready || die "n8n is not ready after HTTPS configuration."

  # shellcheck disable=SC1090
  source "$ENV_FILE"
  cat <<EOF

Installation complete.

