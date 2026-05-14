"""Phase 1 PoC orchestrator: invoke Claude Code via claude-agent-sdk and return result+cost."""
import asyncio
import argparse
import json
import os
import sys
from pathlib import Path
from typing import Optional

from dotenv import load_dotenv


def load_api_key() -> Optional[str]:
    """Load ANTHROPIC_API_KEY from .env files in priority order. Returns the source that supplied it."""
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


async def delegate(prompt: str, working_dir: str, max_turns: int = 10) -> dict:
    """Run a one-shot Claude Code delegation. Returns a structured result dict."""
    from claude_agent_sdk import query, ClaudeAgentOptions

    src = load_api_key()
    if not os.environ.get("ANTHROPIC_API_KEY"):
        raise RuntimeError("ANTHROPIC_API_KEY not found in env or any .env candidate")

    options = ClaudeAgentOptions(
        cwd=working_dir,
        max_turns=max_turns,
        permission_mode="acceptEdits",
        allowed_tools=["Bash", "Read", "Edit", "Write"],
    )

    messages = []
    try:
        async for msg in query(prompt=prompt, options=options):
            messages.append(msg)
    except Exception as e:
        return {
            "success": False,
            "error": f"{type(e).__name__}: {e}",
            "key_source": src,
            "messages_received": len(messages),
        }

    result = {
        "success": False,
        "result": None,
        "cost_usd": 0.0,
        "session_id": None,
        "num_turns": 0,
        "key_source": src,
        "messages_received": len(messages),
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

    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="claude-code-bridge Phase 1 PoC orchestrator")
    parser.add_argument("--prompt", required=True, help="The prompt to send to Claude Code")
    parser.add_argument("--working-dir", required=True, help="Absolute path for Claude Code's cwd")
    parser.add_argument("--max-turns", type=int, default=10, help="Cap on agentic loop turns")
    args = parser.parse_args()
    result = asyncio.run(delegate(args.prompt, args.working_dir, args.max_turns))
    print(json.dumps(result, indent=2, default=str))
    return 0 if result.get("success") else 1


if __name__ == "__main__":
    sys.exit(main())
