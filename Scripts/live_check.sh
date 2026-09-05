#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
test -f .env || { echo 'A local .env with GEMINI_API_KEY is required.' >&2; exit 1; }
mkdir -p build/fixtures
say -o build/fixtures/english.aiff 'Please send the revised architecture report by Friday.'
afconvert -f WAVE -d LEI16@16000 -c 1 build/fixtures/english.aiff build/fixtures/english.wav
python3 - <<'PY'
from pathlib import Path
import wave
with wave.open('build/fixtures/english.wav', 'rb') as audio:
    assert audio.getframerate() == 16000 and audio.getnchannels() == 1 and audio.getsampwidth() == 2
    assert audio.getnframes() > 16000, 'Speech synthesis did not produce audio'
    Path('build/fixtures/english.pcm').write_bytes(audio.readframes(audio.getnframes()))
PY
xcodegen generate
./Scripts/xcodebuild.sh -project Tok.xcodeproj -scheme TokLiveChecks -configuration Debug \
    -derivedDataPath build/DerivedData -destination 'platform=macOS' \
    -only-testing:TokEngineTests/LiveIntegrationTests test
