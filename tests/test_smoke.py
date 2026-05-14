"""Smoke test for Phase 1 orchestrator."""
import asyncio
import os
from pathlib import Path

from bridge.orchestrator import delegate, load_api_key


def test_load_api_key():
    src = load_api_key()
    assert src is not None, "no key source found"
    assert os.environ.get("ANTHROPIC_API_KEY"), "key not loaded into env"
    print(f"key loaded from: {src}")


def test_smoke_say_hi():
    result = asyncio.run(delegate(
        prompt="Respond with the single word 'hello'. Do not use any tools. Do not write any code.",
        working_dir=str(Path.cwd()),
        max_turns=2,
    ))
    print(f"FULL RESULT: {result}")
    assert result.get("success"), f"orchestrator did not return success: {result}"
    assert result.get("result"), "no result content returned"
