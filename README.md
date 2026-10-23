# One-Shot n8n Installer — 1 GB RAM VPS

A production-ready, one-command installer for a **fresh Ubuntu 22.04 VPS with about 1 GiB RAM**, a domain, and root/sudo access. It automatically provisions Docker Compose, n8n with SQLite persistence, Nginx reverse proxy, Let's Encrypt SSL/TLS, 2 GB swap safety net, and stability-first low-memory defaults.

## What it installs

```text
Internet
   │
 HTTPS :443 (Let's Encrypt SSL/TLS)
   │
 Nginx Reverse Proxy
   │
 127.0.0.1:5678 (Localhost only)
   │
 n8n Docker Container (Node.js heap: 384 MB, Container RAM: 700 MB)
   │
 SQLite (/var/lib/one-shot-n8n) + Binary Files (/home/node/.n8n/binaryData)
```

The n8n port is bound strictly to `127.0.0.1`; Nginx is the public entry point. Heavy external dependencies like PostgreSQL and Redis are intentionally excluded to ensure maximum stability and reliability within 1 GB RAM.

---

## Prerequisites

Before running the installer:

1. **Ubuntu 22.04 VPS**: Fresh installation on `amd64` or `arm64` architecture with at least 768 MiB RAM.
2. **DNS Record Set Up**: Create a DNS **A record** (or AAAA for IPv6) pointing your subdomain (e.g., `n8n.yourdomain.com`) to your VPS public IP.
3. **Firewall / Ports Open**: Ensure inbound TCP ports **80** (HTTP) and **443** (HTTPS) are allowed on your cloud provider's firewall / security group (e.g., AWS Security Group, Hetzner Firewall, DigitalOcean Cloud Firewall, Oracle Cloud Security List).
4. **Root or Sudo Access**: Log in as `root` or a user with `sudo` privileges.

---

## Quick Start & Usage Instructions

### Method 1: Interactive (Easiest — 1-Command)

SSH into your VPS and run this single command:

```bash
curl -fsSL https://raw.githubusercontent.com/7020227649/One-Shot-n8n-installer-on-1-gb-ram-vps-with-domain/main/install.sh | sudo bash
```

The installer will prompt you for your details:

```text
One-Shot n8n Installer
Enter the domain that already points to this VPS and an email for Let's Encrypt.

Domain (example: n8n.example.com): n8n.yourdomain.com
Email  (example: you@example.com): you@yourdomain.com
```

### Method 2: Non-Interactive (Automated Single Line)

For headless setups, cloud-init scripts, or automated provisioning, supply your domain and email directly as arguments in one line:

```bash
curl -fsSL https://raw.githubusercontent.com/7020227649/One-Shot-n8n-installer-on-1-gb-ram-vps-with-domain/main/install.sh | sudo bash -s -- "n8n.yourdomain.com" "you@example.com"
```

Replace `n8n.yourdomain.com` with your actual domain and `you@example.com` with your email address for Let's Encrypt certificate renewal notices.

---

## How It Works

1. **Detached Background Execution**: The installer launches the actual setup as a detached systemd background service (`one-shot-n8n-install.service`) and immediately returns to your shell; closing SSH will not stop that service.
2. **Safe Idempotent Resumption**: If an installation was previously interrupted or if you reconnect via SSH, re-running the command automatically reads your saved configuration from `/opt/one-shot-n8n/.env` and resumes without asking for domain/email again.
3. **Port Verification**: Verifies TCP ports 80/443. If this installation's own Nginx is already listening, it permits safe re-runs while blocking unknown third-party services.
4. **Swap Safety Net**: Allocates a 2 GB swapfile if total swap is below 1 GB, and configures kernel swappiness (`vm.swappiness=10`) to prioritize physical RAM.
5. **Secure Reverse Proxy & Auto-Renewal**: Sets up Nginx with WebSocket reverse proxying and requests an official Let's Encrypt certificate with auto-renewal timers and deploy reload hooks.

---

## Monitoring & Inspecting Installation

To follow live installation progress:

```bash
sudo journalctl -fu one-shot-n8n-install.service
```

To inspect the most recent 100 log lines without following continuously:

```bash
sudo journalctl -u one-shot-n8n-install.service -n 100 --no-pager
```

