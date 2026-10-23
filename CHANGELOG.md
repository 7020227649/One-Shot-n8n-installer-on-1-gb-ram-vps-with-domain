# Changelog

## 0.2.0 - 2026-10-23

### Added
- **Self-Healing Package Manager (`heal_package_manager`)**: Automatically detects and heals interrupted package manager states (`dpkg --configure -a`, `apt-get -f install`) and waits for transient background apt/unattended-upgrade locks to clear before proceeding.
- **Dirty VPS Port Conflict Resolution**: Automatically detects pre-installed Apache2 or default Ubuntu Nginx welcome sites (`sites-enabled/default`) on port 80/443 and disables them cleanly when no user sites exist, allowing smooth deployment on pre-configured cloud images.
- **Docker Compose Container Sanitation**: Added `--force-recreate --remove-orphans` to `docker compose up` to gracefully replace halted, dead, or dangling container instances from previous interrupted runs.
- **Transient Service Reset**: Added `systemctl reset-failed` before launching background installation units to ensure prior failed service states do not block subsequent runs.
- **Docker Healthcheck**: Added native Docker healthcheck (`wget -q -O - http://127.0.0.1:5678/healthz/readiness >/dev/null 2>&1 || exit 1`) in `compose.yaml`.
- **Filesystem Binary Storage Mode**: Added `N8N_DEFAULT_BINARY_DATA_MODE: filesystem` to store binary attachments on disk instead of SQLite / RAM.
- **`.gitattributes`**: Added repository-wide LF line ending enforcement (`eol=lf`).

### Fixed
- Added root/sudo check to `n8n-status`, `n8n-restart`, `n8n-logs`, `n8n-version`, and `n8n-uninstall`.
- Added explicit `/dev/tty` redirect to interactive `read` prompts in `n8n-restore`, `n8n-update`, and `n8n-uninstall` to prevent silent cancellations in piped or headless executions.
- Fixed `port_listeners_are_only_nginx` quote escaping in `install.sh`.
- Fixed the backup-rotation pipeline in `n8n-backup` to use NUL-delimited sorting for paths containing spaces.
- Added TLS hardening to the HTTPS Nginx block (`ssl_protocols TLSv1.2 TLSv1.3`, `ssl_prefer_server_ciphers off`, `ssl_session_cache`, `ssl_session_tickets off`).
- Added `--no-eff-email` to the `certbot certonly` call.
- Added `user: "1000:1000"` to `compose.yaml` matching data-directory ownership.
- Replaced `$(seq ...)` loops with native C-style Bash loops (`for ((i=0; i<N; i++))`).
- Upgraded the Let's Encrypt renewal hook to `set -Eeuo pipefail`.
- Added carriage return (`\r`) stripping to backup metadata parsing in `n8n-restore`.

## 0.1.0 - 2026-10-06

- Initial 1 GB RAM Ubuntu 22.04 installer.
- Docker Compose deployment with SQLite persistence.
- 2 GB swap and conservative n8n memory/concurrency defaults.
- Nginx reverse proxy and Let's Encrypt HTTPS.
- Version-aware n8n update command with backup, readiness checks, and automatic rollback.
- Backup, restore, status, logs, restart, version, and uninstall helpers.
