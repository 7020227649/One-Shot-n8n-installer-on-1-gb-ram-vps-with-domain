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
INSTALLER_UNIT="one-shot-n8n-install.service"
BOOTSTRAP_SCRIPT="${STACK_DIR}/install.sh"

log() { printf '\n[one-shot] %s\n' "$*"; }
die() { printf '\n[error] %s\n' "$*" >&2; exit 1; }
trap '_rc=$?; _msg="Installation failed at line $LINENO (exit $_rc)."; [[ -f "$COMPOSE_FILE" ]] && _msg+=" Check: docker compose -f \"$COMPOSE_FILE\" logs --tail=100 n8n"; die "$_msg"' ERR

require_root() { [[ $EUID -eq 0 ]] || die "Run as root or with sudo."; }

heal_package_manager() {
  export DEBIAN_FRONTEND=noninteractive
  # Wait if unattended-upgrades or another apt process holds locks (up to 30s)
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    if (( waited >= 30 )); then
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done
  # Recover interrupted package manager state from prior failed commands
  dpkg --configure -a >/dev/null 2>&1 || true
  apt-get install -f -y >/dev/null 2>&1 || true
}

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

prompt_for_details() {
  [[ -r /dev/tty ]] || die "Domain and email are required. Usage: $0 <domain> <email>"
  printf '\nOne-Shot n8n Installer\n'
  printf 'Enter the domain that already points to this VPS and an email for Let\047s Encrypt.\n\n'
  read -r -p 'Domain (example: n8n.example.com): ' DOMAIN </dev/tty
  read -r -p 'Email  (example: you@example.com): ' EMAIL </dev/tty
  [[ -n $DOMAIN && -n $EMAIL ]] || die "Domain and email cannot be empty."
}

