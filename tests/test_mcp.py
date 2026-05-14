"""Smoke test for the v0.2.0 MCP server: verify it exposes run_command with the right schema."""
import json

import pytest


@pytest.mark.asyncio
async def test_list_tools_exposes_run_command():
    """The server should expose exactly one tool: run_command."""
    from bridge.mcp_server import list_tools
    tools = await list_tools()
    assert len(tools) == 1
    t = tools[0]
    assert t.name == "run_command"
    schema = t.inputSchema
    # Only `command` is strictly required; cwd/shell/timeout/etc. are optional.
    assert "command" in schema["required"]
    props = schema["properties"]
    assert "command" in props
    assert "cwd" in props
    assert "shell" in props
    assert "timeout" in props
    assert "allow_destructive" in props
    assert "env" in props
    # shell enum should include powershell, pwsh, cmd, bash
    assert set(props["shell"]["enum"]) >= {"powershell", "pwsh", "cmd", "bash"}


@pytest.mark.asyncio
async def test_call_tool_rejects_unknown():
    """Calling an unknown tool returns an error JSON, not an exception."""
    from bridge.mcp_server import call_tool
    result = await call_tool("not_a_real_tool", {})
    assert len(result) == 1
    body = json.loads(result[0].text)
    assert "error" in body


@pytest.mark.asyncio
async def test_call_tool_rejects_missing_command():
    """Calling run_command without `command` returns an error."""
    from bridge.mcp_server import call_tool
    result = await call_tool("run_command", {})
    assert len(result) == 1
    body = json.loads(result[0].text)
    assert "error" in body
    assert "command" in body["error"]


@pytest.mark.asyncio
async def test_call_tool_blocks_destructive_command():
    """End-to-end via the MCP call_tool entry: destructive command is blocked at the gate."""
    from bridge.mcp_server import call_tool
    result = await call_tool("run_command", {"command": "rm -rf /tmp", "shell": "bash"})
    assert len(result) == 1
    body = json.loads(result[0].text)
    assert body.get("blocked_by_gate") == "destructive_op"
    assert body["exit_code"] == -1
