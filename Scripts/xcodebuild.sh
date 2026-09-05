#!/bin/bash
set -euo pipefail
exec python3 - "$@" <<'PY'
import os
import re
import subprocess
import sys

result = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True, timeout=10)
identities = re.findall(r'\b([A-F0-9]{40}) "([^"]+)"', result.stdout)
distribution = os.environ.get('TOK_SIGNING_MODE') == 'distribution'
prefix = 'Developer ID Application:' if distribution else 'Apple Development:'
identity = next(((digest, name) for digest, name in identities if name.startswith(prefix)), None)
if distribution and identity is None:
    raise SystemExit('Developer ID Application identity is required for distribution.')
settings = []
if identity:
    digest, name = identity
    settings.append('CODE_SIGN_IDENTITY=' + digest)
    team = re.search(r'\(([A-Z0-9]+)\)$', name)
    if team:
        settings.append('DEVELOPMENT_TEAM=' + team[1])
    print('Signing: Developer ID Application' if distribution else 'Signing: Apple Development', flush=True)
else:
    print('Signing: ad-hoc local development', flush=True)
feed = os.environ.get('TOK_UPDATE_FEED_URL')
if feed:
    from urllib.parse import urlparse
    parsed = urlparse(feed)
    if parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.scheme != 'https' or not parsed.hostname:
        raise SystemExit('Use a public HTTPS appcast URL without embedded credentials.')
    settings.append('TOK_UPDATE_FEED_URL=' + feed)
runner = os.path.join(os.getcwd(), 'Scripts', 'bounded_run.py')
os.execv(sys.executable, [sys.executable, runner, '--seconds', os.environ.get('TOK_BUILD_TIMEOUT_SECONDS', '120'), '--label', 'xcodebuild', '--', 'xcodebuild', *sys.argv[1:], *settings])
PY
