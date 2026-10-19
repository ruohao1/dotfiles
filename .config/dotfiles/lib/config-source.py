#!/usr/bin/env python3
"""Validate a transferred asset against its selected canonical regular source.

Writable state, snapshot, lock and Codex hook policies remain with their owners.
"""
import argparse
import os
from pathlib import Path
import stat
import sys


def valid_source(path, expected, executable=False):
    try:
        expected = Path(expected)
        if not expected.is_absolute() or expected.resolve(strict=True) != expected:
            return False
        info = expected.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid not in {0, os.geteuid()}:
            return False
        if info.st_mode & 0o022:
            return False
        path = Path(path)
        seen = set()
        while path.is_symlink():
            identity = str(path.absolute())
            if identity in seen or len(seen) >= 40:
                return False
            seen.add(identity)
            if path.lstat().st_uid not in {0, os.geteuid()}:
                return False
            target = os.readlink(path)
            path = Path(target) if os.path.isabs(target) else path.parent / target
        if path.resolve(strict=True) != expected:
            return False
        return not executable or bool(info.st_mode & 0o111) and os.access(expected, os.X_OK)
    except (OSError, RuntimeError, ValueError):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--path", required=True)
    parser.add_argument("--expected", required=True)
    parser.add_argument("--executable", action="store_true")
    args = parser.parse_args()
    return 0 if valid_source(args.path, args.expected, args.executable) else 1


if __name__ == "__main__":
    sys.exit(main())