Once installation finishes, open your browser and navigate to:
```text
https://n8n.yourdomain.com
```

---

## 1 GB RAM Stability Tuning

The deployment is pre-configured with memory-conservative settings designed specifically to prevent Out-Of-Memory (OOM) crashes:

| Setting | Value | Rationale |
|:---|---:|:---|
| **Host swap** | 2 GB | Safety buffer against sudden memory spikes |
| **Node.js max heap** | 384 MB | Constrains V8 garbage collection within limits |
| **Container RAM limit** | 700 MB | Hard cgroup memory threshold |
| **Container memory + swap** | 900 MB | Maximum combined memory threshold |
| **Production concurrency** | 1 | Eliminates concurrency-related memory bursts |
| **Binary data storage** | Filesystem | Offloads attachments to disk instead of SQLite / RAM |
| **Successful execution history** | Disabled | Keeps SQLite database lightweight and responsive |
| **Failed execution history** | Enabled | Preserves error logs for debugging workflows |
| **Execution data pruning** | Enabled | Automatically deletes old execution logs |
| **Max execution age** | 7 days (168h) | Prevents unbounded SQLite growth |
| **Max execution count** | 2,000 | Caps database execution records |

---

## Management Commands

The installer places convenient management commands in `/usr/local/bin`:

### Check Status & Health
```bash
sudo n8n-status
```
Displays running containers, healthcheck readiness, host memory usage (`free -h`), and live Docker memory stats.

### View Logs
```bash
sudo n8n-logs
```
Streams live container logs (`docker compose logs -f --tail=200 n8n`).

### Restart n8n
```bash
sudo n8n-restart
```

### Check Installed Version
```bash
sudo n8n-version
```

### Updating n8n
Update to the latest stable release with zero downtime image pre-pulling, automatic pre-update backup, and migration rollback:

```bash
sudo n8n-update
```

Or update to a specific version:

```bash
sudo n8n-update 2.44.5
```

The update process:
1. Pulls the new Docker image **before** stopping the existing container.
2. Creates and verifies an atomic SQLite backup in `/var/backups/one-shot-n8n/`.
3. Starts the new version and polls `/healthz/readiness`.
4. If migrations or startup fail, automatically rolls back to the previous data and configuration.

### Creating Backups
```bash
sudo n8n-backup
```
Creates an atomic, consistent archive in `/var/backups/one-shot-n8n/` alongside a `.env` configuration sidecar. Automatically retains the 5 newest routine backups.

### Restoring from Backup
```bash
sudo n8n-restore /var/backups/one-shot-n8n/n8n-2.44.5-<timestamp>.tar.gz
```
Validates archive integrity against path traversal and symlink exploits, creates a safety backup of current data, restores SQLite database and version, and confirms readiness with automatic rollback on failure.

### Uninstalling
```bash
sudo n8n-uninstall
```
Gracefully tears down the container, Compose files, Nginx configuration, and helper symlinks, while **preserving** your workflow data (`/var/lib/one-shot-n8n`) and backups (`/var/backups/one-shot-n8n`).

---

## File Locations

```text
/opt/one-shot-n8n/
├── .env                  # Configuration variables & version tag
├── compose.yaml          # Docker Compose stack definition
└── bin/                  # Helper script binaries
    ├── n8n-backup
    ├── n8n-logs
    ├── n8n-restart
    ├── n8n-restore
    ├── n8n-status
    ├── n8n-uninstall
    ├── n8n-update
    └── n8n-version

/var/lib/one-shot-n8n/     # Persistent n8n data & SQLite database
/var/backups/one-shot-n8n/ # Automated backups & rollback snapshots
/etc/nginx/conf.d/one-shot-n8n.conf # Nginx reverse proxy configuration
```

---

## Development Checks

The GitHub Actions workflow runs on Ubuntu 22.04 and verifies shell syntax, ShellCheck, regression invariants, and archive security:

```bash
bash -n install.sh scripts/*
shellcheck install.sh scripts/*
python3 tests/test_installer_persistent_execution.py
python3 tests/test_installer_resume.py
python3 tests/test_release_version_resolution.py
python3 tests/test_restore_archive_validation.py
python3 tests/test_lifecycle_safety.py
```

---

## License

See [LICENSE](LICENSE).
