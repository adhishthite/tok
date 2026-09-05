#!/bin/bash
set -euo pipefail
app="${1:?Pass the built Tok.app path}"
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/build/package"
codesign --verify --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$root/build/package/Tok.zip"
echo "Created $root/build/package/Tok.zip (local development build; not notarized)"
