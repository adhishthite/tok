#!/usr/bin/env python3
# Copyright 2026 Adhish Thite
# SPDX-License-Identifier: Apache-2.0

"""Check or add the Apache-2.0 header on tracked Swift, Python, and shell files."""

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COPYRIGHT = "Copyright 2026 Adhish Thite"
SPDX = "SPDX-License-Identifier: Apache-2.0"
COMMENT_PREFIX = {".swift": "// ", ".py": "# ", ".sh": "# "}


def header_lines(suffix):
    prefix = COMMENT_PREFIX[suffix]
    return [prefix + COPYRIGHT, prefix + SPDX]


def split_shebang(text):
    if text.startswith("#!"):
        first, _, rest = text.partition("\n")
        return first + "\n", rest
    return "", text


def has_header(text, suffix):
    _, body = split_shebang(text)
    return body.splitlines()[:2] == header_lines(suffix)


def with_header(text, suffix):
    if has_header(text, suffix):
        return text
    shebang, body = split_shebang(text)
    return shebang + "\n".join(header_lines(suffix)) + "\n\n" + body.lstrip("\n")


def tracked_files():
    patterns = [f"*{suffix}" for suffix in COMMENT_PREFIX]
    output = subprocess.run(
        ["git", "ls-files", "--", *patterns],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=10,
        check=True,
    ).stdout
    return [ROOT / line for line in output.splitlines()]


def main(arguments):
    write = arguments == ["--write"]
    if arguments not in ([], ["--check"], ["--write"]):
        print("Usage: license_headers.py [--check | --write]", file=sys.stderr)
        return 2
    missing = []
    for path in tracked_files():
        text = path.read_text(encoding="utf-8")
        if has_header(text, path.suffix):
            continue
        if write:
            path.write_text(with_header(text, path.suffix), encoding="utf-8")
        missing.append(path.relative_to(ROOT))
    if write:
        print(f"Added license headers to {len(missing)} files.")
        return 0
    for path in missing:
        print(f"Missing license header: {path}", file=sys.stderr)
    if missing:
        print("Run: python3 Scripts/license_headers.py --write", file=sys.stderr)
        return 1
    print("PASS: every tracked source file has the license header.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
