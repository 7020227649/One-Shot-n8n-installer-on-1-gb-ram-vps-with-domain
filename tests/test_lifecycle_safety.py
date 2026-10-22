#!/usr/bin/env python3
"""Guard high-impact lifecycle safety invariants against accidental regressions."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


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
    'started=1\ndocker compose -f "$STACK_DIR/compose.yaml" stop n8n',
    'mv -- "$env_tmp" "$env_file"\nmv -- "$archive_tmp" "$archive"',
)
require(
    "scripts/n8n-update",
    'tar -tzf "$backup_tmp" >/dev/null',
    'cp -- "$backup_env" "$ENV_FILE"',
    'wait_ready 60',
    'restore_old=1\ndocker compose -f "$COMPOSE_FILE" stop n8n',
    'tar -tzf "$failed_state" >/dev/null 2>&1',
    'stamp="$(date -u +%Y%m%d-%H%M%S)-${BASHPID}"',
    'mv -- "$backup_env_tmp" "$backup_env"\nmv -- "$backup_tmp" "$backup"',
)
require(
    "scripts/n8n-restore",
    "MAX_ARCHIVE_BYTES = 5 * 1024**3",
    "MAX_UNPACKED_BYTES = 5 * 1024**3",
    "MAX_MEMBERS = 100_000",
    'tar -tzf "$safety_backup_tmp" >/dev/null',
    'stamp="$(date -u +%Y%m%d-%H%M%S)-${BASHPID}"',
    'curl -fsS --max-time 5 http://127.0.0.1:5678/healthz/readiness',
)
forbid(
    "scripts/n8n-restore",
    'source "$backup_env"',
    "tar -C \"$DATA_DIR\" -xzf \"$archive\"",
)
require(
    "install.sh",
    'tmp="$(mktemp "${STACK_DIR}/compose.yaml.XXXXXX")"',
    'mv -f -- "$tmp" "$COMPOSE_FILE"',
    'swap_path=/swapfile.one-shot-n8n',
    'Refusing to overwrite an unknown file',
)
forbid("install.sh", "rm -f /swapfile")
print("All lifecycle safety guards passed.")
