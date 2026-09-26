# Copyright 2026 Adhish Thite
# SPDX-License-Identifier: Apache-2.0

import importlib.util
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "update_check", Path(__file__).resolve().parents[2] / "Scripts/check_updates.py"
)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class UpdateCheckTests(unittest.TestCase):
    def test_authentication_failure_is_not_counted_as_tamper_rejection(self):
        result = subprocess.CompletedProcess([], 1, stdout="Keychain access denied")
        with (
            patch.object(check.subprocess, "run", return_value=result),
            self.assertRaisesRegex(RuntimeError, "not a signature rejection"),
        ):
            check.run(["tool"], "Tamper check", expected_success=False)

    def test_cryptographic_rejection_is_accepted(self):
        result = subprocess.CompletedProcess(
            [], 1, stdout="Error: failed to pass signing verification."
        )
        with patch.object(check.subprocess, "run", return_value=result):
            check.run(["tool"], "Tamper check", expected_success=False)

    def test_timeout_is_reported_without_command_arguments(self):
        with (
            patch.object(
                check.subprocess,
                "run",
                side_effect=subprocess.TimeoutExpired(["tool"], 30),
            ),
            self.assertRaisesRegex(RuntimeError, "exceeded 30 seconds and was stopped"),
        ):
            check.run(["tool"], "Signing")
