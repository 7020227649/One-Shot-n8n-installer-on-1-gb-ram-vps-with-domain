# Changelog

## 0.2.0 - 2026-10-23

### Fixed
- Added root/sudo check to `n8n-status`, `n8n-restart`, `n8n-logs`, `n8n-version`, and `n8n-uninstall` — these all invoke Docker or read privileged files and must run as root.
- Added explicit `/dev/tty` redirect to the interactive `read` prompts in `n8n-restore` and `n8n-update` so they work correctly when stdin is piped (e.g. `curl … | bash`).
- Added `read -r -p … </dev/tty` to `n8n-uninstall` for the same reason.
- Fixed the backup-rotation pipeline in `n8n-backup`: replaced the `find … -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-` chain (which breaks on paths containing spaces) with a NUL-delimited pipeline using `sort -zrn` and `mapfile -d ''`.
- Added TLS hardening to the HTTPS Nginx block (`ssl_protocols TLSv1.2 TLSv1.3`, `ssl_prefer_server_ciphers off`, `ssl_session_cache`, `ssl_session_tickets off`).
- Added `--no-eff-email` to the `certbot certonly` call to suppress the non-interactive EFF email prompt.
- Added `user: "1000:1000"` to `compose.yaml` so the n8n container process matches the data-directory ownership set by the installer (`chown 1000:1000`).
- Added a Docker `healthcheck` to `compose.yaml` so `docker compose ps` reports container health status.
- Explicitly redirected `wait_ready` curl stderr to `/dev/null` in `install.sh` so transient connection errors during the readiness poll do not print to the terminal.
- Fixed `wait_ready` variable shadowing: changed the loop variable from `_` (implicitly reused) to an explicit named variable `i` to avoid confusion with `set -u`.
- Added the missing `python3 tests/test_release_version_resolution.py` step to the README development checks section.
- Clarified the `certbot.timer` comment: the snap variant of certbot manages its own renewal and does not expose a systemd unit, so `systemctl enable --now certbot.timer || true` already handles both cases — added an explanatory comment.

## 0.1.0 - 2026-10-06

- Initial 1 GB RAM Ubuntu 22.04 installer.
- Docker Compose deployment with SQLite persistence.
- 2 GB swap and conservative n8n memory/concurrency defaults.
- Nginx reverse proxy and Let's Encrypt HTTPS.
- Version-aware n8n update command with backup, readiness checks, and automatic rollback.
- Backup, restore, status, logs, restart, version, and uninstall helpers.
