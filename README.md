# One-Shot n8n Installer — 1 GB RAM VPS

A one-command installer for a **fresh Ubuntu 22.04 VPS with about 1 GiB RAM**, a domain, and root/sudo access. It installs n8n with SQLite, Docker Compose, Nginx, Let's Encrypt HTTPS, persistent storage, 2 GB swap, and low-memory defaults.

## What it installs

```text
Internet
   │
 HTTPS :443
   │
 Nginx
   │
 127.0.0.1:5678
   │
 n8n Docker container
   │
 SQLite + /home/node/.n8n
```

The n8n port is bound to localhost; Nginx is the public entry point. Redis, PostgreSQL, queue mode, workers, and other optional services are intentionally not installed because this project targets a 1 GB VPS.

## Requirements

- Fresh Ubuntu **22.04** VPS
- About **1 GB RAM** (the installer refuses machines below 768 MiB)
- amd64 or arm64
- Root or sudo access
- A DNS A/AAAA record already pointing the domain to the VPS
- TCP ports 80 and 443 available
- Outbound internet access

## Install

The easiest method is **one command**. You do not need to edit the command or understand Bash arguments.

```bash
curl -fsSL https://raw.githubusercontent.com/7020227649/One-Shot-n8n-installer-on-1-gb-ram-vps-with-domain/main/install.sh | sudo bash
```

The installer will ask you:

```text
Domain (example: n8n.example.com):
Email  (example: you@example.com):
```

Enter the domain/subdomain that already points to your VPS and an email address for Let's Encrypt. The installer then performs the setup automatically.

For scripts or automation, you can also provide the two values directly:

```bash
curl -fsSL https://raw.githubusercontent.com/7020227649/One-Shot-n8n-installer-on-1-gb-ram-vps-with-domain/main/install.sh | sudo bash -s -- "n8n.example.com" "you@example.com"
```

The installer resolves the current stable n8n release from the n8n GitHub releases API and stores the selected version in `/opt/one-shot-n8n/.env`. Re-running the installer for the same domain preserves the existing version/configuration instead of silently downgrading it.

> **Before installing:** your DNS A/AAAA record must already point to this VPS, and the VPS/cloud firewall must allow inbound TCP **80** and **443** for Let's Encrypt and HTTPS.

## 1 GB tuning

The default profile is intentionally stability-first:

| Setting | Default |
| --- | ---: |
| Host swap | 2 GB |
| n8n Node.js heap | 384 MB |
| n8n container RAM limit | 700 MB |
| n8n container memory+swap | 900 MB |
| Production concurrency | 1 |
| Successful execution retention | Disabled |
| Failed execution retention | Enabled |
| Execution pruning | Enabled |
| Execution max age | 7 days |
| Execution max count | 2,000 |

Heavy workflows can still exceed a 1 GB VPS. Large binaries, huge JSON payloads, Code nodes, and many concurrent executions need more memory.

## Updating n8n

Updating is a first-class feature of this project:

```bash
sudo n8n-update
```

Or specify an exact stable version:

```bash
sudo n8n-update 2.41.7
```

The updater:

1. Resolves/validates the target version.
2. Pulls the new Docker image **before stopping the current n8n**, minimizing downtime.
3. Stops n8n for a consistent SQLite backup.
4. Saves the current data and `.env` to `/var/backups/one-shot-n8n/`.
5. Recreates the n8n container with the target version.
6. Waits for `/healthz/readiness`, including database migrations.
7. On failed readiness, captures the failed state and automatically restores the pre-update backup and old version.
8. Removes the previous Docker image after a successful update to avoid filling a small VPS disk.

A failed update may discard changes made by the failed version between startup and rollback; the failed-state archive is retained for investigation.

## Backups and restore

Create a consistent backup:

```bash
sudo n8n-backup
```

Restore a backup:

```bash
sudo n8n-restore /var/backups/one-shot-n8n/<backup>.tar.gz
```

The restore command requires typing `RESTORE` because it replaces the current n8n data directory.

## Useful commands

```bash
sudo n8n-status
sudo n8n-version
sudo n8n-logs
sudo n8n-restart
sudo n8n-backup
sudo n8n-update
sudo n8n-restore <backup.tar.gz>
sudo n8n-uninstall
```

`n8n-uninstall` removes the container, Compose stack, Nginx configuration, and helper commands while preserving `/var/lib/one-shot-n8n` and `/var/backups/one-shot-n8n`.

## Files on the VPS

```text
/opt/one-shot-n8n/
├── .env
├── compose.yaml
└── bin/
    ├── n8n-backup
    ├── n8n-logs
    ├── n8n-restart
    ├── n8n-restore
    ├── n8n-status
    ├── n8n-uninstall
    ├── n8n-update
    └── n8n-version

/var/lib/one-shot-n8n/       # persistent n8n data
/var/backups/one-shot-n8n/  # backups
```

## Notes

This project intentionally targets the smallest practical n8n deployment. It does not promise that every n8n workflow will fit in 1 GB RAM. For sustained high concurrency, large data processing, or production-critical workloads, use a larger VPS and consider PostgreSQL/queue-based architecture.

The installer currently targets Ubuntu 22.04 only. It is designed for a **fresh** server and deliberately stops when ports 80/443 are already occupied.

## License

See [LICENSE](LICENSE).
