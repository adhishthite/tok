#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
    app) archive=build/package/Tok-distribution.zip; target=build/distribution/Tok.app ;;
    dmg) archive=build/package/Tok.dmg; target=build/package/Tok.dmg ;;
    *) echo 'Usage: notarize_distribution.sh app|dmg' >&2; exit 2 ;;
esac
bound=(python3 Scripts/bounded_run.py --seconds 30)
# Stapling changes the container bytes. Recognize a valid ticket before hashing
# the archive, so a second invocation does not create another submission.
if "${bound[@]}" --label existing-ticket -- xcrun stapler validate "$target"; then
    echo 'The existing notarization ticket is valid.'
else
    python3 Scripts/notarize.py "$archive"
    "${bound[@]}" --label staple -- xcrun stapler staple "$target"
    "${bound[@]}" --label verify-ticket -- xcrun stapler validate "$target"
fi
