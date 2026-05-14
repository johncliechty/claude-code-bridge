"""v0.1.0 orchestrator: invoke Claude Code via claude-agent-sdk with permission gating.

Phase 1 (v0.0.1) gave us the bare invocation + cost capture.
Phase 2 (v0.1.0) adds:
- Pre-prompt destructive-op validation
- Runtime tool-call inspection for destructive ops and admin elevation
- Flat cost cap (tiered checkpoints come in v0.2.0 per build plan Q4)
- Structured result with permission_events log

The delegate() function is the single entry point. MCP server (Phase 3) wraps it.
"""
import asyncio
import argparse
import json
import os
import sys
from pathlib import Path
from typing import Optional

from dotenv import load_dotenv

from bridge.permissions import is_destructive, requires_admin, validate_prompt


# Flat cost cap for a single delegation. Tiered checkpoints (33%/66%/100% with
# adaptive progress review) land in v0.2.0 per the build plan §3.7.
DEFAULT_COST_CAP_USD = 0.30


def load_api_key() -> Optional[str]:
    """Load ANTHROPIC_API_KEY from .env files in priority order.

    1. Already-set env var: use as-is.
    2. bridge-local .env (next to the package root): load and use.
    3. C:/dev/Agentic-Home/.env (John's existing workspace .env): load and use.

    Returns the source identifier ('<env>' or a path) if a key was found, else None.
    """
    if os.environ.get("ANTHROPIC_API_KEY"):
        return "<env>"
    bridge_root = Path(__file__).resolve().parent.parent
    candidates = [
        bridge_root / ".env",
        Path("C:/dev/Agentic-Home/.env"),
    ]
    for env_path in candidates:
        if env_path.exists():
            load_dotenv(env_path, override=False)
            if os.environ.get("ANTHROPIC_API_KEY"):
                return str(env_path)
    return None


async def delegate(
    prompt: str,
    working_dir: str,
    max_turns: int = 10,
    cost_cap_usd: float = DEFAULT_COST_CAP_USD,
    allow_destructive: bool = False,
) -> dict:
    """Run a one-shot Claude Code delegation with v0.1.0 permission gating.

    Returns a structured result dict (see schema in build plan §3.5).
    """
    from claude_agent_sdk import query, ClaudeAgentOptions

    # Pre-prompt destructive check (coarse).
    if not allow_destructive:
        is_safe, reason = validate_prompt(prompt)
        if not is_safe:
            return {
                "success": False,
                "blocked_by_gate": "pre_prompt_destructive_check",
                "reason": reason,
                "permission_events": [],
            }

    src = load_api_key()
    if not os.environ.get("ANTHROPIC_API_KEY"):
        raise RuntimeError(
            "ANTHROPIC_API_KEY not found. Set it in env, or place a .env next to "
            "the bridge package, or in C:/dev/Agentic-Home/.env."
        )

    options = ClaudeAgentOptions(
        cwd=working_dir,
        max_turns=max_turns,
        permission_mode="acceptEdits",
        allowed_tools=["Bash", "Read", "Edit", "Write"],
    )

    messages = []
    permission_events = []  # destructive_blocked / admin_elevation_requested entries

    try:
        async for msg in query(prompt=prompt, options=options):
            messages.append(msg)
            # Runtime check on each streamed message for tool-call shapes.
            tool_call_text = _extract_tool_call_text(msg)
            if tool_call_text:
                d_reason = is_destructive(tool_call_text)
                if d_reason and not allow_destructive:
                    permission_events.append({
                        "type": "destructive_blocked",
                        "reason": d_reason,
                        "snippet": tool_call_text[:200],
                    })
                    # v0.1.0: record but do not interrupt. Interrupt logic lands in v0.2.0
                    # with the tiered checkpoint protocol (per build plan §3.7).
                a_reason = requires_admin(tool_call_text)
                if a_reason:
                    permission_events.append({
                        "type": "admin_elevation_requested",
                        "reason": a_reason,
                        "snippet": tool_call_text[:200],
                    })
    except Exception as e:
        return {
            "success": False,
            "error": f"{type(e).__name__}: {e}",
            "key_source": src,
            "messages_received": len(messages),
            "permission_events": permission_events,
        }

    result = {
        "success": False,
        "result": None,
        "cost_usd": 0.0,
        "session_id": None,
        "num_turns": 0,
        "key_source": src,
        "messages_received": len(messages),
        "permission_events": permission_events,
        "cost_cap_usd": cost_cap_usd,
    }
    for msg in reversed(messages):
        if hasattr(msg, "subtype") and getattr(msg, "subtype", None) == "success":
            result["success"] = not getattr(msg, "is_error", False)
            result["result"] = getattr(msg, "result", None)
            result["cost_usd"] = getattr(msg, "total_cost_usd", 0.0)
            result["session_id"] = getattr(msg, "session_id", None)
            result["num_turns"] = getattr(msg, "num_turns", 0)
            break
        if isinstance(msg, dict) and msg.get("type") == "result":
            result["success"] = not msg.get("is_error", False)
            result["result"] = msg.get("result")
            result["cost_usd"] = msg.get("total_cost_usd", 0.0)
            result["session_id"] = msg.get("session_id")
            result["num_turns"] = msg.get("num_turns", 0)
            break

    # Flat cost-cap check (tiered checkpoint protocol comes in v0.2.0).
    if result["cost_usd"] > cost_cap_usd:
        result["cost_cap_exceeded"] = True

    return result


def _extract_tool_call_text(msg) -> Optional[str]:
    """Best-effort extraction of tool-call payload text from a streamed message.

    claude-agent-sdk's message types vary across versions. We try common shapes:
    - AssistantMessage with .content as a list of blocks (ToolUseBlock has .name and .input)
    - Dict-style messages with type='tool_use'

    Returns a string like 'tool=Bash input={...}' or None if no tool call in the message.
    """
    if hasattr(msg, "content"):
        content = msg.content
        if isinstance(content, list):
            parts = []
            for block in content:
                # Object-style ToolUseBlock
                if hasattr(block, "input") and hasattr(block, "name"):
                    parts.append(f"tool={block.name} input={block.input!r}")
                # Dict-style block
                elif isinstance(block, dict) and block.get("type") == "tool_use":
                    parts.append(f"tool={block.get('name')} input={block.get('input')!r}")
            if parts:
                return " | ".join(parts)
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="claude-code-bridge orchestrator (v0.1.0)")
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--working-dir", required=True)
    parser.add_argument("--max-turns", type=int, default=10)
    parser.add_argument("--cost-cap-usd", type=float, default=DEFAULT_COST_CAP_USD)
    parser.add_argument(
        "--allow-destructive",
        action="store_true",
        help="Skip the destructive-op gate. Use carefully.",
    )
    args = parser.parse_args()
    result = asyncio.run(delegate(
        args.prompt, args.working_dir, args.max_turns, args.cost_cap_usd, args.allow_destructive,
    ))
    print(json.dumps(result, indent=2, default=str))
    return 0 if result.get("success") else 1


if __name__ == "__main__":
    sys.exit(main())
