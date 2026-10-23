#!/usr/bin/env python3
"""Regression checks ensuring installer work is detached from the SSH session."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = (ROOT / "install.sh").read_text().replace('\r\n', '\n')
README = (ROOT / "README.md").read_text().replace('\r\n', '\n')


def require(text, *needles):
    for needle in needles:
        if needle not in text:
            raise AssertionError(f"required persistent-install invariant missing: {needle!r}")


def main():
    require(
        INSTALLER,
        'INSTALLER_UNIT="one-shot-n8n-install.service"',
        'ONE_SHOT_INSTALLER_SERVICE=1',
        'systemd-run --unit="$INSTALLER_UNIT" --collect --property=Type=exec',
        'journalctl -fu %s\\n',
        'View recent logs: sudo journalctl -u %s -n 100 --no-pager',
        'mv -f -- "$tmp" "$BOOTSTRAP_SCRIPT"',
        '/usr/bin/env ONE_SHOT_INSTALLER_SERVICE=1 /bin/bash "$BOOTSTRAP_SCRIPT" "$DOMAIN" "$EMAIL"',
    )

    main_body = INSTALLER[INSTALLER.index("main() {"):]
    launch_index = main_body.index("start_persistent_install")
    guarded_worker_index = main_body.index('if [[ ${ONE_SHOT_INSTALLER_SERVICE:-0} != 1 ]]; then')
    actual_install_index = main_body.index("check_ports")
    if not (guarded_worker_index < launch_index < actual_install_index):
        raise AssertionError("installer must detach before running long installation steps")

    require(
        README,
        "closing SSH will not stop that service",
        "sudo journalctl -fu one-shot-n8n-install.service",
        "sudo journalctl -u one-shot-n8n-install.service -n 100 --no-pager",
    )
    print("PASS: installer runs in a detached systemd service and documents how to inspect logs")


if __name__ == "__main__":
    main()
