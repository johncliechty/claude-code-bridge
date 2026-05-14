"""Cowork-side client for the filesystem-IPC bridge.

This module is for sandboxed agent runtimes (Cowork) that need to execute
shell commands on the user's host. It writes a JSON request to the bridge's
ipc/inbox/ folder and polls ipc/outbox/ for the matching response.

Usage from a Cowork session:

    # Option A — Python import (if the bridge folder is on sys.path or
    # this file has been copied to a mounted path):
    from bridge.cowork_client import run_on_host
    result = run_on_host("echo hello", shell="powershell")
    print(result["stdout"])

    # Option B — inline (no import needed). Just emit JSON to inbox/<uuid>.json
    # via your runtime's file-write tool, then poll outbox/<uuid>.json with read.
    # See the inline-protocol section below for the exact schema.

Protocol (no library required):

  Request (Cowork → daemon, file: <bridge_root>/ipc/inbox/<uuid>.json):
    {
      "request_id": "<uuid>",
      "command":   "<shell command string>",      // required
      "shell":     "powershell|pwsh|cmd|bash",    // optional; OS default if absent
      "cwd":       "<absolute path>",             // optional
      "timeout":   60.0,                          // optional, seconds
      "allow_destructive": false,                 // optional; default false (gate ON)
      "env":       { "KEY": "VALUE" }             // optional env-var merge
    }

  Response (daemon → Cowork, file: <bridge_root>/ipc/outbox/<uuid>.json):
    {
      "exit_code":         0,
      "stdout":            "<text>",
      "stderr":            "<text>",
      "duration_ms":       12.3,
      "command":           "<echo of input>",
      "shell":             "<resolved>",
      "cwd":               "<resolved>",
      "timed_out":         false,
      "permission_events": [],
      "request_id":        "<echo of request_id>"
    }

  On a destructive-op block, the response has:
    {
      "exit_code": -1,
      "blocked_by_gate": "destructive_op",
      "reason": "<human-readable>",
      ...
    }

The daemon also writes .tmp files atomically (write → rename) so partial reads
never happen. The daemon auto-cleans outbox files older than 5 minutes.
"""
from __future__ import annotations

import json
import os
import time
import uuid
from pathlib import Path
from typing import Optional

# Default bridge root on John's Windows machine; override via env var
# BRIDGE_IPC_ROOT for portability.
DEFAULT_BRIDGE_ROOT = Path(os.environ.get("BRIDGE_IPC_ROOT", r"C:\dev\claude-code-bridge"))


def run_on_host(
    command: str,
    *,
    shell: Optional[str] = None,
    cwd: Optional[str] = None,
    timeout: float = 60.0,
    allow_destructive: bool = False,
    env: Optional[dict] = None,
    bridge_root: Optional[Path] = None,
    poll_interval: float = 0.1,
    max_wait_seconds: float = 90.0,
) -> dict:
    """Submit a shell command to the host daemon and return the result.

    Blocks until the daemon writes a response file or max_wait_seconds elapses.

    Raises TimeoutError if no response within max_wait_seconds.
    Raises FileNotFoundError if the bridge IPC folders don't exist (daemon not installed).
    """
    root = bridge_root or DEFAULT_BRIDGE_ROOT
    inbox = root / "ipc" / "inbox"
    outbox = root / "ipc" / "outbox"

    if not inbox.exists() or not outbox.exists():
        raise FileNotFoundError(
            f"Bridge IPC folders not found at {root}/ipc/. "
            "Install and start the watcher daemon first (see install-watcher.ps1)."
        )

    request_id = str(uuid.uuid4())
    request = {
        "request_id": request_id,
        "command": command,
        "shell": shell,
        "cwd": cwd,
        "timeout": timeout,
        "allow_destructive": allow_destructive,
        "env": env,
    }
    # Drop keys with None values so the daemon uses its defaults
    request = {k: v for k, v in request.items() if v is not None}

    req_path = inbox / f"{request_id}.json"
    out_path = outbox / f"{request_id}.json"

    # Atomic write
    tmp = req_path.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(request, f)
    tmp.replace(req_path)

    # Poll for response
    deadline = time.time() + max_wait_seconds
    while time.time() < deadline:
        if out_path.exists():
            try:
                with open(out_path, "r", encoding="utf-8") as f:
                    result = json.load(f)
                # Best-effort cleanup; daemon also auto-cleans after TTL
                try:
                    out_path.unlink()
                except OSError:
                    pass
                return result
            except (json.JSONDecodeError, OSError):
                # File might be mid-write; wait a tick
                time.sleep(0.05)
                continue
        time.sleep(poll_interval)

    raise TimeoutError(
        f"No response from bridge daemon within {max_wait_seconds}s for request {request_id}. "
        f"Check that the watcher is running (logs at {root}/logs/watcher.log)."
    )


if __name__ == "__main__":
    # Quick smoke test from CLI
    import sys
    cmd = " ".join(sys.argv[1:]) or "echo hello-from-cowork-client"
    r = run_on_host(cmd)
    print(json.dumps(r, indent=2, default=str))
