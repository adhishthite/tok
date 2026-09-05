#!/bin/bash
set -euo pipefail
exec python3 - "$@" <<'PY'
import os
import re
import subprocess
import sys

result = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True)
identities = re.findall(r'\b([A-F0-9]{40}) "([^"]+)"', result.stdout)
identity = next(((digest, name) for digest, name in identities if name.startswith('Apple Development:')), None)
settings = []
if identity:
    digest, name = identity
    settings.append('CODE_SIGN_IDENTITY=' + digest)
    team = re.search(r'\(([A-Z0-9]+)\)$', name)
    if team:
        settings.append('DEVELOPMENT_TEAM=' + team[1])
    print('Signing: Apple Development', flush=True)
else:
    print('Signing: ad-hoc local development', flush=True)
runner = os.path.join(os.getcwd(), 'Scripts', 'bounded_run.py')
os.execv(sys.executable, [sys.executable, runner, '--seconds', os.environ.get('TOK_BUILD_TIMEOUT_SECONDS', '120'), '--label', 'xcodebuild', '--', 'xcodebuild', *sys.argv[1:], *settings])
PY
