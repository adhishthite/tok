#!/usr/bin/env python3
"""Submit once, then inspect the same notarization job on subsequent invocations."""

import argparse
import fcntl
import hashlib
import json
import os
import subprocess
import sys
import uuid
from pathlib import Path


def call_notary(arguments, profile, seconds):
    try:
        result = subprocess.run(
            [
                "xcrun",
                "notarytool",
                *arguments,
                "--keychain-profile",
                profile,
                "--output-format",
                "json",
            ],
            capture_output=True,
            check=False,
            text=True,
            timeout=seconds,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"Notary command exceeded {seconds} seconds.") from None
    if result.returncode:
        # Tool errors can contain authentication details. Keep them out of build logs.
        raise RuntimeError(
            f"notarytool exited {result.returncode}; check the Keychain profile and Apple service status."
        )
    return json.loads(result.stdout)


def notarize(artifact, state_dir, profile, submission=None):
    digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    state_dir.mkdir(parents=True, exist_ok=True)
    state_path = state_dir / f"{digest}.json"
    with (state_dir / f"{digest}.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

        def save(state):
            temporary = state_path.with_suffix(".tmp")
            temporary.write_text(json.dumps(state, indent=2) + "\n")
            temporary.replace(state_path)

        state = json.loads(state_path.read_text()) if state_path.exists() else {}
        if submission:
            submission = str(uuid.UUID(submission))
            if state.get("id") and state["id"] != submission:
                raise RuntimeError(
                    "A different submission is already recorded for this archive."
                )
            state = {"sha256": digest, "id": submission}
            save(state)
        if not state:
            # Persist before contacting Apple. An ambiguous upload must never auto-retry.
            state = {"sha256": digest, "status": "upload-started"}
            save(state)
            result = call_notary(["submit", str(artifact), "--no-wait"], profile, 120)
            state["id"] = str(uuid.UUID(result["id"]))
            save(state)
        if not state.get("id"):
            raise RuntimeError(
                "Previous upload has no recorded submission ID. Inspect notarytool history, "
                "then use --submission with the matching ID. No archive was resubmitted."
            )
        result = call_notary(["info", state["id"]], profile, 30)
        state["status"] = result["status"]
        save(state)
        print(f"Notarization {state['id']}: {state['status']}", flush=True)
        if state["status"] == "Accepted":
            return 0
        if state["status"] == "In Progress":
            print(
                "Run the same command later to check this submission. No wait loop is running."
            )
            return 75
        raise RuntimeError(
            "Notarization was not accepted. Inspect the submission log before rebuilding."
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument(
        "--submission",
        help="Recover the matching submission ID after an interrupted upload.",
    )
    args = parser.parse_args()
    profile = os.environ.get("NOTARY_PROFILE")
    if not profile:
        parser.error(
            "Set NOTARY_PROFILE to an existing notarytool Keychain profile name."
        )
    try:
        return notarize(
            args.artifact.resolve(strict=True),
            Path("build/notary"),
            profile,
            args.submission,
        )
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"Notarization stopped: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
