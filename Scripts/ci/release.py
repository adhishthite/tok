"""Build a bounded, resumable release and populate a GitHub draft. Never publish."""

import contextlib
import hashlib
import json
import os
import plistlib
import posixpath
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import time
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
STATE = ROOT / "build/release-state.json"
BIN = ROOT / "build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"


def run(arguments, seconds=120, accepted=(0,)):
    environment = os.environ.copy()
    if Path(arguments[0]).name != "gh":
        environment.pop("GH_TOKEN", None)
    process = subprocess.Popen(
        [str(value) for value in arguments],
        cwd=ROOT,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=seconds)
    except subprocess.TimeoutExpired:
        # Give nested deadline supervisors a chance to forward the interrupt to
        # their own sessions, then kill any members left in this process group.
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGINT)
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        finally:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()
        raise RuntimeError(
            f"{Path(arguments[0]).name} exceeded its {seconds:g}-second limit; command output withheld."
        ) from None
    result = subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)
    if result.returncode not in accepted:
        raise RuntimeError(
            f"{Path(arguments[0]).name} exited {result.returncode}. Raw output withheld; preserve recovery files."
        )
    return result


def save(state):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    staged = STATE.with_suffix(".tmp")
    staged.write_text(json.dumps(state, indent=2) + "\n")
    staged.replace(STATE)


def configuration():
    tag = os.environ.get("TOK_RELEASE_TAG", "")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise RuntimeError("Use a version tag such as v0.1.0.")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise RuntimeError("A GitHub repository is required.")
    project = (ROOT / "project.yml").read_text()
    version = re.search(r"MARKETING_VERSION:\s*'([^']+)'", project).group(1)
    build = re.search(r"CURRENT_PROJECT_VERSION:\s*'(\d+)'", project).group(1)
    if tag != "v" + version:
        raise RuntimeError(
            "The release tag must match MARKETING_VERSION in project.yml."
        )
    commit = run(["git", "rev-parse", "HEAD"], 5).stdout.strip()
    if run(["git", "status", "--porcelain"], 5).stdout:
        raise RuntimeError("Release from a clean checkout.")
    run(["git", "merge-base", "--is-ancestor", commit, "origin/main"], 5)
    return {
        "repository": repository,
        "tag": tag,
        "version": version,
        "build": build,
        "commit": commit,
        "stage": "build",
    }


def verify_tag(state):
    # Query the remote directly: checkout is shallow and may not contain tags.
    result = run(
        [
            "gh",
            "api",
            f"repos/{state['repository']}/git/ref/tags/{state['tag']}",
            "--include",
        ],
        30,
        accepted=(0, 1),
    )
    if result.returncode:
        # Only an explicit missing-ref response permits a new tag. Authentication
        # and transport failures must not be mistaken for an absent tag.
        if re.search(r"^HTTP/\S+ 404(?: |$)", result.stdout, re.MULTILINE):
            return
        raise RuntimeError("Could not verify the release tag; no release changes made.")
    payload = result.stdout.split("\r\n\r\n", 1)
    if len(payload) == 1:
        payload = result.stdout.split("\n\n", 1)
    reference = json.loads(payload[-1])["object"]
    for _ in range(8):
        if reference["type"] == "commit":
            if reference["sha"] != state["commit"]:
                raise RuntimeError(
                    "Existing release tag does not match the recorded source commit."
                )
            return
        if reference["type"] != "tag":
            break
        reference = json.loads(
            run(
                [
                    "gh",
                    "api",
                    f"repos/{state['repository']}/git/tags/{reference['sha']}",
                ],
                30,
            ).stdout
        )["object"]
    raise RuntimeError("Release tag does not resolve to a supported commit reference.")


def preflight():
    state = configuration()
    verify_tag(state)
    repository = json.loads(
        run(["gh", "api", "repos/" + state["repository"]], 30).stdout
    )
    if repository.get("private"):
        raise RuntimeError(
            "This hosting setup requires a public repository for anonymous Sparkle downloads."
        )
    existing = run(
        [
            "gh",
            "release",
            "view",
            state["tag"],
            "--repo",
            state["repository"],
            "--json",
            "isDraft",
        ],
        30,
        accepted=(0, 1),
    )
    if existing.returncode == 0:
        raise RuntimeError(
            "This release already exists. Resume its recorded attempt rather than rebuilding it."
        )
    print("Release version, source, and repository checks passed.")


def notarize(kind):
    deadline = time.monotonic() + 300
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError(
                "Apple review polling deadline reached; preserve recovery files."
            )
        result = run(
            ["bash", "Scripts/notarize_distribution.sh", kind],
            min(180, remaining),
            accepted=(0, 75),
        )
        if result.returncode == 0:
            print(f"Accepted and stapled {kind}.", flush=True)
            return
        print(
            f"Apple is reviewing {kind}; the same saved submission will be checked again.",
            flush=True,
        )
        if time.monotonic() + 20 >= deadline:
            raise RuntimeError(
                "Apple review remains pending. Download the recovery artifact and resume this attempt; do not start a fresh release."
            )
        time.sleep(20)


