# Bridge Build — End-of-Session Notes (2026-05-14)

**Status:** Phases 0-4 complete. Bridge code v0.2.0 written, tested, registered with Claude Desktop's MCP loader. **One restart required to activate.**

## What's done

- **Phase 0 — environment validation:** PASS
- **Phase 1 — PoC orchestrator + smoke test:** PASS (18/18 tests in overnight run)
- **Phase 2 — permission gating:** PASS (destructive blocklist + admin-elevation detection)
- **Phase 3 — MCP server wrapper:** PASS (stdio transport, structured tool schema)
- **Architecture pivot — v0.2.0:** Cowork now calls shell directly via `run_command`. The Claude-Code-SDK indirection has been removed from the MCP surface. The legacy `delegate_to_claude_code` orchestrator is retained in `bridge/orchestrator.py` and accessible via the `bridge-orchestrator` CLI script for the rare case where LLM-driven host work is wanted; `claude-agent-sdk` is now an optional dependency.
- **Phase 4 — Cowork integration:** Registered in `C:\Users\john\AppData\Roaming\Claude\claude_desktop_config.json` under `mcpServers`. Claude Desktop bridges configured MCPs into Cowork's sandboxed VM automatically (the SDK Bridge mechanism). Original config backed up to `outputs/claude_desktop_config.json.backup-2026-05-14`.

## What John needs to do

**Restart Claude Desktop.** Close the app entirely (right-click tray icon → Quit on Windows, or close all windows) and reopen it. On startup, the new `mcpServers.claude-code-bridge` entry causes the desktop app to spawn `python -m bridge.mcp_server` in `C:\dev\claude-code-bridge` and proxy its stdio MCP tools into every Cowork session.

After restart, in a fresh Cowork session, the tool should appear as `mcp__claude-code-bridge__run_command` (or similar — exact naming depends on Cowork's MCP namespacing). Quick verification: ask Cowork to "run `echo hello` via PowerShell on my host" — it should call `run_command`, return `{exit_code: 0, stdout: "hello\r\n", ...}`, and surface the output in chat.

## What it does

The `run_command` MCP tool takes a shell command string and runs it on the host. Parameters:

| Param | Default | Notes |
|---|---|---|
| `command` | (required) | The shell command. |
| `cwd` | bridge cwd | Working directory. |
| `shell` | `powershell` on Windows | One of `powershell`, `pwsh`, `cmd`, `bash`. |
| `timeout` | 60 | Seconds before kill. |
| `allow_destructive` | false | Bypass the rm-rf / force-push gate. |
| `env` | none | Add/override env vars. |

Returns `{exit_code, stdout, stderr, duration_ms, command, shell, cwd, timed_out, permission_events}`. Destructive operations (rm -rf, Remove-Item -Recurse -Force, git push --force, etc.) are blocked unless `allow_destructive=true`. Admin-elevation requests (sudo, RunAs) are flagged in `permission_events` but executed — the OS handles the actual prompt.

## File map

- `bridge/permissions.py` — destructive-op blocklist + admin-elevation regex patterns.
- `bridge/shell.py` — the `run_command` async function (subprocess.create_subprocess_exec under the hood; cross-platform; structured output).
- `bridge/mcp_server.py` — MCP stdio server exposing `run_command`.
- `bridge/orchestrator.py` — legacy claude-agent-sdk path (still importable; not in MCP surface).
- `tests/` — pytest suite covering permissions, shell exec, MCP schema. All 18 tests passed in overnight run.
- `.claude-plugin/plugin.json` — Cowork/Claude Code plugin manifest (alternative install path via marketplace).
- `pyproject.toml` — v0.2.0. `claude-agent-sdk` moved to optional `[claude-code-delegation]` extra.
- `run-overnight.ps1` — unattended pip install + pytest + commit script. Use `Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\dev\claude-code-bridge\run-overnight.ps1' -WindowStyle Hidden` to re-run.

## Git state

The v0.2.0 changes are uncommitted on disk. The `.git/config` has been updated with `user.name = John Liechty` and `user.email = john.liechty@gmail.com` so future commits work. Next overnight run will commit automatically, or John can `cd C:\dev\claude-code-bridge && git add . && git commit -m "v0.2.0 ..."` whenever convenient.

## What's queued behind verification

After the bridge is confirmed working in Cowork:

1. **Curriculum-builder skill revision** (Part 4 of the original Anchor pilot plan): Add Mode B (Interactive Lesson Designer) and Mode C (Coach-Behavior Auditor) to the existing `curriculum-builder` skill. ~60-90 min.
2. **M3-M7 rubric sweep:** Extend the engagement-gated pattern landed for M1/M2 into M3 through M7 rubrics. ~20-30 min.
3. **Update the `use-claude-code` skill** to defer to the bridge when available, fall back to the paste-once handshake only when the bridge isn't reachable. Make the bridge the primary path, paste-once the legacy backup. ~15 min.
4. **Drop the `delegate_to_claude_code` legacy code** from the bridge repo once the shell-direct path has been live for a couple of weeks without regression. Cleanup task; not urgent.
