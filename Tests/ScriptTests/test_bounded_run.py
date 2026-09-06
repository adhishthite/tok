import contextlib
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class BoundedRunTests(unittest.TestCase):
    def setUp(self):
        probe = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(0.1)"],
            start_new_session=True,
        )
        try:
            try:
                os.killpg(probe.pid, 0)
            except PermissionError:
                self.skipTest(
                    "Sandbox denies process-group signals; requires an unrestricted runner"
                )
        finally:
            probe.wait(timeout=2)

    def check_descendant_cleanup(self, interrupt):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready = root / "ready.json"
            child = root / "child.py"
            child.write_text(
                "import os, signal, sys, time\n"
                "signal.signal(signal.SIGINT, signal.SIG_IGN)\n"
                "open(sys.argv[1], 'w').write(str(os.getpid()))\n"
                "end = time.monotonic() + 9\n"
                "while time.monotonic() < end: time.sleep(0.1)\n"
            )
            leader = root / "leader.py"
            leader.write_text(
                "import json, os, signal, subprocess, sys, time\n"
                "from pathlib import Path\n"
                "signal.signal(signal.SIGINT, lambda *_: sys.exit(0))\n"
                "subprocess.Popen([sys.executable, sys.argv[1], sys.argv[2]])\n"
                "ready_end = time.monotonic() + 1\n"
                "while not Path(sys.argv[2]).exists() and time.monotonic() < ready_end: time.sleep(0.01)\n"
                "if not Path(sys.argv[2]).exists(): sys.exit(1)\n"
                "Path(sys.argv[3]).write_text(json.dumps({'group': os.getpid()}))\n"
                "end = time.monotonic() + 9\n"
                "while time.monotonic() < end: time.sleep(0.1)\n"
            )
            started = time.monotonic()
            runner = subprocess.Popen(
                [
                    sys.executable,
                    str(ROOT / "Scripts/bounded_run.py"),
                    "--seconds",
                    "30" if interrupt else "1",
                    "--",
                    sys.executable,
                    str(leader),
                    str(child),
                    str(root / "child.pid"),
                    str(ready),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
                env={**os.environ, "TMPDIR": directory},
            )
            group = None
            try:
                while not ready.exists() and time.monotonic() - started < 2:
                    time.sleep(0.02)
                self.assertTrue(ready.exists(), "Synthetic descendant did not start")
                group = json.loads(ready.read_text())["group"]
                if interrupt:
                    runner.send_signal(signal.SIGINT)
                try:
                    output, errors = runner.communicate(
                        timeout=max(0.1, 10 - (time.monotonic() - started))
                    )
                except subprocess.TimeoutExpired:
                    self.fail("Runner left a descendant holding its output pipe open")
                self.assertEqual(runner.returncode, 0 if interrupt else 124, errors)
                self.assertIn("Deadline:", output)
                with self.assertRaises(ProcessLookupError):
                    os.kill(int((root / "child.pid").read_text()), 0)
            finally:
                if group is None and ready.exists():
                    group = json.loads(ready.read_text())["group"]
                for process_group in (group, runner.pid):
                    if process_group is not None:
                        with contextlib.suppress(ProcessLookupError, PermissionError):
                            os.killpg(process_group, signal.SIGKILL)
                runner.communicate(timeout=2)

    def test_timeout_kills_descendant_after_leader_exits(self):
        self.check_descendant_cleanup(interrupt=False)

    def test_interrupt_kills_descendant_after_leader_exits(self):
        self.check_descendant_cleanup(interrupt=True)


if __name__ == "__main__":
    unittest.main()
