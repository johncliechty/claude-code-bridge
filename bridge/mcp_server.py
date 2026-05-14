"""v0.2.0 MCP server: expose run_command as an MCP tool.

The post-pivot architecture: Cowork (or any sandboxed agent) calls this server's
`run_command` tool over MCP stdio; the server runs the command on the host via
subprocess (PowerShell, cmd, or bash) with permission gating; the structured
result (stdout, stderr, exit_code, duration, timed_out, permission_events) goes
back to the caller. No second LLM in the loop — Cowork decides what to run and
how to interpret the output.

The legacy `delegate_to_claude_code` tool (which used claude-agent-sdk to run an
agentic loop on Claude Code) is intentionally NOT exposed here. The orchestrator
code remains in `bridge/orchestrator.py` for CLI use via `bridge-orchestrator`,
but the MCP surface is the shell-direct tool.

Run with: python -m bridge.mcp_server
or via the `bridge-mcp` script entry point after `pip install -e .`.
"""
import asyncio
import json

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent

from bridge.shell import (
    run_command,
    DEFAULT_TIMEOUT_SECONDS,
    SUPPORTED_SHELLS,
    _default_shell,
)


app = Server("claude-code-bridge")


@app.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="run_command",
            description=(
                "Run a shell command on the user's host machine and return structured output. "
                "Use this when you (the calling agent) need to execute commands the user's "
                "machine — installing software with winget/brew/apt, running git operations "
                "with host credentials, executing PowerShell or cmd scripts, anything that "
                "requires the real host environment. The default shell is PowerShell on Windows "
                "(invoked with -NoProfile -ExecutionPolicy Bypass) and bash on Mac/Linux; you "
                "can pass shell='cmd' for the Windows Command Prompt when you want simpler/faster "
                "text-only execution. Destructive operations (rm -rf, Remove-Item -Recurse -Force, "
                "git push --force, etc.) are blocked by default; pass allow_destructive=true to "
                "bypass with intent. Admin elevation requests (sudo, RunAs) are flagged in the "
                "result but executed — the OS will prompt as appropriate."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": (
                            "The shell command to execute. One-liners and multi-statement scripts "
                            "are both supported (semicolons in PowerShell; && / || in bash; & in cmd). "
                            "For long scripts, write to a file first and execute it."
                        ),
                    },
                    "cwd": {
                        "type": "string",
                        "description": (
                            "Working directory for the command (absolute path). Optional; defaults to "
                            "the bridge process's cwd. Most callers should set this to the user's "
                            "project folder."
                        ),
                    },
                    "shell": {
                        "type": "string",
                        "enum": list(SUPPORTED_SHELLS),
                        "description": (
                            f"Which shell to use. Defaults to {_default_shell()!r} for this OS. "
                            "Options: 'powershell' (Windows PS 5+, default), 'pwsh' (PowerShell 7+ "
                            "if installed), 'cmd' (Windows Command Prompt, faster startup, text-only), "
                            "'bash' (Mac/Linux/Git Bash on Windows)."
                        ),
                    },
                    "timeout": {
                        "type": "number",
                        "description": (
                            f"Maximum seconds to wait for the command to finish. Defaults to "
                            f"{DEFAULT_TIMEOUT_SECONDS}. If the command runs longer, it is killed and "
                            "timed_out=true is set in the result."
                        ),
                        "default": DEFAULT_TIMEOUT_SECONDS,
                    },
                    "allow_destructive": {
                        "type": "boolean",
                        "description": (
                            "Set to true to bypass the destructive-op gate. Use only when the destructive "
                            "operation is genuinely intentional and the caller has accepted the risk. "
                            "Defaults to false."
                        ),
                        "default": False,
                    },
                    "env": {
                        "type": "object",
                        "description": (
                            "Optional environment variables to add or override for this command. "
                            "Keys and values are strings. The host's existing env is inherited; "
                            "entries here merge on top."
                        ),
                        "additionalProperties": {"type": "string"},
                    },
                },
                "required": ["command"],
            },
        )
    ]


@app.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    if name != "run_command":
        return [TextContent(type="text", text=json.dumps({"error": f"unknown tool: {name}"}))]

    command = arguments.get("command")
    if not command:
        return [TextContent(type="text", text=json.dumps({"error": "command is required"}))]

    # Normalise env dict — MCP clients sometimes send None or non-string values.
    env = arguments.get("env")
    if env is not None and not isinstance(env, dict):
        env = None
    if isinstance(env, dict):
        env = {str(k): str(v) for k, v in env.items()}

    result = await run_command(
        command=command,
        cwd=arguments.get("cwd"),
        shell=arguments.get("shell"),
        timeout=arguments.get("timeout", DEFAULT_TIMEOUT_SECONDS),
        allow_destructive=arguments.get("allow_destructive", False),
        env=env,
    )

    return [TextContent(type="text", text=json.dumps(result, indent=2, default=str))]


async def _main() -> None:
    async with stdio_server() as (read_stream, write_stream):
        await app.run(read_stream, write_stream, app.create_initialization_options())


def cli() -> None:
    """Synchronous wrapper for the `bridge-mcp` script entry point."""
    asyncio.run(_main())


if __name__ == "__main__":
    cli()
