"""Tests for the v0.2.0 shell module — the post-pivot core of the bridge."""
import asyncio
import sys

import pytest

from bridge.shell import (
    run_command,
    _build_argv,
    _default_shell,
    SUPPORTED_SHELLS,
)


# --------------------- argv construction (pure logic) ---------------------

def test_default_shell_picks_per_os():
    expected = "powershell" if sys.platform == "win32" else "bash"
    assert _default_shell() == expected


def test_build_argv_powershell():
    argv = _build_argv("powershell", "Get-Date")
    assert argv[0].endswith("powershell.exe") or argv[0] == "powershell"
    assert "-NoProfile" in argv
    assert "-ExecutionPolicy" in argv
    assert "Bypass" in argv
    assert "-Command" in argv
    assert argv[-1] == "Get-Date"


def test_build_argv_pwsh():
    argv = _build_argv("pwsh", "Get-Date")
    assert argv[0].endswith("pwsh.exe") or argv[0] == "pwsh"
    assert "-NoProfile" in argv
    assert argv[-1] == "Get-Date"


def test_build_argv_cmd():
    argv = _build_argv("cmd", "dir")
    assert argv == ["cmd.exe", "/c", "dir"]


def test_build_argv_bash():
    argv = _build_argv("bash", "ls -la")
    assert argv == ["bash", "-c", "ls -la"]


def test_build_argv_rejects_unknown_shell():
    with pytest.raises(ValueError):
        _build_argv("fish", "ls")


# --------------------- permission gating in run_command ---------------------

@pytest.mark.asyncio
async def test_destructive_command_blocked():
    result = await run_command("rm -rf /tmp", shell="bash")
    assert result["exit_code"] == -1
    assert result["blocked_by_gate"] == "destructive_op"
    assert "rm -rf" in result["reason"]
    assert result["stdout"] == ""
    assert len(result["permission_events"]) == 1
    assert result["permission_events"][0]["type"] == "destructive_blocked"


@pytest.mark.asyncio
async def test_destructive_command_allowed_when_flagged():
    # The destructive gate doesn't run when allow_destructive=True; the actual
    # command would still try to run (and may legitimately fail on a path that
    # doesn't exist or on permission grounds). We just verify the gate didn't fire.
    result = await run_command("rm -rf /tmp/nonexistent-bridge-test-path-12345", shell="bash", allow_destructive=True)
    assert result.get("blocked_by_gate") != "destructive_op"


@pytest.mark.asyncio
async def test_admin_request_surfaced_not_blocked():
    # Admin elevation is FLAGGED in permission_events but not blocked. The OS
    # handles the actual elevation prompt. We use a command that requires admin
    # but is otherwise non-destructive.
    # Use shell=bash so this works in the test environment regardless of OS.
    result = await run_command("sudo echo hello", shell="bash")
    assert result.get("blocked_by_gate") is None or result.get("blocked_by_gate") == "shell_not_found"
    if result.get("blocked_by_gate") is None:
        # The admin-elevation event should be in permission_events.
        admin_events = [e for e in result["permission_events"] if e["type"] == "admin_elevation_requested"]
        assert len(admin_events) >= 1


# --------------------- actual subprocess execution ---------------------

@pytest.mark.asyncio
async def test_simple_bash_command():
    """Smoke test: bash echo runs and returns stdout. Skipped on Windows-only environments."""
    # bash should exist on Cowork's Linux sandbox AND on the host via Git Bash.
    result = await run_command("echo 'hello bridge'", shell="bash", timeout=10)
    if result.get("blocked_by_gate") == "shell_not_found":
        pytest.skip("bash not available on this host")
    assert result["exit_code"] == 0
    assert "hello bridge" in result["stdout"]
    assert result["timed_out"] is False
    assert result["duration_ms"] > 0


@pytest.mark.asyncio
async def test_timeout_kills_process():
    """A command longer than the timeout is killed and timed_out=True."""
    result = await run_command("sleep 5", shell="bash", timeout=0.5)
    if result.get("blocked_by_gate") == "shell_not_found":
        pytest.skip("bash not available on this host")
    assert result["timed_out"] is True
    # The killed proc may have exit_code -1 or a signal code; just check it's not 0.
    assert result["exit_code"] != 0


@pytest.mark.asyncio
async def test_nonzero_exit_code_captured():
    """A command that exits non-zero still returns with that exit code (not raised)."""
    result = await run_command("exit 7", shell="bash", timeout=5)
    if result.get("blocked_by_gate") == "shell_not_found":
        pytest.skip("bash not available on this host")
    assert result["exit_code"] == 7
    assert result["timed_out"] is False


@pytest.mark.asyncio
async def test_stderr_captured():
    """Output on stderr ends up in the stderr field."""
    result = await run_command("echo 'to stderr' 1>&2", shell="bash", timeout=5)
    if result.get("blocked_by_gate") == "shell_not_found":
        pytest.skip("bash not available on this host")
    assert "to stderr" in result["stderr"]


@pytest.mark.asyncio
async def test_env_merge():
    """Env vars passed in env= are visible to the child process."""
    result = await run_command(
        "echo $BRIDGE_TEST_VAR",
        shell="bash",
        timeout=5,
        env={"BRIDGE_TEST_VAR": "from-bridge-env"},
    )
    if result.get("blocked_by_gate") == "shell_not_found":
        pytest.skip("bash not available on this host")
    assert "from-bridge-env" in result["stdout"]


@pytest.mark.asyncio
async def test_unsupported_shell():
    result = await run_command("anything", shell="fish")
    assert result["exit_code"] == -1
    assert result["blocked_by_gate"] == "unsupported_shell"


# --------------------- Windows-specific (run only on Windows) ---------------------

@pytest.mark.skipif(sys.platform != "win32", reason="Windows-only PowerShell test")
@pytest.mark.asyncio
async def test_powershell_basic():
    result = await run_command("Write-Output 'hello-from-ps'", shell="powershell", timeout=15)
    assert result["exit_code"] == 0
    assert "hello-from-ps" in result["stdout"]


@pytest.mark.skipif(sys.platform != "win32", reason="Windows-only cmd test")
@pytest.mark.asyncio
async def test_cmd_basic():
    result = await run_command("echo hello-from-cmd", shell="cmd", timeout=10)
    assert result["exit_code"] == 0
    assert "hello-from-cmd" in result["stdout"]
