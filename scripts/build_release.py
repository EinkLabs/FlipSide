#!/usr/bin/env python3
"""Package only flipside.koplugin; never include tests or GitHub automation."""
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "flipside.koplugin"
DEST = ROOT / "dist" / "FlipSide-1.0.0-rc.1.zip"
DISALLOWED_SUFFIXES = (".sqlite", ".sqlite3", ".db", ".db-wal", ".db-shm", ".old")


def main():
    if not (PLUGIN / "main.lua").is_file():
        sys.exit("Expected flipside.koplugin/main.lua at repository root")
    members = sorted(p for p in PLUGIN.rglob("*") if p.is_file())
    if not members:
        sys.exit("No plugin files found")
    for path in members:
        if path.is_symlink():
            sys.exit("Refusing symlink in plugin: " + str(path))
        relative = path.relative_to(PLUGIN)
        if any(s in {"settings", "cache", "tests", ".git"} for s in relative.parts):
            sys.exit("Refusing private/runtime folder: " + str(path))
        if path.name.endswith(DISALLOWED_SUFFIXES):
            sys.exit("Refusing potentially private user data: " + str(path))
    DEST.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(DEST, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in members:
            archive.write(path, arcname=path.relative_to(ROOT).as_posix())
    with zipfile.ZipFile(DEST) as archive:
        if archive.testzip() is not None:
            sys.exit("Release ZIP failed CRC check")
    print(f"Built {DEST.relative_to(ROOT)} with {len(members)} plugin files only")


if __name__ == "__main__":
    main()
