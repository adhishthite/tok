import hashlib
import importlib.util
import io
import json
import os
import plistlib
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, file)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


ROOT = Path(__file__).resolve().parents[2]
release = module("ci_release", ROOT / "Scripts/ci/release.py")
signing = module("ci_signing", ROOT / "Scripts/ci/signing.py")


class CIReleaseTests(unittest.TestCase):
    def test_signing_setup_refuses_local_machine(self):
        with (
            patch.dict(os.environ, {}, clear=True),
            self.assertRaisesRegex(RuntimeError, "disposable"),
        ):
            signing.prepare()

    def test_untrusted_tag_is_rejected_before_running_commands(self):
        with (
            patch.dict(
                os.environ,
                {
                    "TOK_RELEASE_TAG": "v1.2.3; command",
                    "GITHUB_REPOSITORY": "owner/repo",
                },
            ),
            patch.object(release, "run") as run,
        ):
            with self.assertRaisesRegex(RuntimeError, "version tag"):
                release.configuration()
            run.assert_not_called()

    def test_resuming_dmg_does_not_rebuild_or_resubmit_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state_path = root / "state.json"
            state = {
                "hosting_commit": "a" * 40,
                "source_commit": "b" * 40,
                "source_repository": "owner/repo",
                "feed_url": "https://github.com/owner/releases/releases/latest/download/appcast.xml",
                "version": "1.2.3",
                "build": "7",
                "stage": "dmg",
                "hosting_repository": "owner/releases",
                "tag": "v1.2.3",
            }
            state_path.write_text(json.dumps(state))

            def run(args, *unused, **kwargs):
                result = (
                    "git@github.com:owner/repo.git"
                    if args[:2] == ["git", "remote"]
                    else state["hosting_commit"]
                    if args[0] == "git"
                    else json.dumps(
                        {"isDraft": True, "targetCommitish": state["hosting_commit"]}
                    )
                )
                return subprocess.CompletedProcess(args, 0, result, "")

            with (
                patch.object(release, "STATE", state_path),
                patch.object(release, "require_draft_authorization"),
                patch.object(release, "configuration", return_value=state),
                patch.object(release, "verify_destinations"),
                patch.object(release, "verify_tag"),
                patch.object(release, "run", side_effect=run) as calls,
                patch.object(
                    release, "notarize", side_effect=RuntimeError("pending")
                ) as notarize,
            ):
                with self.assertRaisesRegex(RuntimeError, "pending"):
                    release.prepare(resume=True)
                notarize.assert_called_once_with("dmg")
                self.assertFalse(
                    any(call.args[0][0] == "make" for call in calls.call_args_list)
                )
                self.assertEqual(json.loads(state_path.read_text())["stage"], "dmg")

    def test_prepare_and_resume_require_exact_draft_authorization_before_commands(self):
        for resume in [False, True]:
            with (
                self.subTest(resume=resume),
                patch.dict(
                    os.environ,
                    {
                        "TOK_RELEASE_REPOSITORY": "owner/releases",
                        "TOK_RELEASE_TAG": "v1.2.3",
                        "TOK_RELEASE_HOSTING_COMMIT": "a" * 40,
                        "TOK_RELEASE_DRAFT_AUTHORIZATION": "owner/releases:v1.2.3:wrong",
                    },
                    clear=True,
                ),
                patch.object(release, "run") as run,
                self.assertRaisesRegex(RuntimeError, "Explicit authorization"),
            ):
                release.prepare(resume=resume)
            run.assert_not_called()

    def test_exact_draft_authorization_is_scoped_to_target(self):
        with patch.dict(
            os.environ,
            {
                "TOK_RELEASE_REPOSITORY": "owner/releases",
                "TOK_RELEASE_TAG": "v1.2.3",
                "TOK_RELEASE_HOSTING_COMMIT": "a" * 40,
                "TOK_RELEASE_DRAFT_AUTHORIZATION": "owner/releases:v1.2.3:" + "a" * 40,
            },
            clear=True,
        ):
            release.require_draft_authorization()

    def test_source_must_remain_private(self):
        state = {
            "source_repository": "owner/source",
            "hosting_repository": "owner/releases",
        }
        with (
            patch.object(
                release,
                "run",
                return_value=subprocess.CompletedProcess(
                    [],
                    0,
                    json.dumps({"private": False, "full_name": "owner/source"}),
                    "",
                ),
            ),
            self.assertRaisesRegex(RuntimeError, "remain private"),
        ):
            release.verify_destinations(state)

    def test_local_staging_never_creates_draft_before_artifact_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            state = {
                "hosting_repository": "owner/releases",
                "tag": "v1.2.3",
                "feed_url": "https://github.com/owner/releases/releases/latest/download/appcast.xml",
            }
            with (
                patch.object(release, "ROOT", Path(directory)),
                patch.object(release, "configuration", return_value=state),
                patch.object(release, "verify_destinations"),
                patch.object(release, "run") as run,
                self.assertRaises(FileNotFoundError),
            ):
                release.prepare(local_only=True)
            run.assert_not_called()

    def test_update_security_flags_must_be_true_booleans(self):
        for key in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"]:
            for value in [False, None, 1, "true"]:
                info = {
                    "SURequireSignedFeed": True,
                    "SUVerifyUpdateBeforeExtraction": True,
                }
                info[key] = value
                with (
                    self.subTest(key=key, value=value),
                    self.assertRaisesRegex(RuntimeError, "signed feeds"),
                ):
                    release.verify_update_flags(info)

    def test_wrong_zip_is_rejected_before_code_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Tok.app"
            app.mkdir()
            (app / "payload").write_bytes(b"current")
            archive = root / "Tok.zip"
            with zipfile.ZipFile(archive, "w") as zipped:
                zipped.writestr("Tok.app/payload", b"stale")

            def run(args, *unused):
                self.assertEqual(args[0], "ditto")
                with zipfile.ZipFile(args[3]) as zipped:
                    zipped.extractall(args[4])
                return subprocess.CompletedProcess(args, 0, "", "")

            with (
                patch.object(release, "run", side_effect=run) as calls,
                self.assertRaisesRegex(RuntimeError, "exact verified"),
            ):
                release.verify_update_archive(app, archive)
            self.assertEqual(calls.call_count, 1)

    def test_local_stage_success_preserves_archive_hash_and_never_mutates_github(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "build/distribution/Tok.app"
            (app / "Contents").mkdir(parents=True)
            state = {
                "hosting_repository": "owner/releases",
                "source_commit": "a" * 40,
                "tag": "v1.2.3",
                "version": "1.2.3",
                "build": "8",
                "feed_url": "https://github.com/owner/releases/releases/latest/download/appcast.xml",
            }
            info = {
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "8",
                "TokSourceRevision": "a" * 12,
                "SUFeedURL": state["feed_url"],
                "LSMinimumSystemVersion": "14.0",
                "SURequireSignedFeed": True,
                "SUVerifyUpdateBeforeExtraction": True,
            }
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            package = root / "build/package"
            package.mkdir()
            (package / "Tok.dmg").write_bytes(b"synthetic dmg")
            archive = package / "Tok-distribution.zip"
            with zipfile.ZipFile(archive, "w") as zipped:
                zipped.write(app / "Contents/Info.plist", "Tok.app/Contents/Info.plist")

            def run(args, *unused):
                command = str(args[0])
                self.assertNotEqual(command, "gh")
                if command == "ditto":
                    with zipfile.ZipFile(args[3]) as zipped:
                        zipped.extractall(args[4])
                if Path(command).name == "generate_appcast":
                    Path(args[args.index("-o") + 1]).write_text("synthetic signed feed")
                return subprocess.CompletedProcess(
                    args,
                    0,
                    "arm64 x86_64" if command == "lipo" else "signature",
                    "TeamIdentifier=FIXTURE" if command == "codesign" else "",
                )

            with (
                patch.object(release, "ROOT", root),
                patch.object(release, "configuration", return_value=state),
                patch.object(release, "verify_destinations"),
                patch.object(release, "run", side_effect=run),
                patch.dict(os.environ, {"TOK_EXPECTED_TEAM_ID": "FIXTURE"}, clear=True),
            ):
                release.prepare(local_only=True)
            assets = root / "build/release-assets"
            manifest = json.loads((assets / "release-manifest.json").read_text())
            self.assertEqual(manifest["stage"], "local-assets-ready")
            self.assertEqual(
                manifest["artifact_sha256"]["Tok.zip"],
                hashlib.sha256(archive.read_bytes()).hexdigest(),
            )
            self.assertFalse((root / "build/release-state.json").exists())

    def test_timeout_stops_child_after_parent_exits_on_interrupt(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "child-survived"
            child = (
                "import signal,time; from pathlib import Path; "
                "signal.signal(signal.SIGINT, signal.SIG_IGN); "
                f"time.sleep(6); Path({str(marker)!r}).write_text('survived')"
            )
            parent = (
                "import subprocess,sys,time; "
                f"subprocess.Popen([sys.executable, '-c', {child!r}]); time.sleep(20)"
            )
            with self.assertRaisesRegex(RuntimeError, "second limit"):
                release.run([sys.executable, "-c", parent], seconds=0.3)
            time.sleep(1.2)
            self.assertFalse(
                marker.exists(), "A descendant survived the timeout cleanup"
            )

    def test_existing_tag_must_resolve_to_recorded_commit(self):
        state = {
            "hosting_repository": "owner/releases",
            "tag": "v1.2.3",
            "hosting_commit": "a" * 40,
        }
        for kind in ["commit", "tag"]:
            with self.subTest(kind=kind):
                first = subprocess.CompletedProcess(
                    [],
                    0,
                    "HTTP/2.0 200 OK\n\n"
                    + json.dumps({"object": {"type": kind, "sha": "b" * 40}}),
                    "",
                )
                annotated = subprocess.CompletedProcess(
                    [],
                    0,
                    json.dumps({"object": {"type": "commit", "sha": "c" * 40}}),
                    "",
                )
                with (
                    patch.object(release, "run", side_effect=[first, annotated]),
                    self.assertRaisesRegex(RuntimeError, "does not match"),
                ):
                    release.verify_tag(state)

    def test_missing_tag_requires_explicit_not_found_response(self):
        state = {
            "hosting_repository": "owner/releases",
            "tag": "v1.2.3",
            "hosting_commit": "a" * 40,
        }
        for status, permitted in [(404, True), (401, False), (500, False)]:
            with (
                self.subTest(status=status),
                patch.object(
                    release,
                    "run",
                    return_value=subprocess.CompletedProcess(
                        [], 1, f"HTTP/2.0 {status} Error\n\n{{}}", ""
                    ),
                ),
            ):
                if permitted:
                    release.verify_tag(state)
                else:
                    with self.assertRaisesRegex(RuntimeError, "Could not verify"):
                        release.verify_tag(state)

    def test_notary_invocation_uses_remaining_poll_budget(self):
        with (
            patch.object(release.time, "monotonic", side_effect=[0, 280]),
            patch.object(
                release, "run", return_value=subprocess.CompletedProcess([], 0)
            ) as run,
        ):
            release.notarize("app")
            self.assertEqual(run.call_args.args[1], 20)

    def test_recovery_bundle_excludes_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "build/package").mkdir(parents=True)
            (root / "build/package/Tok.dmg").write_bytes(b"fixture")
            state_path = root / "build/release-state.json"
            state_path.write_text('{"stage":"dmg"}')
            (root / "private.key").write_text("not a real key")
            with (
                patch.object(release, "ROOT", root),
                patch.object(release, "STATE", state_path),
            ):
                release.bundle()
                with tarfile.open(root / "build/release-recovery.tar") as archive:
                    self.assertNotIn("private.key", archive.getnames())
                    self.assertIn("build/release-state.json", archive.getnames())

    def test_restore_rejects_traversal_and_external_links(self):
        for name, link in [
            ("build/package/../../escape", None),
            ("build/distribution/link", "../../Scripts"),
        ]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                path = root / "fixture.tar"
                with tarfile.open(path, "w") as archive:
                    entry = tarfile.TarInfo(name)
                    if link:
                        entry.type = tarfile.SYMTYPE
                        entry.linkname = link
                        archive.addfile(entry)
                    else:
                        entry.size = 1
                        archive.addfile(entry, io.BytesIO(b"x"))
                with (
                    patch.object(release, "ROOT", root),
                    self.assertRaises(RuntimeError),
                ):
                    release.restore(path)


if __name__ == "__main__":
    unittest.main()
