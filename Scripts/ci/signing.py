# Copyright 2026 Adhish Thite
# SPDX-License-Identifier: Apache-2.0

"""Stage signing inputs only on a disposable GitHub-hosted runner."""

import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def run(arguments, seconds=30, environment=None):
    result = subprocess.run(
        [str(value) for value in arguments],
        capture_output=True,
        text=True,
        timeout=seconds,
        env=environment,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(
            f"{Path(arguments[0]).name} failed (exit {result.returncode}); credential output withheld."
        )
    return result.stdout.strip()


def hosted():
    if (
        os.environ.get("GITHUB_ACTIONS") != "true"
        or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"
    ):
        raise RuntimeError(
            "Signing setup is restricted to disposable GitHub-hosted runners."
        )
    return Path(os.environ["RUNNER_TEMP"]).resolve()


def prepare():
    temporary = hosted()
    names = [
        "TOK_CERTIFICATE_P12_BASE64",
        "TOK_CERTIFICATE_PASSWORD",
        "TOK_NOTARY_KEY_BASE64",
        "TOK_NOTARY_KEY_ID",
        "TOK_NOTARY_ISSUER_ID",
        "TOK_SPARKLE_PRIVATE_KEY",
        "TOK_EXPECTED_TEAM_ID",
    ]
    missing = [name for name in names if not os.environ.get(name)]
    if missing:
        raise RuntimeError("Configure release inputs: " + ", ".join(missing))
    directory = Path(tempfile.mkdtemp(prefix="tok-signing-", dir=temporary))
    keychain = directory / "signing.keychain-db"
    original_default = run(["security", "default-keychain", "-d", "user"]).strip('"')
    original_search = [
        line.strip().strip('"')
        for line in run(["security", "list-keychains", "-d", "user"]).splitlines()
    ]
    state = {
        "directory": str(directory),
        "keychain": str(keychain),
        "default": original_default,
        "search": original_search,
    }
    (temporary / "tok-signing-state.json").write_text(json.dumps(state))
    # Empty password only for this short-lived CI keychain. The encrypted P12
    # password is passed directly to Security by import_identity.swift.
    run(["security", "create-keychain", "-p", "", keychain])
    run(["security", "unlock-keychain", "-p", "", keychain])
    run(["security", "set-keychain-settings", "-lut", "21600", keychain])
    run(["security", "list-keychains", "-d", "user", "-s", keychain, *original_search])
    run(["security", "default-keychain", "-d", "user", "-s", keychain])
    run(["swift", ROOT / "Scripts/ci/import_identity.swift", keychain])
    run(
        [
            "security",
            "set-key-partition-list",
            "-S",
            "apple-tool:,apple:,codesign:",
            "-s",
            "-k",
            "",
            keychain,
        ]
    )
    notary_key = directory / "notary.p8"
    notary_key.write_bytes(
        base64.b64decode(os.environ["TOK_NOTARY_KEY_BASE64"], validate=True)
    )
    notary_key.chmod(0o600)
    sparkle_key = directory / "sparkle.key"
    sparkle_key.write_text(os.environ["TOK_SPARKLE_PRIVATE_KEY"].strip())
    sparkle_key.chmod(0o600)
    run(
        [
            "xcrun",
            "notarytool",
            "store-credentials",
            "TokCI",
            "--key",
            notary_key,
            "--key-id",
            os.environ["TOK_NOTARY_KEY_ID"],
            "--issuer",
            os.environ["TOK_NOTARY_ISSUER_ID"],
            "--keychain",
            keychain,
        ]
    )
    binaries = ROOT / "build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
    challenge = directory / "key-check.txt"
    challenge.write_text("Tok CI signing key verification\n")
    signature = run(
        [binaries / "sign_update", "--ed-key-file", sparkle_key, "-p", challenge]
    )
    environment = os.environ.copy()
    environment["TOK_TEST_SIGNATURE"] = signature
    run(
        [
            "swift",
            ROOT / "Scripts/ci/verify_signature.swift",
            ROOT / "Config/Info.plist",
            challenge,
        ],
        environment=environment,
    )
    with open(os.environ["GITHUB_ENV"], "a") as output:
        output.write(f"NOTARY_PROFILE=TokCI\nTOK_SPARKLE_KEY_FILE={sparkle_key}\n")
    print("Prepared temporary signing credentials; Sparkle key matches the app.")


def cleanup():
    temporary = hosted()
    state_path = temporary / "tok-signing-state.json"
    if not state_path.exists():
        return
    state = json.loads(state_path.read_text())
    directory = Path(state["directory"]).resolve()
    if directory.parent != temporary or not directory.name.startswith("tok-signing-"):
        raise RuntimeError("Refusing cleanup outside the signing directory.")
    run(["security", "default-keychain", "-d", "user", "-s", state["default"]])
    run(["security", "list-keychains", "-d", "user", "-s", *state["search"]])
    if Path(state["keychain"]).exists():
        run(["security", "delete-keychain", state["keychain"]])
    shutil.rmtree(directory)
    state_path.unlink()
    print(
        "Removed temporary signing files and keychain; restored runner keychain selection."
    )


if __name__ == "__main__":
    try:
        {"prepare": prepare, "cleanup": cleanup}[sys.argv[1]]()
    except (
        RuntimeError,
        OSError,
        ValueError,
        KeyError,
        IndexError,
        subprocess.TimeoutExpired,
    ) as error:
        # Never print exceptions that may contain secret-bearing process arguments.
        print(
            str(error)
            if isinstance(error, RuntimeError)
            else "Signing setup stopped; check release inputs.",
            file=sys.stderr,
        )
        sys.exit(1)
