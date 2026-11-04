#!/usr/bin/env python3
"""Check the compiled local-cache marker in the exact application being packaged."""
import argparse
from pathlib import Path
import plistlib


MARKER = b"/Users/Shared/AuroraInstallerTestPayloads"


def check(app, expected):
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    executable = info["CFBundleExecutable"]
    if not isinstance(executable, str) or Path(executable).name != executable:
        raise ValueError("unsafe bundle executable")
    binary = app / "Contents/MacOS" / executable
    helpers = app / "Contents/Library/LaunchServices"
    binaries = [binary, *sorted(helpers.iterdir())]
    if len(binaries) != 2 or any(p.is_symlink() or not p.is_file() for p in binaries):
        raise ValueError("expected the app and its regular-file helper")
    present = [MARKER in p.read_bytes() for p in binaries]
    if expected == "disabled" and any(present):
        raise ValueError("release application contains the test-only local payload source")
    if expected == "enabled":
        if not present[0] or info.get("AuroraDeveloperBuild") is not True:
            raise ValueError("test application lacks its compiled local source or developer identity")
        release = app / "Contents/Resources/Release"
        if not all((release / name).is_file() for name in ("catalog.json", "catalog.json.sig")):
            raise ValueError("local payload test application must seal its signed catalog")
    print(f"Compiled local payload source: {expected}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected", choices=("enabled", "disabled"), required=True)
    parser.add_argument("app", type=Path)
    arguments = parser.parse_args()
    check(arguments.app, arguments.expected)
