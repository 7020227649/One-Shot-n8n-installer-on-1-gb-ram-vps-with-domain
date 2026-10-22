#!/usr/bin/env python3
"""Regression test for GitHub release channel aliases vs numeric n8n versions."""
import re

SAMPLE_RELEASES = [
    {"tag_name": "stable", "draft": False, "prerelease": False},
    {"tag_name": "n8n@2.44.5", "draft": False, "prerelease": False},
    {"tag_name": "n8n@2.45.1", "draft": False, "prerelease": True},
    {"tag_name": "n8n@2.44.4", "draft": False, "prerelease": False},
    {"tag_name": "beta", "draft": False, "prerelease": True},
]


def resolve(releases):
    for release in releases:
        tag = release.get("tag_name", "")
        match = re.fullmatch(r"(?:n8n@)?v?(\d+\.\d+\.\d+)", tag)
        if not release.get("draft") and not release.get("prerelease") and match:
            return match.group(1)
    raise ValueError("No semantic-version stable n8n release found")


assert resolve(SAMPLE_RELEASES) == "2.44.5"
assert resolve([{"tag_name": "v1.2.3", "draft": False, "prerelease": False}]) == "1.2.3"
try:
    resolve([{"tag_name": "stable", "draft": False, "prerelease": False}])
except ValueError:
    pass
else:
    raise AssertionError("Channel aliases must not be accepted as numeric versions")

print("PASS: stable/beta aliases are skipped and numeric stable versions are resolved")