def prepare(resume=False):
    if resume:
        state = json.loads(STATE.read_text())
        remote = run(["git", "remote", "get-url", "origin"], 5).stdout.strip()
        if remote.startswith("git@github.com:"):
            repository = remote.split(":", 1)[1].removesuffix(".git")
        else:
            parsed = urlparse(remote)
            repository = (
                parsed.path.lstrip("/").removesuffix(".git")
                if parsed.hostname == "github.com"
                else ""
            )
        if repository.lower() != state["repository"].lower():
            raise RuntimeError("Recovery repository does not match this checkout.")
        if run(["git", "rev-parse", "HEAD"], 5).stdout.strip() != state["commit"]:
            raise RuntimeError("Resume from the original recorded source commit.")
        release = json.loads(
            run(
                [
                    "gh",
                    "release",
                    "view",
                    state["tag"],
                    "--repo",
                    state["repository"],
                    "--json",
                    "isDraft,targetCommitish",
                ],
                30,
            ).stdout
        )
        if not release["isDraft"] or release["targetCommitish"] != state["commit"]:
            raise RuntimeError("Only the matching unpublished draft can be resumed.")
    else:
        preflight()
        state = configuration()
        notes = ROOT / "build/release-notes.md"
        notes.parent.mkdir(parents=True, exist_ok=True)
        notes.write_text(
            f"Tok {state['version']} (build {state['build']}).\n\nSigned release preparation in progress.\n"
        )
        run(
            [
                "gh",
                "release",
                "create",
                state["tag"],
                "--repo",
                state["repository"],
                "--draft",
                "--target",
                state["commit"],
                "--title",
                "Tok " + state["version"],
                "--notes-file",
                notes,
            ],
            30,
        )
        save(state)
    os.environ["TOK_UPDATE_FEED_URL"] = (
        f"https://github.com/{state['repository']}/releases/latest/download/appcast.xml"
    )
    if state["stage"] == "build":
        print("Building signed release.", flush=True)
        run(["make", "distribute"], 360)
        state["stage"] = "app"
        save(state)
    if state["stage"] == "app":
        notarize("app")
        state["stage"] = "containers"
        save(state)
    if state["stage"] == "containers":
        run(["make", "containers"], 180)
        state["stage"] = "dmg"
        save(state)
    if state["stage"] == "dmg":
        notarize("dmg")
        state["stage"] = "assets"
        save(state)
    app = ROOT / "build/distribution/Tok.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = (
        state["version"],
        state["build"],
        state["commit"][:12],
        os.environ["TOK_UPDATE_FEED_URL"],
    )
    actual = tuple(
        info.get(key)
        for key in [
            "CFBundleShortVersionString",
            "CFBundleVersion",
            "TokSourceRevision",
            "SUFeedURL",
        ]
    )
    if actual != expected:
        raise RuntimeError("App metadata does not match the release request.")
    architectures = run(
        ["lipo", "-archs", app / "Contents/MacOS/Tok"], 10
    ).stdout.split()
    if (
        set(architectures) != {"arm64", "x86_64"}
        or info.get("LSMinimumSystemVersion") != "14.0"
    ):
        raise RuntimeError(
            "Release must contain both architectures and declare macOS 14.0."
        )
    team = os.environ.get("TOK_EXPECTED_TEAM_ID")
    signature = run(["codesign", "-d", "--verbose=4", app], 20)
    if not team or f"TeamIdentifier={team}" not in signature.stderr.splitlines():
        raise RuntimeError("Signing team does not match TOK_EXPECTED_TEAM_ID.")
    for target in [app, ROOT / "build/package/Tok.dmg"]:
        run(["codesign", "--verify", "--deep", "--strict", target], 30)
        run(["xcrun", "stapler", "validate", target], 30)
    run(["spctl", "--assess", "--type", "execute", app], 30)
    run(
        [
            "spctl",
            "--assess",
            "--type",
            "open",
            "--context",
            "context:primary-signature",
            "build/package/Tok.dmg",
        ],
        30,
    )
    assets = ROOT / "build/release-assets"
    updates = ROOT / "build/release-updates"
    assets.mkdir(exist_ok=True)
    updates.mkdir(exist_ok=True)
    shutil.copy2(ROOT / "build/package/Tok-distribution.zip", updates / "Tok.zip")
    key = os.environ.get("TOK_SPARKLE_KEY_FILE")
    signing = ["--ed-key-file", key] if key else ["--account", "com.adhishthite.tok"]
    run(
        [
            BIN / "generate_appcast",
            *signing,
            "--maximum-deltas",
            "0",
            "--download-url-prefix",
            f"https://github.com/{state['repository']}/releases/download/{state['tag']}/",
            "-o",
            assets / "appcast.xml",
            updates,
        ],
        60,
    )
    run([BIN / "sign_update", *signing, "--verify", assets / "appcast.xml"], 30)
    signature = run(
        [BIN / "sign_update", *signing, "-p", updates / "Tok.zip"], 30
    ).stdout.strip()
    os.environ["TOK_TEST_SIGNATURE"] = signature
    try:
        run(
            [
                "swift",
                "Scripts/ci/verify_signature.swift",
                app / "Contents/Info.plist",
                updates / "Tok.zip",
            ],
            30,
        )
    finally:
        os.environ.pop("TOK_TEST_SIGNATURE", None)
    shutil.copy2(updates / "Tok.zip", assets / "Tok.zip")
    shutil.copy2(ROOT / "build/package/Tok.dmg", assets / "Tok.dmg")
    (assets / "checksums.txt").write_text(
        "".join(
            hashlib.sha256((assets / name).read_bytes()).hexdigest()
            + "  "
            + name
            + "\n"
            for name in ["Tok.dmg", "Tok.zip", "appcast.xml"]
        )
    )
    current = json.loads(
        run(
            [
                "gh",
                "release",
                "view",
                state["tag"],
                "--repo",
                state["repository"],
                "--json",
                "isDraft,targetCommitish",
            ],
            30,
        ).stdout
    )
    if not current["isDraft"] or current["targetCommitish"] != state["commit"]:
        raise RuntimeError(
            "The release changed during preparation; no assets were replaced."
        )
    verify_tag(state)
    run(
        [
            "gh",
            "release",
            "upload",
            state["tag"],
            "--repo",
            state["repository"],
            "--clobber",
            *[
                assets / name
                for name in ["Tok.dmg", "Tok.zip", "appcast.xml", "checksums.txt"]
            ],
        ],
        120,
    )
    state["stage"] = "draft-ready"
    save(state)
    notes = ROOT / "build/release-notes.md"
    notes.write_text(
        f"Tok {state['version']} (build {state['build']}).\n\n"
        "Signed, notarized, and stapled for macOS 14 or later, on Apple silicon and Intel.\n\n"
        f"Source: `{state['commit']}`.\n\n"
        "Package verification completed. Review this draft before publishing.\n"
    )
    run(
        [
            "gh",
            "release",
            "edit",
            state["tag"],
            "--repo",
            state["repository"],
            "--notes-file",
            notes,
        ],
        30,
    )
    print(
        "Verified assets uploaded to the draft release. Publication requires an explicit action."
    )


