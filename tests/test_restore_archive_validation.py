#!/usr/bin/env python3
"""Exercise the actual archive-validation block embedded in n8n-restore."""
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
restore_script = (ROOT / "scripts/n8n-restore").read_text()
match = re.search(
    r"python3 - \"\$archive\" <<'PY_VALIDATE'[^\n]*\n(.*?)\nPY_VALIDATE",
    restore_script,
    re.DOTALL,
)
if not match:
    raise SystemExit("Could not locate the restore archive validator")
validator = match.group(1)

def make_archive(path, entries):
    with tarfile.open(path, "w:gz") as tf:
        for name, kind, data in entries:
            info = tarfile.TarInfo(name)
            if kind == "file":
                payload = data
                info.size = len(payload)
                import io
                tf.addfile(info, io.BytesIO(payload))
            elif kind == "dir":
                info.type = tarfile.DIRTYPE
                tf.addfile(info)
            elif kind == "symlink":
                info.type = tarfile.SYMTYPE
                info.linkname = data
                tf.addfile(info)
            elif kind == "hardlink":
                info.type = tarfile.LNKTYPE
                info.linkname = data
                tf.addfile(info)
            elif kind == "fifo":
                info.type = tarfile.FIFOTYPE
                tf.addfile(info)

def check(label, entries, expected_ok):
    archive = temp / (label + ".tar.gz")
    make_archive(archive, entries)
    result = subprocess.run(
        [sys.executable, "-c", validator, str(archive)],
        text=True, capture_output=True,
    )
    ok = result.returncode == 0
    if ok != expected_ok:
        raise AssertionError(
            f"{label}: expected accepted={expected_ok}, got accepted={ok}; "
            f"stdout={result.stdout!r}, stderr={result.stderr!r}"
        )
    print(f"PASS {label}")

with tempfile.TemporaryDirectory() as directory:
    temp = pathlib.Path(directory)
    check("valid-backup", [("./", "dir", b""), ("./database.sqlite", "file", b"sqlite")], True)
    check("valid-root-path", [("database.sqlite", "file", b"sqlite")], True)
    check("missing-database", [("./config", "file", b"config")], False)
    check("path-traversal", [("./database.sqlite", "file", b"sqlite"), ("../escape", "file", b"bad")], False)
    check("absolute-path", [("/tmp/escape", "file", b"bad"), ("database.sqlite", "file", b"sqlite")], False)
    check("symbolic-link", [("database.sqlite", "file", b"sqlite"), ("link", "symlink", "database.sqlite")], False)
    check("hard-link", [("database.sqlite", "file", b"sqlite"), ("link", "hardlink", "database.sqlite")], False)
    check("special-file", [("database.sqlite", "file", b"sqlite"), ("pipe", "fifo", b"")], False)
    check("database-as-directory", [("database.sqlite", "dir", b"")], False)
    check("duplicate-path", [("database.sqlite", "file", b"one"), ("./database.sqlite", "file", b"two")], False)
    broken = temp / "truncated.tar.gz"
    broken.write_bytes(b"not a tar archive")
    result = subprocess.run([sys.executable, "-c", validator, str(broken)], text=True, capture_output=True)
    if result.returncode == 0:
        raise AssertionError("truncated archive was unexpectedly accepted")
    print("PASS truncated-archive")
