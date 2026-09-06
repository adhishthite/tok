#!/usr/bin/env python3
"""Run a command with an explicit, incrementally extendable deadline."""

import argparse
import contextlib
import fcntl
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def interrupt_group(process):
    """Allow the whole process group to exit, then kill any remaining members."""
    try:
        os.killpg(process.pid, signal.SIGINT)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        process.poll()  # Reap the leader without mistaking it for the whole group.
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.05)
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGKILL)
    process.wait(timeout=5)


parser = argparse.ArgumentParser()
parser.add_argument("--seconds", type=int, default=120)
parser.add_argument("--extend", type=Path)
parser.add_argument("--label", default="command")
parser.add_argument("command", nargs=argparse.REMAINDER)
args = parser.parse_args()

if args.extend:
    if not 1 <= args.seconds <= 60:
        parser.error("Extend by 1 to 60 seconds after inspecting progress.")
    with args.extend.open("r+") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        state = json.load(handle)
        if state.get("state") != "running" or time.monotonic() >= state["deadline"]:
            parser.error("This deadline is no longer active.")
        try:
            os.kill(state["pid"], 0)
        except ProcessLookupError:
            parser.error("The command process is no longer live.")
        state["deadline"] += args.seconds
        handle.seek(0)
        json.dump(state, handle)
        handle.truncate()
        handle.flush()
    print(f"Extended {state['label']} by {args.seconds} seconds.", flush=True)
    sys.exit(0)

command = args.command[1:] if args.command[:1] == ["--"] else args.command
if not command or args.seconds < 1:
    parser.error("Provide a positive time limit and a command after --.")
process = subprocess.Popen(command, start_new_session=True)
descriptor, name = tempfile.mkstemp(prefix="tok-deadline-", suffix=".json")
os.close(descriptor)
control = Path(name)
state = {
    "label": args.label,
    "pid": process.pid,
    "state": "running",
    "deadline": time.monotonic() + args.seconds,
}
control.write_text(json.dumps(state))
print(
    f"Deadline: {args.seconds}s; process: {process.pid}; control: {control}", flush=True
)
timed_out = False
try:
    while process.poll() is None:
        with control.open("r+") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            current = json.load(handle)
            expired = time.monotonic() >= current["deadline"]
            if expired:
                current["state"] = "expiring"
                handle.seek(0)
                json.dump(current, handle)
                handle.truncate()
                handle.flush()
        if expired:
            timed_out = True
            print(
                f"{args.label}: time limit reached; interrupting the command.",
                flush=True,
            )
            interrupt_group(process)
            break
        time.sleep(0.2)
except KeyboardInterrupt:
    interrupt_group(process)
finally:
    # A broken control file must not leave an unbounded child behind.
    if process.poll() is None:
        interrupt_group(process)
    state["state"] = "timed_out" if timed_out else "finished"
    state["exit_code"] = process.returncode
    with control.open("r+") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        handle.seek(0)
        json.dump(state, handle)
        handle.truncate()
sys.exit(124 if timed_out else process.returncode or 0)
