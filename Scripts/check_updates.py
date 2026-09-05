#!/usr/bin/env python3
"""Exercise Sparkle signing locally without publishing or installing an update."""

import base64
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
APP = ROOT / "build/DerivedData/Build/Products/Debug/Tok.app"
ACCOUNT = "com.adhishthite.tok"


def run(arguments, label, expected_success=True):
    print(f"Running: {label} (30-second limit)", flush=True)
    try:
        result = subprocess.run(
            [str(value) for value in arguments],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"{label} exceeded 30 seconds and was stopped.") from None
    if (result.returncode == 0) != expected_success:
        raise RuntimeError(f"{label}: unexpected exit status {result.returncode}.")
    if (
        not expected_success
        and "failed to pass signing verification" not in result.stdout
    ):
        raise RuntimeError(f"{label}: failure was not a signature rejection.")
    print(f"Completed: {label}", flush=True)
    return result.stdout.strip()


def main():
    info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
    public_key = run(
        [BIN / "generate_keys", "--account", ACCOUNT, "-p"], "Public-key lookup"
    )
    assert public_key == info["SUPublicEDKey"], (
        "Signing and application public keys differ."
    )
    assert len(base64.b64decode(public_key, validate=True)) == 32
    assert info["SURequireSignedFeed"] and info["SUVerifyUpdateBeforeExtraction"]
    stage = Path(tempfile.mkdtemp(prefix="sparkle-check-", dir=ROOT / "build"))
    (stage / "TEST-ONLY.txt").write_text(
        "Local signing test using a development build. Do not distribute these files.\n"
    )
    archive = stage / "Tok-test.zip"
    run(
        ["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", APP, archive],
        "Test archive",
    )
    feed = stage / "appcast.xml"
    run(
        [
            BIN / "generate_appcast",
            "--account",
            ACCOUNT,
            "--maximum-deltas",
            "0",
            "--download-url-prefix",
            "https://updates.invalid/",
            "-o",
            feed,
            stage,
        ],
        "Feed generation",
    )
    run(
        [BIN / "sign_update", "--account", ACCOUNT, "--verify", feed],
        "Feed verification",
    )
    enclosure = ET.parse(feed).find(".//enclosure")
    assert enclosure is not None, "Missing update enclosure."
    signature = enclosure.attrib[
        "{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"
    ]
    assert int(enclosure.attrib["length"]) == archive.stat().st_size
    run(
        [BIN / "sign_update", "--account", ACCOUNT, "--verify", archive, signature],
        "Archive verification",
    )
    changed_archive = stage / "changed.zip"
    changed_archive.write_bytes(archive.read_bytes() + b"tampered")
    run(
        [
            BIN / "sign_update",
            "--account",
            ACCOUNT,
            "--verify",
            changed_archive,
            signature,
        ],
        "Changed archive rejection",
        expected_success=False,
    )
    changed_feed = stage / "changed.xml"
    original = feed.read_text()
    changed = original.replace("https://updates.invalid/", "https://modified.invalid/")
    assert changed != original
    changed_feed.write_text(changed)
    run(
        [BIN / "sign_update", "--account", ACCOUNT, "--verify", changed_feed],
        "Changed feed rejection",
        expected_success=False,
    )
    print("PASS: embedded public key matches the signing key.")
    print("PASS: generated feed and archive signatures verify.")
    print("PASS: modified feed and archive are rejected.")
    print(f"Test-only artifacts: {stage}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, AssertionError) as error:
        print(f"STOPPED: {error}", file=sys.stderr)
        sys.exit(1)
