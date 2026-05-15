# claude-code-bridge

**A thin MCP server that lets a sandboxed agent (Cowork, Cursor, etc.) run shell commands on the user's host machine.**

The calling agent sends a shell command string over MCP; the bridge runs it via `subprocess` on the host (PowerShell, cmd, or bash) with permission gating; the structured result (stdout, stderr, exit code, duration, permission events) goes back to the caller. No second LLM in the loop — the calling agent decides what to run and how to interpret the output.

**Status:** v0.2.0, post-pivot. Verified working in Cowork sandbox; pending Cowork plugin-manifest wire-up for universal availability.

## Quick start (first-time install on a Windows 11 PC)

**Easiest:** download **[`Install-Claude-Code-Bridge.bat`](https://raw.githubusercontent.com/johncliechty/claude-code-bridge/master/Install-Claude-Code-Bridge.bat)** (right-click → "Save link as…"), double-click it, press Y to confirm. The installer auto-detects an existing Python (no reinstall if found), installs Python 3.13 via winget if missing, clones the repo, sets up the venv, registers the IPC daemon Scheduled Task, and self-tests end-to-end. No PowerShell commands to copy. See [`M0.md`](./M0.md) for the full walkthrough and troubleshooting.

**From PowerShell (two commands):**

```powershell
git clone https://github.com/johncliechty/claude-code-bridge C:\dev\claude-code-bridge
powershell -NoProfile -ExecutionPolicy Bypass -File C:\dev\claude-code-bridge\bootstrap.ps1
```

`bootstrap.ps1` is idempotent and handles Python detection / install, git detection / install, repo clone-or-pull, venv setup, and the Scheduled Task registration. It runs `install-watcher.ps1` at the end which self-tests the daemon round-trip.

## How it works

The bridge exposes one MCP tool, `run_command`, with the following surface:

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `command` | string | (required) | The shell command to execute. |
| `cwd` | string | bridge process cwd | Absolute working directory. |
| `shell` | enum | `powershell` on Windows, `bash` elsewhere | One of `powershell`, `pwsh`, `cmd`, `bash`. |
| `timeout` | number | 60 | Seconds before the command is killed. |
| `allow_destructive` | bool | false | Bypass the destructive-op gate. |
| `env` | object | none | Env vars to add/override. |

Returns `{exit_code, stdout, stderr, duration_ms, command, shell, cwd, timed_out, permission_events}`.

## Permission gating

Two layers of safety, both implemented in `bridge/permissions.py` and applied to every command:

- **Destructive-op blocklist.** `rm -rf`, `Remove-Item -Recurse -Force`, `git push --force`, `git reset --hard`, `git branch -D`, `Format-Volume`, `format <drive>:`, `shutdown`, `Restart-Computer`, `regedit`, `diskpart`, writes to `~/.ssh`. Blocked by default; callers can pass `allow_destructive=true` to bypass with intent.
- **Admin-elevation detection.** `Start-Process -Verb RunAs`, `sudo`, `runas`, `pwsh -Verb RunAs`. Surfaced as a `permission_events` entry but not blocked — the OS handles the actual elevation prompt.

## Manual install (for developers)

If you'd rather not use `bootstrap.ps1`, from the repo root:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -e .
```

This installs `bridge-mcp` (the MCP server script) and `bridge-orchestrator` (the legacy CLI for the optional claude-agent-sdk path). To pick up the optional delegation extras:

```powershell
pip install -e ".[claude-code-delegation]"
```

To register the IPC daemon Scheduled Task after the package install:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install-watcher.ps1
```

`install-watcher.ps1` resolves Python from known install paths (or via `py -3` / PATH) and offers to install via winget if nothing is found. Pass `-PythonPath <abs-path>` if you want to skip discovery and force a specific Python.

## Usage

The MCP server is invoked over stdio by an MCP client (Cowork's plugin loader, Claude Desktop, or a hand-rolled MCP client):

```powershell
python -m bridge.mcp_server
# or
bridge-mcp
```

For CLI testing outside of an MCP client, the underlying `run_command` is also reachable via the legacy `bridge-orchestrator` script.

## Cowork integration

The bridge becomes universally callable from any Cowork session once registered in Cowork's plugin manifest. See `PHASE-4-ARCHITECTURE-OPTIONS.md` for the wiring plan. The architecturally-correct route is a Cowork plugin with an `mcpServers` entry; the filesystem-IPC fallback is documented as a backup.

## What changed in v0.2.0

v0.1.0 used `claude-agent-sdk` to invoke Claude Code as an agentic-loop intermediary on the host. v0.2.0 replaces that with direct shell execution — same MCP server surface, completely different internals. The Claude Code SDK is now an optional dependency for the legacy `bridge-orchestrator` CLI only; the MCP path (`bridge-mcp`) has no LLM in the loop.

Rationale: the sandboxed agent already has its own LLM (Cowork's agent); routing through a second LLM (Claude Code on the host) added tokens, latency, and tangent risk without adding decision-making the caller couldn't do itself. Deterministic shell access turns out to be enough for nearly every host operation a Cowork session needs to perform.

## Design docs

- `M0.md` — novice-friendly install walkthrough.
- `OVERNIGHT-NOTES.md` — handoff notes between sessions.
- `PHASE-4-ARCHITECTURE-OPTIONS.md` — open question on Cowork plugin manifest schema.
- `C:\dev\Teaching\USE-CLAUDE-CODE-TOOL-PLAN-2026-05-13.md` — original build plan (predates the v0.2.0 pivot; treat as historical context).
