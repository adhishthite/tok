#!/bin/bash
set -euo pipefail
app="${1:?Pass the built Tok.app path}"
if pgrep -x Tok >/dev/null; then
    python3 "$(dirname "$0")/bounded_run.py" --seconds 10 --label quit -- osascript -e 'tell application id "com.adhishthite.tok" to quit'
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
if [[ "${TOK_PROBE_MIC:-0}" == 1 ]]; then args+=(--probe-microphone); fi
if [[ "${TOK_PREPARE_MIC:-0}" == 1 ]]; then args+=(--prepare-microphone); fi
if [[ "${TOK_PROFILE_MIC:-0}" == 1 ]]; then
    trace="$root/build/microphone-startup-$(date +%Y%m%d-%H%M%S).trace"
    python3 "$root/Scripts/bounded_run.py" --seconds 10 --label launch -- \
        open "$app" --args "${args[@]}" --probe-microphone-delayed
    sleep 1
    pid="$(pgrep -x Tok)"
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        echo 'Expected exactly one Tok process for profiling.' >&2
        exit 1
    fi
    python3 "$root/Scripts/bounded_run.py" --seconds 45 --label microphone-profile -- \
        xcrun xctrace record --template 'Time Profiler' --time-limit 12s \
        --output "$trace" --no-prompt --attach "$pid"
    echo "Profile saved: $trace"
    exit 0
fi
open "$app" --args "${args[@]}"
sleep 2
if ! pgrep -x Tok >/dev/null; then
    echo 'Tok exited during startup. Check its DiagnosticReports crash log.' >&2
    exit 1
fi
echo 'Tok is running.'
