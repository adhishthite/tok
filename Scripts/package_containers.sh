#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
python3 Scripts/bounded_run.py --seconds 20 --label verify-signature -- \
    codesign --verify --deep --strict build/distribution/Tok.app
mkdir -p build/package
stage="$(mktemp -d "$root/build/dmg-staging.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
python3 Scripts/bounded_run.py --seconds 30 --label stage-app -- \
    ditto build/distribution/Tok.app "$stage/Tok.app"
ln -s /Applications "$stage/Applications"
python3 Scripts/bounded_run.py --seconds 60 --label dmg -- hdiutil create -volname Tok \
    -srcfolder "$stage" -ov -fs APFS -format ULFO build/package/Tok.dmg
python3 - <<'PY'
import re
import subprocess
result = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True, timeout=10)
identities = re.findall(r'\b([A-F0-9]{40}) "([^"]+)"', result.stdout)
digest = next((digest for digest, name in identities if name.startswith('Developer ID Application:')), None)
if digest is None:
    raise SystemExit('Developer ID Application identity is required.')
subprocess.run(['codesign', '--force', '--sign', digest, '--timestamp', 'build/package/Tok.dmg'], check=True, timeout=30)
PY
python3 Scripts/bounded_run.py --seconds 60 --label zip -- ditto -c -k --sequesterRsrc --keepParent \
    build/distribution/Tok.app build/package/Tok-distribution.zip
echo 'Created signed Tok.dmg and Tok-distribution.zip. No artifacts were published.'
