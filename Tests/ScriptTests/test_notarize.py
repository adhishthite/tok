import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "notarize", Path(__file__).resolve().parents[2] / "Scripts/notarize.py"
)
notary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notary)
JOB_ID = "e25a358e-a9ec-49cb-a8c6-44d65811dcab"


class NotarizationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.archive = self.root / "Tok.zip"
        self.archive.write_bytes(b"first signed archive")
        self.state = self.root / "jobs"

    def run_job(self, submission=None):
        return notary.notarize(self.archive, self.state, "test-profile", submission)

    def test_pending_job_resumes_without_second_upload(self):
        with patch.object(
            notary,
            "call_notary",
            side_effect=[
                {"id": JOB_ID},
                {"status": "In Progress"},
                {"status": "Accepted"},
            ],
        ) as call:
            self.assertEqual(self.run_job(), 75)
            self.assertEqual(self.run_job(), 0)
        self.assertEqual(
            [entry.args[0][0] for entry in call.call_args_list],
            ["submit", "info", "info"],
        )

    def test_ambiguous_upload_requires_explicit_recovery(self):
        with patch.object(
            notary, "call_notary", side_effect=RuntimeError("timeout")
        ) as call:
            with self.assertRaisesRegex(RuntimeError, "timeout"):
                self.run_job()
            with self.assertRaisesRegex(RuntimeError, "No archive was resubmitted"):
                self.run_job()
            self.assertEqual(call.call_count, 1)
        with patch.object(
            notary, "call_notary", return_value={"status": "Accepted"}
        ) as call:
            self.assertEqual(self.run_job(JOB_ID), 0)
            self.assertEqual(call.call_args.args[0], ["info", JOB_ID])

    def test_rebuilt_archive_does_not_reuse_accepted_job(self):
        with patch.object(
            notary,
            "call_notary",
            side_effect=[
                {"id": JOB_ID},
                {"status": "Accepted"},
                {"id": JOB_ID},
                {"status": "In Progress"},
            ],
        ) as call:
            self.assertEqual(self.run_job(), 0)
            self.archive.write_bytes(b"different signed archive")
            self.assertEqual(self.run_job(), 75)
        self.assertEqual(
            [entry.args[0][0] for entry in call.call_args_list],
            ["submit", "info", "submit", "info"],
        )

    def test_rejected_archive_is_not_reuploaded(self):
        with patch.object(
            notary,
            "call_notary",
            side_effect=[{"id": JOB_ID}, {"status": "Invalid"}, {"status": "Invalid"}],
        ) as call:
            for _ in range(2):
                with self.assertRaisesRegex(RuntimeError, "not accepted"):
                    self.run_job()
        self.assertEqual(
            [entry.args[0][0] for entry in call.call_args_list],
            ["submit", "info", "info"],
        )
