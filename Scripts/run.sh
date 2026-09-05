#!/bin/bash
set -euo pipefail
app="${1:?Pass the built Tok.app path}"
if pgrep -x Tok >/dev/null; then
    osascript -e 'tell application id "com.adhishthite.tok" to quit'
    for ((attempt=0; attempt<50; attempt++)); do
        pgrep -x Tok >/dev/null || break
        sleep 0.1
    done
    if pgrep -x Tok >/dev/null; then
        echo 'Tok has not quit. Close Tok before running again.' >&2
        exit 1
    fi
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
args=()
if [[ -f "$root/.env" ]]; then
    args+=(--config-file "$root/.env" --status-file "$root/build/runtime-status.json")
fi
if [[ "${TOK_SHOW_SETUP:-0}" == 1 ]]; then args+=(--show-setup); fi
open "$app" --args "${args[@]}"
sleep 2
if ! pgrep -x Tok >/dev/null; then
    echo 'Tok exited during startup. Check its DiagnosticReports crash log.' >&2
    exit 1
fi
echo 'Tok is running.'
