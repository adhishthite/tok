# Copyright 2026 Adhish Thite
# SPDX-License-Identifier: Apache-2.0

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def swift_string_literals(path):
    """String literals from a Swift file, ignoring // comments."""
    literals = []
    for line in path.read_text().splitlines():
        code = re.sub(r'"(?:\\.|[^"\\])*"', lambda m: m.group(0).replace("//", ""), line)
        code = code.split("//", 1)[0]
        literals += re.findall(r'"((?:\\.|[^"\\])*)"', code)
    return literals


class ShippedTextTests(unittest.TestCase):
    def test_privacy_cap_covers_both_diagnostics_files(self):
        source = (ROOT / "Sources/Store/DiagnosticsFile.swift").read_text()
        match = re.search(r"defaultRollThreshold = (\d+) \* 1024 \* 1024", source)
        self.assertIsNotNone(match, "defaultRollThreshold is no longer a whole number of MB")
        total_mb = 2 * int(match.group(1))
        privacy = (ROOT / "PRIVACY.md").read_text()
        stated = re.search(r"capped at about (\d+) MB in total", privacy)
        self.assertIsNotNone(stated, "PRIVACY.md no longer states the diagnostics cap")
        self.assertGreaterEqual(int(stated.group(1)), total_mb)

    def test_privacy_states_the_crash_report_bounds(self):
        source = (ROOT / "Sources/Store/CrashDiagnostics.swift").read_text()
        files = re.search(r"defaultMaxFiles = (\d+)", source)
        megabytes = re.search(r"defaultMaxBytes = (\d+) \* 1024 \* 1024", source)
        self.assertIsNotNone(files)
        self.assertIsNotNone(megabytes)
        privacy = " ".join((ROOT / "PRIVACY.md").read_text().split())
        self.assertIn(f"at most {files.group(1)} reports and {megabytes.group(1)} MB", privacy)

    def test_no_developer_commands_or_retired_models_in_shipped_strings(self):
        offenders = []
        for path in sorted((ROOT / "Sources").rglob("*.swift")):
            for literal in swift_string_literals(path):
                if "make analyze" in literal or "gemini-3.1-flash-lite" in literal:
                    offenders.append(f"{path.relative_to(ROOT)}: {literal}")
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
