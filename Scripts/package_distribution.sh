#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p build/distribution build/package
xcodegen generate
TOK_SIGNING_MODE=distribution ./Scripts/xcodebuild.sh -project Tok.xcodeproj -scheme Tok \
    -configuration Release -derivedDataPath build/DerivedData \
    -destination 'generic/platform=macOS' -archivePath build/Tok.xcarchive archive
python3 - <<'PY'
from pathlib import Path
import plistlib,re,subprocess
result=subprocess.run(['security','find-identity','-v','-p','codesigning'],capture_output=True,text=True,timeout=10)
identities=re.findall(r'\b([A-F0-9]{40}) "([^"]+)"',result.stdout)
identity=next((name for _,name in identities if name.startswith('Developer ID Application:')),None)
if identity is None:raise SystemExit('Developer ID identity not available.')
team=re.search(r'\(([A-Z0-9]+)\)$',identity).group(1)
options={'method':'developer-id','teamID':team,'signingStyle':'manual','signingCertificate':'Developer ID Application','destination':'export'}
Path('build/ExportOptions.plist').write_bytes(plistlib.dumps(options))
PY
python3 Scripts/bounded_run.py --seconds 120 --label export -- xcodebuild -exportArchive \
    -archivePath build/Tok.xcarchive -exportPath build/distribution \
    -exportOptionsPlist build/ExportOptions.plist
codesign --verify --deep --strict build/distribution/Tok.app
./Scripts/package_containers.sh
echo 'Created Developer ID distribution artifacts. Notarization has not been performed.'
