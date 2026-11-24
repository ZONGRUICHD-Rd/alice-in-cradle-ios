#!/usr/bin/env python3
"""Verify that the repository strictly excludes copyrighted game assets, binaries, and signing material."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent

FORBIDDEN_EXTS = {
    ".ipa", ".dylib", ".dll", ".exe", ".assets", ".resource", ".ress",
    ".unity3d", ".p12", ".mobileprovision", ".cer", ".pkg",
}
SKIP_DIRS = {".git", "build", "dist", "work", "out", "__pycache__", ".venv"}


def main() -> None:
    violations: list[str] = []
    for p in ROOT.rglob("*"):
        if any(part in SKIP_DIRS for part in p.parts):
            continue
        if p.is_file() and p.suffix.lower() in FORBIDDEN_EXTS:
            violations.append(str(p.relative_to(ROOT)))
    if violations:
        print("COPYRIGHT / PUBLIC REPO AUDIT FAILED! Forbidden files detected:", file=sys.stderr)
        for v in violations:
            print(f"  - {v}", file=sys.stderr)
        raise SystemExit(1)
    print("Audit passed: zero copyrighted game files, binaries, or signing assets in repository.")


if __name__ == "__main__":
    main()