def bundle():
    if not STATE.exists():
        return
    with tarfile.open(ROOT / "build/release-recovery.tar", "w") as archive:
        for name in [
            "build/release-state.json",
            "build/distribution",
            "build/package",
            "build/notary",
        ]:
            path = ROOT / name
            if path.exists():
                archive.add(path, arcname=name)
    print("Saved release recovery bundle; it contains no staged signing credentials.")


def restore(path):
    # Run only in a fresh checkout of the recorded commit. Existing deliverables
    # must not be overwritten by a recovery archive.
    allowed = (
        "build/release-state.json",
        "build/distribution",
        "build/package",
        "build/notary",
    )
    if any((ROOT / name).exists() for name in allowed):
        raise RuntimeError(
            "Restore into a fresh checkout without existing release output."
        )
    with tarfile.open(path, "r") as archive:
        members = archive.getmembers()
        if (
            len(members) > 20_000
            or sum(member.size for member in members) > 500_000_000
        ):
            raise RuntimeError("Recovery archive is unexpectedly large.")
        for member in members:
            if member.name.startswith("/") or ".." in member.name.split("/"):
                raise RuntimeError("Unsafe recovery archive path.")
            if not any(
                member.name == name or member.name.startswith(name + "/")
                for name in allowed
            ):
                raise RuntimeError("Unexpected recovery archive path.")
            if member.issym() or member.islnk():
                destination = posixpath.normpath(
                    posixpath.join(posixpath.dirname(member.name), member.linkname)
                    if member.issym()
                    else member.linkname
                )
                if not destination.startswith("build/distribution/"):
                    raise RuntimeError(
                        "Recovery links must stay within the app distribution."
                    )
        archive.extractall(ROOT, members=members, filter="data")
    print(
        "Restored release state. Verify its repository, tag, and commit before resuming."
    )


if __name__ == "__main__":
    try:
        {
            "preflight": preflight,
            "prepare": prepare,
            "resume": lambda: prepare(True),
            "bundle": bundle,
            "restore": lambda: restore(sys.argv[2]),
        }[sys.argv[1]]()
    except (
        RuntimeError,
        OSError,
        ValueError,
        KeyError,
        AttributeError,
        IndexError,
        subprocess.TimeoutExpired,
    ) as error:
        print(
            str(error)
            if isinstance(error, RuntimeError)
            else "Release stopped; preserve recovery artifacts and inspect the recorded stage.",
            file=sys.stderr,
        )
        sys.exit(1)
