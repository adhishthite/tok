# Copyright 2026 Adhish Thite
# SPDX-License-Identifier: Apache-2.0

import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "license_headers",
    Path(__file__).resolve().parents[2] / "Scripts/license_headers.py",
)
license_headers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(license_headers)

SWIFT_HEADER = (
    "// Copyright 2026 Adhish Thite\n// SPDX-License-Identifier: Apache-2.0\n\n"
)
HASH_HEADER = "# Copyright 2026 Adhish Thite\n# SPDX-License-Identifier: Apache-2.0\n\n"


class LicenseHeaderTests(unittest.TestCase):
    def test_swift_header_precedes_imports(self):
        result = license_headers.with_header("import Foundation\n", ".swift")
        self.assertEqual(result, SWIFT_HEADER + "import Foundation\n")

    def test_header_follows_shebang(self):
        source = '#!/usr/bin/env python3\n"""Doc."""\n'
        result = license_headers.with_header(source, ".py")
        self.assertEqual(
            result, '#!/usr/bin/env python3\n' + HASH_HEADER + '"""Doc."""\n'
        )
        self.assertTrue(license_headers.has_header(result, ".py"))

    def test_adding_twice_is_unchanged(self):
        once = license_headers.with_header("#!/bin/bash\nset -e\n", ".sh")
        self.assertEqual(license_headers.with_header(once, ".sh"), once)

    def test_wrong_comment_style_is_missing(self):
        self.assertFalse(license_headers.has_header(HASH_HEADER, ".swift"))


if __name__ == "__main__":
    unittest.main()
