#!/usr/bin/env python3
"""Guard high-impact lifecycle safety invariants against accidental regressions."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text().replace('\r\n', '\n')


def require(path, *needles):
    body = read(path)
    for needle in needles:
        if needle not in body:
            raise AssertionError(f"{path}: required safety invariant missing: {needle!r}")
    print(f"PASS {path}: {len(needles)} safety invariants")


def forbid(path, *needles):
    body = read(path)
    for needle in needles:
        if needle in body:
            raise AssertionError(f"{path}: forbidden unsafe pattern found: {needle!r}")
    print(f"PASS {path}: {len(needles)} unsafe patterns absent")


require(
    "scripts/n8n-backup",
    'archive_tmp="${archive}.partial.$$"',
    'tar -tzf "$archive_tmp" >/dev/null',
    'chmod 0600 "$archive_tmp" "$env_tmp"',
    'stamp="$(date -u +%Y%m%d-%H%M%S)-${BASHPID}"',
    'if [[ $started == 1 ]]',
    '# Arm cleanup before stopping: a failed stop can still leave the service stopped.\nstarted=1\ndocker compose -f "$STACK_DIR/compose.yaml" stop n8n',
    'mv -- "$env_tmp" "$env_file"\nmv -- "$archive_tmp" "$archive"',
    '[[ $EUID -eq 0 ]]',
)
require(
    "scripts/n8n-update",
    'tar -tzf "$backup_tmp" >/dev/null',
    'cp -- "$backup_env" "$ENV_FILE"',
    'wait_ready 60',
    '# Arm recovery before stopping: a failed stop can still leave the service stopped.\nrestore_old=1\ndocker compose -f "$COMPOSE_FILE" stop n8n',
    'tar -tzf "$failed_state" >/dev/null 2>&1',
    'stamp="$(date -u +%Y%m%d-%H%M%S)-${BASHPID}"',
    'mv -- "$backup_env_tmp" "$backup_env"\nmv -- "$backup_tmp" "$backup"',
    '[[ $EUID -eq 0 ]]',
    'read -r -p "Continue with backup + update? [y/N] " answer </dev/tty',
)
require(
    "scripts/n8n-restore",
    "MAX_ARCHIVE_BYTES = 5 * 1024**3",
    "MAX_UNPACKED_BYTES = 5 * 1024**3",
    "MAX_MEMBERS = 100_000",
    'tar -tzf "$safety_backup_tmp" >/dev/null',
    'stamp="$(date -u +%Y%m%d-%H%M%S)-${BASHPID}"',
    'curl -fsS --max-time 5 http://127.0.0.1:5678/healthz/readiness',
    '[[ $EUID -eq 0 ]]',
    'read -r -p "Type RESTORE to continue: " answer </dev/tty',
)
forbid(
    "scripts/n8n-restore",
    'source "$backup_env"',
    'tar -C "$DATA_DIR" -xzf "$archive"',
)
require(
    "scripts/n8n-status",
    '[[ $EUID -eq 0 ]]',
)
require(
    "scripts/n8n-restart",
    '[[ $EUID -eq 0 ]]',
)
require(
    "scripts/n8n-logs",
    '[[ $EUID -eq 0 ]]',
)
require(
    "scripts/n8n-version",
    '[[ $EUID -eq 0 ]]',
)
require(
    "scripts/n8n-uninstall",
    '[[ $EUID -eq 0 ]]',
    'read -r -p "Type REMOVE to continue: " answer </dev/tty',
)
require(
    "install.sh",
    'tmp="$(mktemp "${STACK_DIR}/compose.yaml.XXXXXX")"',
    'mv -f -- "$tmp" "$COMPOSE_FILE"',
    'swap_path=/swapfile.one-shot-n8n',
    'Refusing to overwrite an unknown file',
    'port_listeners_are_only_nginx "$port"',
    'grep -Fq "server_name $DOMAIN;" "$NGINX_CONF"',
    'ssl_protocols TLSv1.2 TLSv1.3',
    '--no-eff-email',
)
forbid("install.sh", "rm -f /swapfile")

require(
    "compose.yaml",
    'user: "1000:1000"',
    'healthcheck:',
    'N8N_DEFAULT_BINARY_DATA_MODE: filesystem',
)

# Exercise the actual listener-owner predicate with representative ss output.
# This catches active Nginx masking an unrelated service on the other port.
import os
import subprocess
import tempfile


def test_port_listener_ownership():
    installer = read("install.sh")
    start = installer.index("port_listeners_are_only_nginx() {")
    end = installer.index("\ncheck_ports() {", start)
    function = installer[start:end]

    with tempfile.TemporaryDirectory() as temp_dir:
        stub = Path(temp_dir) / "ss"
        stub.write_text('#!/usr/bin/env bash\nprintf "%s\n" "$SS_OUTPUT"\n')
        stub.chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = f"{temp_dir}:{env['PATH']}"

        cases = [
            ('LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=12,fd=6))', True),
            ('LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=12,fd=6))\nLISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:(("other",pid=99,fd=3))', False),
            ('LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:(("other",pid=99,fd=3))', False),
            ('', False),
        ]
        for output, expected in cases:
            env["SS_OUTPUT"] = output
            result = subprocess.run(
                ["bash", "-c", function + "\nport_listeners_are_only_nginx 443"],
                env=env,
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            actual = result.returncode == 0
            if actual != expected:
                raise AssertionError(
                    f"listener ownership mismatch for {output!r}: expected {expected}, got {actual}"
                )
    print("PASS install.sh: listener-owner predicate accepts only verified Nginx listeners")


test_port_listener_ownership()

print("All lifecycle safety guards passed.")
