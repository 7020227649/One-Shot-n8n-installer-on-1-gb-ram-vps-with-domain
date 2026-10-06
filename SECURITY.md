# Security

Please do not report security vulnerabilities in public issues.

The installer is designed for a fresh VPS and follows a few security-oriented defaults:

- n8n listens on `127.0.0.1:5678`, not on the public interface.
- Public HTTP traffic is redirected to HTTPS.
- Let's Encrypt certificates are renewed through Certbot's timer.
- n8n state is stored on the host so container replacement does not delete it.
- `.env` and backup files are written with restrictive permissions.
- Update operations create a pre-update backup before container recreation.

The project does not manage cloud-provider firewall rules. Ensure TCP 80/443 are allowed only as required by your setup, and keep SSH restricted to trusted sources.
