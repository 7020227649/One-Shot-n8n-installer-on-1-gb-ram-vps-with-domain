#!/usr/bin/env python3
"""Regression tests for resuming a partially completed interactive installation."""
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = (ROOT / "install.sh").read_text().replace('\r\n', '\n')


def extract_function(source, name, next_name):
    start = source.index(f"{name}() {{")
    end = source.index(f"\n{next_name}() {{", start)
    return source[start:end]


def run_validate(env_file, args=()):
    function = extract_function(INSTALLER, "validate_args", "port_listeners_are_only_nginx")
    script = "\n".join(
        [
            f"ENV_FILE={shlex.quote(str(env_file))}",
            'log() { :; }',
            'die() { echo "$*" >&2; exit 1; }',
            "prompt_for_details() { echo 'unexpected interactive prompt' >&2; exit 91; }",
            function,
            "validate_args " + " ".join(shlex.quote(arg) for arg in args),
            'printf "DOMAIN=%s\nEMAIL=%s\n" "$DOMAIN" "$EMAIL"',
        ]
    )
    return subprocess.run(["bash", "-c", script], text=True, capture_output=True, check=False)


def main():
    with tempfile.TemporaryDirectory() as temporary:
        env_file = Path(temporary) / ".env"
        env_file.write_text(
            "N8N_VERSION=2.44.5\n"
            "N8N_DOMAIN=n8n.example.com\n"
            "N8N_EMAIL=setup@example.com\n"
        )

        resumed = run_validate(env_file)
        if resumed.returncode != 0:
            raise AssertionError(f"Resume failed: {resumed.stderr}")
        if "DOMAIN=n8n.example.com" not in resumed.stdout or "EMAIL=setup@example.com" not in resumed.stdout:
            raise AssertionError(f"Saved values were not reused: {resumed.stdout!r}")

        explicit = run_validate(env_file, ("another.example.com", "owner@example.org"))
        if explicit.returncode != 0:
            raise AssertionError(f"Explicit arguments failed: {explicit.stderr}")
        if "DOMAIN=another.example.com" not in explicit.stdout or "EMAIL=owner@example.org" not in explicit.stdout:
            raise AssertionError(f"Explicit arguments were not respected: {explicit.stdout!r}")

    print("PASS: interrupted installs reuse saved configuration without prompting")
    print("PASS: explicit domain and email arguments remain supported")


if __name__ == "__main__":
    main()