validate_args() {
  [[ $# -eq 0 || $# -eq 2 ]] || die "Usage: $0 [domain email]"
  if [[ $# -eq 0 ]]; then
    # If a prior run reached environment creation before SSH disconnected,
    # reuse its saved values so rerunning the one-command installer resumes
    # automatically instead of asking for the domain/email again.
    if [[ -r "$ENV_FILE" ]]; then
      # shellcheck disable=SC1090
      source "$ENV_FILE"
      DOMAIN="${N8N_DOMAIN:-}"
      EMAIL="${N8N_EMAIL:-}"
      if [[ -n $DOMAIN && -n $EMAIL ]]; then
        log "Resuming the existing installation for $DOMAIN using saved configuration."
      else
        prompt_for_details
      fi
    else
      prompt_for_details
    fi
  else
    DOMAIN="$1"
    EMAIL="$2"
  fi
  [[ $DOMAIN =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "Invalid domain: $DOMAIN"
  # Exclude '#' from email to prevent it truncating .env values when sourced as shell.
  [[ $EMAIL =~ ^[^[:space:]@#]+@[^[:space:]@#]+\.[^[:space:]@#]+$ ]] || die "Invalid email: $EMAIL"
}
port_listeners_are_only_nginx() {
  local port="$1" listeners line
  listeners="$(ss -H -ltnp "( sport = :${port} )")" || return 1
  [[ -n $listeners ]] || return 1
  while IFS= read -r line; do
    # With root privileges ss reports owning processes. Reject unknown owners
    # rather than assuming an active Nginx means every listener belongs to it.
    [[ $line == *'users:(("nginx"'* ]] || return 1
  done <<< "$listeners"
}

check_ports() {
  heal_package_manager
  apt-get update -y >/dev/null
  apt-get install -y iproute2 >/dev/null

  # Handle dirty VPS edge case: if Nginx was already present with only the default
  # welcome page, clear the default site so it does not conflict with this domain.
  if [[ -L /etc/nginx/sites-enabled/default || -f /etc/nginx/sites-enabled/default ]]; then
    if [[ ! -f "$NGINX_CONF" ]] && systemctl is-active --quiet nginx; then
      local other_sites
      other_sites="$(find /etc/nginx/sites-enabled -maxdepth 1 -type l ! -name default 2>/dev/null | wc -l)"
      if (( other_sites == 0 )); then
        log "Disabling default Nginx welcome site to prepare for n8n domain configuration..."
        rm -f /etc/nginx/sites-enabled/default
        systemctl reload nginx 2>/dev/null || true
      fi
    fi
  fi

  # Handle dirty VPS edge case: if default Apache2 is running, disable it to prevent port 80/443 conflicts.
  if systemctl is-active --quiet apache2 2>/dev/null; then
    if [[ ! -f "$NGINX_CONF" ]]; then
      log "Stopping default Apache2 service to allow Nginx reverse proxy on ports 80/443..."
      systemctl stop apache2 >/dev/null 2>&1 || true
      systemctl disable apache2 >/dev/null 2>&1 || true
    fi
  fi

  for port in 80 443; do
    if ss -H -ltn "( sport = :${port} )" | grep -q .; then
      # A rerun is safe only if this install's config is valid and every
      # listener on the occupied port is owned by Nginx.
      if [[ -f "$NGINX_CONF" ]] &&
         systemctl is-active --quiet nginx &&
         nginx -t >/dev/null 2>&1 &&
         grep -Fq "server_name $DOMAIN;" "$NGINX_CONF" &&
         port_listeners_are_only_nginx "$port"; then
        log "TCP port ${port} is already served by this installation's Nginx; allowing rerun."
      else
        die "TCP port ${port} is already in use by an unverified service. Stop it or inspect the existing Nginx configuration before rerunning."
      fi
    fi
  done
}

configure_swap() {
  local swap_mb swap_path
  swap_mb="$(free -m | awk '/^Swap:/ {print $2}')"
  swap_path=/swapfile
  if (( swap_mb < 1024 )); then
    if [[ -e /swapfile ]]; then
      if swapon --show=NAME --noheadings | grep -Fxq /swapfile; then
        # Preserve a live existing swapfile; add a separate one rather than replacing it.
        swap_path=/swapfile.one-shot-n8n
      else
        die "/swapfile already exists but is not active swap. Refusing to overwrite an unknown file; inspect it and rerun."
      fi
    fi

    if [[ -e "$swap_path" ]]; then
      if swapon --show=NAME --noheadings | grep -Fxq "$swap_path"; then
        log "Existing $swap_path is already active; preserving it."
      else
        die "$swap_path already exists but is not active swap. Refusing to overwrite an unknown file; inspect it and rerun."
      fi
    else
      log "Creating ${SWAP_SIZE_GB} GB swap safety net at $swap_path..."
      if ! fallocate -l "${SWAP_SIZE_GB}G" "$swap_path" 2>/dev/null; then
        rm -f -- "$swap_path"
        dd if=/dev/zero of="$swap_path" bs=1M count=$((SWAP_SIZE_GB*1024)) status=none
      fi
      chmod 600 "$swap_path"
      mkswap "$swap_path" >/dev/null
      swapon "$swap_path"
      grep -qF "$swap_path none swap sw 0 0" /etc/fstab || echo "$swap_path none swap sw 0 0" >> /etc/fstab
    fi
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
  heal_package_manager
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
  install -d -m 0755 "$STACK_DIR" "$HELPER_DIR" "$BACKUP_DIR" "$ACME_WEBROOT"
  # n8n runs as UID 1000 (the 'node' user) inside the container.
  install -d -m 0755 -o 1000 -g 1000 "$DATA_DIR"
}

latest_stable() {
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 \
    -H 'Accept: application/vnd.github+json' -H 'User-Agent: one-shot-n8n-installer' \
    'https://api.github.com/repos/n8n-io/n8n/releases?per_page=100' |
    python3 -c '
import json, re, sys
releases = json.load(sys.stdin)
# GitHub lists channel aliases (for example, "stable") alongside versioned
# releases. Select the first non-draft, non-prerelease semver release tag only.
for r in releases:
    tag = r.get("tag_name", "")
    match = re.fullmatch(r"(?:n8n@)?v?(\d+\.\d+\.\d+)", tag)
    if not r.get("draft") and not r.get("prerelease") and match:
        print(match.group(1))
        break
else:
    raise SystemExit("No semantic-version stable n8n release found in GitHub API response")
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
  local tmp cmd
  tmp="$(mktemp "${STACK_DIR}/compose.yaml.XXXXXX")"
  if ! curl -fsSL "$RAW_BASE/compose.yaml" -o "$tmp"; then
    rm -f -- "$tmp"
    die "Could not download Compose configuration."
  fi
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$COMPOSE_FILE"

  for cmd in n8n-version n8n-status n8n-logs n8n-restart n8n-backup n8n-update n8n-restore n8n-uninstall; do
    tmp="$(mktemp "${HELPER_DIR}/${cmd}.XXXXXX")"
    if ! curl -fsSL "$RAW_BASE/scripts/$cmd" -o "$tmp"; then
      rm -f -- "$tmp"
      die "Could not download helper script: $cmd"
    fi
    chmod 0755 "$tmp"
    mv -f -- "$tmp" "$HELPER_DIR/$cmd"
    ln -sfn "$HELPER_DIR/$cmd" "/usr/local/bin/$cmd"
  done
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
  for ((i=0; i<100; i++)); do
    if curl -fsS --max-time 5 http://127.0.0.1:5678/healthz/readiness >/dev/null 2>&1; then return 0; fi
    sleep 3
  done
  return 1
}

start_stack() {
  log "Pulling n8n image and starting the stack..."
  (cd "$STACK_DIR" && docker compose pull n8n >/dev/null && docker compose up -d --force-recreate --remove-orphans n8n >/dev/null)
  wait_ready || { docker compose -f "$COMPOSE_FILE" logs --tail=150 n8n >&2 || true; die "n8n did not become ready."; }
}

enable_https() {
  log "Requesting the Let's Encrypt certificate..."
  certbot certonly --webroot --webroot-path "$ACME_WEBROOT" \
    --agree-tos --non-interactive --no-eff-email --keep-until-expiring \
    -m "$EMAIL" -d "$DOMAIN" >/dev/null

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
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

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
set -Eeuo pipefail
systemctl reload nginx
HOOK
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/one-shot-n8n-nginx
  # Enable certbot auto-renewal timer when available (apt certbot). The snap
  # variant of certbot manages its own renewal timer (snap.certbot.renew.timer)
  # and does not expose a certbot.timer systemd unit; the || true handles both.
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
}


start_persistent_install() {
  command -v systemd-run >/dev/null 2>&1 || die "systemd-run is required to keep installation running after SSH disconnects."
  command -v journalctl >/dev/null 2>&1 || die "journalctl is required to inspect installation progress."

  if systemctl is-active --quiet "$INSTALLER_UNIT"; then
    log "The installer is already running as a background service."
    printf 'Follow progress: sudo journalctl -fu %s\n' "$INSTALLER_UNIT"
    return 0
  fi

  # Reset any failed prior transient unit state
  systemctl reset-failed "$INSTALLER_UNIT" >/dev/null 2>&1 || true

  install -d -m 0755 "$STACK_DIR"
  local tmp
  tmp="$(mktemp "${STACK_DIR}/install.sh.XXXXXX")"
  if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 "$RAW_BASE/install.sh" -o "$tmp"; then
    rm -f -- "$tmp"
    die "Could not download a persistent copy of the installer."
  fi
  chmod 0755 "$tmp"
  mv -f -- "$tmp" "$BOOTSTRAP_SCRIPT"

  log "Starting installation in the background so SSH disconnects will not stop it..."
  if ! systemd-run --unit="$INSTALLER_UNIT" --collect --property=Type=exec \
      /usr/bin/env ONE_SHOT_INSTALLER_SERVICE=1 /bin/bash "$BOOTSTRAP_SCRIPT" "$DOMAIN" "$EMAIL"; then
    if systemctl is-active --quiet "$INSTALLER_UNIT"; then
      log "The background installer is already running."
    else
      die "Could not start the background installer. Check: sudo journalctl -u $INSTALLER_UNIT -n 100 --no-pager"
    fi
  fi

  printf '\nThe installation is running independently of this SSH connection.\n'
  printf 'View progress: sudo journalctl -fu %s\n' "$INSTALLER_UNIT"
  printf 'View recent logs: sudo journalctl -u %s -n 100 --no-pager\n' "$INSTALLER_UNIT"
}

main() {
  require_root

  # A reconnect should not start a second installation or prompt for values
  # while the detached systemd service is already doing the work.
  if [[ ${ONE_SHOT_INSTALLER_SERVICE:-0} != 1 ]] && systemctl is-active --quiet "$INSTALLER_UNIT"; then
    log "The installer is already running independently of SSH."
    printf 'Follow progress: sudo journalctl -fu %s\n' "$INSTALLER_UNIT"
    return 0
  fi

  validate_args "$@"
  check_system

  # The parent process exits after launching the transient service. The
  # service keeps running if this SSH session closes or its client disconnects.
  if [[ ${ONE_SHOT_INSTALLER_SERVICE:-0} != 1 ]]; then
    start_persistent_install
    return 0
  fi

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

Open: https://$N8N_DOMAIN
n8n version: $N8N_VERSION
Data: $N8N_DATA_DIR
Backups: $BACKUP_DIR

Commands:
  sudo n8n-status
  sudo n8n-update
  sudo n8n-backup
  sudo n8n-restore <backup.tar.gz>
  sudo n8n-logs
  sudo n8n-restart
EOF
}

main "$@"
