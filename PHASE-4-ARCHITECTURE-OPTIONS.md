# Phase 4 — Architecture options for making the bridge Cowork-callable

**Date written:** 2026-05-13 (evening, end of session)
**Status:** Open question. Phases 1, 2, and 3 are implemented and on disk; Phase 4 (the *"wire it into Cowork so a sandboxed session can call `delegate_to_claude_code` without a paste"* piece) is gated on a question we hadn't anticipated and didn't resolve before bed: **Cowork does not appear to support local stdio MCP servers via a documented configuration path.** The build plan assumed it did (citing `claude_desktop_config.json` as the MCP-config file), but inspection of John's actual `C:\Users\john\AppData\Roaming\Claude\claude_desktop_config.json` shows no `mcpServers` section and a different structure than Claude Desktop's. Cowork's MCP integration in this research-preview appears to expose only:

- First-party tools (`mcp__workspace__bash`, `mcp__cowork__*`, `mcp__plugins__*`, etc.).
- Remote/HTTP MCP connectors via the curated MCP registry (Contentsquare, Datadog, etc. — all backed by hosted URLs).
- Plugins installed via the Cowork plugin marketplace (`.claude-plugin/marketplace.json` + per-plugin `plugin.json`). Inspection of the existing `use-claude-code` and `anchor-coach` plugins shows the manifests describe skills but **do not appear to surface a way to register an MCP server**.

In other words, the part we built (a stdio MCP server using the official `mcp` SDK) doesn't have a clean installation slot in Cowork's current model.

## What's already done

- Phase 1: PoC orchestrator (`bridge/orchestrator.py`) — smoke-tested PASS on host earlier this session.
- Phase 2: Permission gating (`bridge/permissions.py` + integration into orchestrator) — 15/15 permission unit tests PASS in the Cowork sandbox.
- Phase 3: MCP server (`bridge/mcp_server.py`) using the official `mcp` Python SDK, stdio transport. Code is structurally complete; verification of the SDK and stdio loop happens in the overnight test run.
- Overnight: `run-overnight.ps1` validates pip install + full pytest suite + git commit.

## Options, with honest pros/cons

### Option A — Package the bridge as a Cowork plugin

Per the existing `.claude-plugin/` pattern in `C:\dev\Project-Manager\plugins\*\.claude-plugin\plugin.json`. Build a `claude-code-bridge` plugin with a manifest that registers the MCP server, and install it via Cowork's plugin marketplace mechanism (or sideload from a local path if Cowork supports that).

**Pros.** Architecturally correct for Cowork's model. Aligns with how `anchor-coach`, `project-manager`, and `use-claude-code` are distributed. Long-term sustainable.

**Cons.** Cowork's plugin manifest format as I've inspected it (skill-only plugins) does not appear to surface an MCP-server registration field. I need to either find documentation that contradicts that observation or experiment to find the right manifest shape. **This is the load-bearing unknown.** Possible that Cowork plugins *can* embed MCP servers but the documentation hasn't surfaced it in any of the existing example plugins.

**Next step if chosen:** Find official Cowork docs on plugin MCP-server registration, OR ask the Cowork team / read the Cowork app source if accessible, OR find a public plugin in the marketplace that includes an MCP server and study its manifest. Once the right schema is known, write the manifest and side-load.

### Option B — Run the bridge as an HTTP MCP server and submit to the Cowork curated registry

Refactor the stdio transport in `bridge/mcp_server.py` to an HTTP transport (the `mcp` SDK supports both). Self-host the server at a known port on localhost. Submit to Cowork's curated MCP registry per Q5 of the build plan.

**Pros.** Aligns with how connectors in the registry actually work (they're all HTTP-backed). Battle-tested deployment path. Public usefulness — other Cowork users could install.

**Cons.** Bigger refactor (transport change + auth layer + persistent process management). Submission and review process for the registry will take days to weeks. The HTTP server has to run as a service on John's host, requiring either a Windows Task Scheduler entry, a systemd-style service wrapper, or a persistent terminal window. Adds operational complexity.

**Next step if chosen:** Refactor mcp_server.py to use HTTP transport (mcp.server.streamable_http or similar). Add an auth shim (likely a local-only token). Wrap as a Windows Service or a Scheduled Task. Document install. Submit to registry.

### Option C — Filesystem IPC workaround (Cowork drops requests in a mounted folder, host daemon executes)

A Python daemon on the host watches a known directory for `<uuid>.json` delegation-request files. When one appears, it calls `bridge.orchestrator.delegate()` and writes the result to `<uuid>.result.json` in an outbox folder. A small helper module on the Cowork side writes requests and polls for results.

**Pros.** Sidesteps Cowork's MCP architecture entirely. Works regardless of what Cowork supports. Reuses everything we've built. Could be live tomorrow.

**Cons.** It's a workaround, not the architecturally correct path. Polling adds latency (~100-500ms per call). Requires a persistent daemon on the host (Task Scheduler or a manual `python bridge/watcher.py`). The Cowork sandbox needs the IPC folder mounted — and `C:\dev\claude-code-bridge` isn't mounted today (mounting requires a Cowork UI action). We could put the IPC folder under one of the existing mounts (e.g., `C:\dev\Agentic-Home\claude-code-bridge-ipc\`) at the cost of cross-tree pollution.

**Next step if chosen:** Pick an IPC folder under a mounted tree. Write the watcher daemon (`bridge/watcher.py`) and a Cowork-side helper. Set up Task Scheduler to run the watcher on login. Document the contract.

### Option D — Accept bridge as host-CLI-only for now

Use `bridge-orchestrator` and `bridge-mcp` as host CLI tools that John (or Claude Code on the host) can invoke directly. The Cowork-to-host paste loop continues for sessions. Revisit Phase 4 once Cowork's MCP support story matures, OR once we choose A/B/C above as a deliberate sprint.

**Pros.** Zero additional work tonight. Bridge is still useful — Claude Code on the host can invoke it programmatically; John can run it from PowerShell.

**Cons.** Doesn't deliver "stop pasting" for Cowork sessions. The original goal isn't met.

## Recommendation for tomorrow morning

**Pursue Option A first** with a 30-60 minute time-box on the documentation hunt. Specifically:

1. Web-search for "Cowork plugin MCP server registration" and "Anthropic Claude Code plugin mcpServers" — look for an official doc or example plugin showing the schema.
2. Read `C:\dev\Project-Manager\plugins\use-claude-code\.claude-plugin\plugin.json` and see if there's a hidden field or convention I missed.
3. Inspect any installed Cowork plugin in `%APPDATA%\Claude\` that DOES include an MCP server — those would give us the live schema.

If after 30-60 minutes we don't find the answer for A, fall back to **Option C (filesystem IPC)** as a working-but-not-pretty solution. C can ship in a session; A might take longer if the docs are scarce.

**Option B is the long-term right answer** if we want this on the public Cowork registry, but it's not the right "tonight or tomorrow" answer.

## What John reads tomorrow

1. `C:\dev\claude-code-bridge\STATUS.json` — overnight build result (success/fail/partial; per-step detail).
2. `C:\dev\claude-code-bridge\logs\overnight-*.log` — full output of pip install + pytest + git commit.
3. This file (`PHASE-4-ARCHITECTURE-OPTIONS.md`) — the decision he needs to make to unblock Phase 4.

Decision required: A vs B vs C vs D. Default to A with the 30-60 min time-box; fall back to C.
