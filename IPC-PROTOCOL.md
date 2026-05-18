# Filesystem-IPC Protocol — Cowork ↔ Host Shell Bridge

**Status:** v0.3.0, fully tested in Cowork sandbox (7 test categories pass), shipped 2026-05-14.

## Prerequisite for sandboxed callers — the mount step

**Before any inbox write can succeed, the bridge folder must be in the caller's mount set.** Installing the bridge (running `bootstrap.ps1` on Windows or the equivalent shell installer on macOS/Linux) registers the host-side daemon and creates `<bridge_root>/ipc/inbox/` and `<bridge_root>/ipc/outbox/` on the host's filesystem — but those folders are *not* automatically reachable from inside a sandboxed agent runtime (Cowork's Linux sandbox is the canonical case). The sandbox can only see folders the user has selected when starting the session OR folders the agent has requested via `mcp__cowork__request_cowork_directory` and the user has approved. Without that mount, the agent's attempt to write a request JSON into the inbox returns "file not found" or "permission denied" — the bridge appears installed but is silently non-load-bearing.

**The fix is one MCP call.** After the install paste completes, the calling agent must call `mcp__cowork__request_cowork_directory(path=<bridge_root>)` (where `<bridge_root>` is `C:\dev\claude-code-bridge` on Windows or `~/dev/claude-code-bridge` on macOS/Linux). The user gets a one-click approval prompt; on approval, the inbox/outbox folders become readable and writable from the agent's session and every later host operation runs silently through this protocol. **Install + mount, not install alone.** Curricula that use this bridge (the Anchor curriculum, for one) should treat both as M0-blocking conditions before declaring the bridge operational.

## What this is

A way for a sandboxed Cowork session to run shell commands on the user's host machine without depending on Cowork's MCP/plugin registry (which doesn't currently accept user-built tools). Works by writing JSON files into `inbox/` and reading them back from `outbox/`.

## Architecture

```
┌─────────────────────────┐                ┌──────────────────────────────┐
│ Cowork session (sandbox)│                │ Host daemon (bridge.watcher) │
│                         │  write JSON →  │                              │
│ Write tool reaches      │ ──────────────►│ Scheduled Task at logon      │
│ C:\dev\* (trusted)      │   ipc/inbox/   │ Polls ipc/inbox/ every 100ms │
│                         │                │ Runs via bridge.shell.run    │
│ Read tool polls         │ ◄──────────────│ Writes result to ipc/outbox/ │
│ ipc/outbox/             │   ipc/outbox/  │                              │
└─────────────────────────┘                └──────────────────────────────┘
```

## File locations

- **Bridge root:** `C:\dev\claude-code-bridge\` (or wherever you've installed it)
- **Inbox:** `<bridge_root>/ipc/inbox/<uuid>.json` — Cowork writes here
- **Outbox:** `<bridge_root>/ipc/outbox/<uuid>.json` — daemon writes here
- **Log:** `<bridge_root>/logs/watcher.log` — daemon's append-only log

## Request schema (Cowork → daemon)

Write a file at `<bridge_root>/ipc/inbox/<uuid>.json` with JSON body:

```json
{
  "request_id": "<a uuid4 string>",        // required, also becomes the filename
  "command":    "<shell command string>",  // required
  "shell":      "powershell|pwsh|cmd|bash", // optional; OS default if absent
  "cwd":        "<absolute path>",         // optional working directory
  "timeout":    60.0,                      // optional, seconds; defaults to 60
  "allow_destructive": false,              // optional; default false (gate ON)
  "env":        { "KEY": "VALUE" }         // optional env-var merge
}
```

**Atomic write requirement:** write to `<uuid>.json.tmp` first, then rename to `<uuid>.json`. Otherwise the daemon may try to read a partial file. (The Python client and the install script's PowerShell self-test both do this.)

## Response schema (daemon → Cowork)

The daemon writes the result to `<bridge_root>/ipc/outbox/<uuid>.json` (same UUID) with JSON body:

```json
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
```

For a destructive-op block:

```json
{
  "exit_code":       -1,
  "stdout":          "",
  "stderr":          "",
  "blocked_by_gate": "destructive_op",
  "reason":          "rm -rf (recursive force-delete)",
  "permission_events": [
    {"type": "destructive_blocked", "reason": "rm -rf (recursive force-delete)", "snippet": "..."}
  ],
  "request_id":      "<echo of request_id>"
}
```

For a timeout: `exit_code: -9, timed_out: true, duration_ms: <approximately the timeout>`.

For admin-elevation detection (sudo, RunAs): the command runs as the daemon's user; an entry is added to `permission_events` flagging that elevation was requested.

## Cowork-side calling pattern (from a Cowork session)

The simplest pattern is to write the request JSON via the Write tool, then poll for the response:

```python
# Pseudocode for inside a Cowork session's bash sandbox:
import json, uuid, time, os

BRIDGE = r"C:\dev\claude-code-bridge"
req_id = str(uuid.uuid4())
req = {
    "request_id": req_id,
    "command": "echo hello",
    "shell": "powershell",
    "timeout": 10,
}

# Write atomically
tmp  = fr"{BRIDGE}\ipc\inbox\{req_id}.json.tmp"
final = fr"{BRIDGE}\ipc\inbox\{req_id}.json"
with open(tmp, "w") as f: json.dump(req, f)
os.replace(tmp, final)

# Poll outbox up to 90s
deadline = time.time() + 90
out_path = fr"{BRIDGE}\ipc\outbox\{req_id}.json"
while time.time() < deadline:
    if os.path.exists(out_path):
        with open(out_path) as f: result = json.load(f)
        os.unlink(out_path)
        break
    time.sleep(0.1)
```

A ready-made client is at `<bridge_root>/bridge/cowork_client.py` if your Cowork session can import it:

```python
from bridge.cowork_client import run_on_host
result = run_on_host("echo hello", shell="powershell", timeout=10)
print(result["stdout"])
```

For agents that can't import a custom module, the inline pattern above is enough — it's 15 lines of standard Python.

## Daemon lifecycle

- **Installation:** `install-watcher.ps1` (in the bridge root) registers a Windows Scheduled Task named `ClaudeCodeBridgeWatcher` that runs the daemon at user logon, hidden window, auto-restart on failure.
- **Auto-start:** at every user logon, no further intervention.
- **Manual control:**
  - Start now:    `Start-ScheduledTask -TaskName ClaudeCodeBridgeWatcher`
  - Stop:         `Stop-ScheduledTask  -TaskName ClaudeCodeBridgeWatcher`
  - Uninstall:    `Unregister-ScheduledTask -TaskName ClaudeCodeBridgeWatcher -Confirm:$false`
  - Check state:  `Get-ScheduledTaskInfo -TaskName ClaudeCodeBridgeWatcher`
  - Tail logs:    `Get-Content C:\dev\claude-code-bridge\logs\watcher.log -Wait -Tail 20`

## Permission gating (same as before)

The daemon uses `bridge.shell.run_command` which applies the same destructive-op blocklist and admin-elevation detection as the previous orchestrator. Defaults:

- Destructive operations (`rm -rf`, `Remove-Item -Recurse -Force`, `git push --force`, `Format-Volume`, etc.) — blocked unless caller passes `allow_destructive: true`.
- Admin elevation (`sudo`, `RunAs`, `pwsh -Verb RunAs`) — flagged in `permission_events`; executed (the OS will prompt the user via UAC/sudo).

## Cleanup behavior

- Outbox files older than 5 minutes are auto-deleted by the daemon.
- Inbox files older than 10 minutes (orphans from crashed clients) are deleted on the next cleanup pass.
- Stale `.tmp` files older than 60 seconds (from interrupted atomic writes) are deleted.

## Cross-platform

The daemon itself is pure Python — runs on Windows, macOS, and Linux. Only `bridge.shell` needs to know about the local shell (PowerShell on Windows, bash elsewhere). For curriculum-student distribution:

- **Windows:** Scheduled Task (handled by `install-watcher.ps1`).
- **macOS:** LaunchAgent plist (recipe: write `~/Library/LaunchAgents/com.claudecodebridge.watcher.plist` that runs `/path/to/python -m bridge.watcher`, then `launchctl load -w` it).
- **Linux:** systemd user unit (recipe: write `~/.config/systemd/user/claude-code-bridge.service`, then `systemctl --user enable --now claude-code-bridge`).

These cross-platform installers can be written as needed; today's `install-watcher.ps1` covers Windows.

## What this fixes vs the Cowork-MCP path that didn't work

The MCPB Desktop Extension path made the bridge available to Claude Desktop's main chat but not to Cowork sessions, because in the current Cowork build (1.7196.0) `LocalAgentModeSessionManager` ignores user-installed MCP servers — it only loads the eleven first-party Cowork MCPs plus plugins from the Anthropic-curated marketplace. The filesystem-IPC path entirely sidesteps Cowork's MCP registry: it uses only file I/O on a trusted folder (`C:\dev\*`), which Cowork's Write/Read tools support natively. Works regardless of Anthropic's plugin roadmap.

## When this becomes obsolete

When Cowork adds support for user-installed MCP servers (which the Cowork team has signaled is coming), the bridge's existing MCP server (`bridge.mcp_server`) can be re-enabled and Cowork will call it directly. The filesystem-IPC layer becomes a fallback for older Cowork versions. The bridge's core (`bridge.shell.run_command` + `bridge.permissions`) stays the same — only the transport changes.
