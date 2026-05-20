"""v0.2.0 shell execution module — the core of the post-pivot bridge.

Phase 2 architecture (with claude-agent-sdk as the intermediary) was replaced
with a direct shell execution model: the bridge MCP server exposes `run_command`,
the calling agent (Cowork) sends a shell command string, the bridge runs it via
`subprocess` on the host and returns structured output. No LLM in the middle.

Supports PowerShell (default on Windows), cmd (faster, simpler), and bash
(default on Mac/Linux). Permission gating from bridge.permissions still applies
to every command before execution.
"""
import asyncio
import os
import sys
import time
from typing import Optional

from bridge.permissions import is_destructive, requires_admin


# Default timeout in seconds for a single command.
DEFAULT_TIMEOUT_SECONDS = 60.0

# The shell choices we support.
SUPPORTED_SHELLS = ("powershell", "pwsh", "cmd", "bash")


def _augment_host_path() -> None:
    """Ensure common host tool directories are on PATH for spawned commands.

    The daemon is usually launched by a Windows Scheduled Task whose process
    environment has a heavily stripped PATH -- empirically so stripped that even
    git / gh / node installed in standard locations are not resolvable, and a
    registry PATH read does not recover them. So we mirror bootstrap.ps1's
    known-location resolver: probe well-known install dirs and prepend any that
    exist to os.environ['PATH']. Because run_command spawns children that inherit
    this process's environment, every command then sees git/gh/node. This is
    general (standard install locations on any Windows box), so it ships with the
    daemon and needs zero per-machine configuration. No-op on non-Windows.
    """
    if sys.platform != "win32":
        return
    import glob

    pf = os.environ.get("ProgramFiles", r"C:\Program Files")
    pf86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
    local = os.environ.get("LOCALAPPDATA", os.path.expanduser(r"~\AppData\Local"))
    windir = os.environ.get("SystemRoot", r"C:\Windows")

    candidates = [
        # git (machine + user installs)
        rf"{pf}\Git\cmd", rf"{pf}\Git\bin", rf"{pf86}\Git\cmd",
        rf"{local}\Programs\Git\cmd",
        # GitHub CLI
        rf"{pf}\GitHub CLI", rf"{local}\GitHubCLI\bin",
        # Node.js
        rf"{pf}\nodejs", rf"{local}\Programs\nodejs",
        # core Windows dirs (so even whoami/where resolve under a stripped PATH)
        rf"{windir}\System32", windir,
        rf"{windir}\System32\WindowsPowerShell\v1.0",
        rf"{local}\Microsoft\WindowsApps",
    ]
    # Python install + Scripts dirs (for pip-installed CLIs)
    for base in (rf"{local}\Programs\Python", pf, r"C:"):
        candidates += glob.glob(rf"{base}\Python3*")
        candidates += glob.glob(rf"{base}\Python3*\Scripts")

    # Ensure PATHEXT lets bare command names resolve to executables. The stripped
    # Scheduled-Task environment can ship a near-empty PATHEXT (observed: just
    # ".CPL"), so `git` never resolves to `git.exe` even when its dir is on PATH.
    if ".EXE" not in os.environ.get("PATHEXT", "").upper():
        os.environ["PATHEXT"] = ".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC"

    existing = os.environ.get("PATH", "")
    have = {p.lower() for p in existing.split(os.pathsep) if p}
    prepend = [c for c in candidates if c and os.path.isdir(c) and c.lower() not in have]
    if prepend:
        os.environ["PATH"] = os.pathsep.join(prepend) + os.pathsep + existing


# Run once at import so both entry points (bridge.watcher and bridge.mcp_server,
# which both `from bridge.shell import ...`) get a usable PATH before any command runs.
_augment_host_path()


def _default_shell() -> str:
    """Pick a sensible default shell for the current OS."""
    if sys.platform == "win32":
        return "powershell"
    return "bash"


def _build_argv(shell: str, command: str) -> list[str]:
    """Build the argv list to invoke `command` in the given `shell`.

    PowerShell uses `-NoProfile -ExecutionPolicy Bypass -Command` so that scripts
    run cleanly without loading the user's profile (which may have surprises) and
    without execution policy interfering. pwsh.exe (PowerShell 7+) takes the same
    args. cmd.exe uses /c. bash uses -c.
    """
    if shell in ("powershell", "pwsh"):
        exe = f"{shell}.exe" if sys.platform == "win32" else shell
        return [exe, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command]
    if shell == "cmd":
        return ["cmd.exe", "/c", command]
    if shell == "bash":
        return ["bash", "-c", command]
    raise ValueError(f"Unsupported shell: {shell!r}. Supported: {SUPPORTED_SHELLS}")


async def run_command(
    command: str,
    cwd: Optional[str] = None,
    shell: Optional[str] = None,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
    allow_destructive: bool = False,
    env: Optional[dict] = None,
) -> dict:
    """Run `command` in the host shell. Returns a structured result.

    Args:
        command: The shell command string to execute.
        cwd: Working directory for the command. Defaults to the bridge's cwd.
        shell: One of "powershell", "pwsh", "cmd", "bash". Defaults to the OS default.
        timeout: Seconds before the command is killed and timed_out=True.
        allow_destructive: If True, skip the destructive-op gate. Use sparingly.
        env: Environment variables to add/override. None means inherit unchanged.

    Returns:
        A dict with: exit_code, stdout, stderr, duration_ms, command, shell, cwd,
        timed_out, permission_events.
    """
    chosen_shell = shell or _default_shell()
    if chosen_shell not in SUPPORTED_SHELLS:
        return {
            "exit_code": -1,
            "stdout": "",
            "stderr": f"Unsupported shell {chosen_shell!r}. Supported: {SUPPORTED_SHELLS}",
            "duration_ms": 0.0,
            "command": command,
            "shell": chosen_shell,
            "cwd": cwd,
            "timed_out": False,
            "permission_events": [],
            "blocked_by_gate": "unsupported_shell",
        }

    permission_events: list[dict] = []

    # Destructive-op pre-check.
    if not allow_destructive:
        d_reason = is_destructive(command)
        if d_reason:
            return {
                "exit_code": -1,
                "stdout": "",
                "stderr": "",
                "duration_ms": 0.0,
                "command": command,
                "shell": chosen_shell,
                "cwd": cwd,
                "timed_out": False,
                "blocked_by_gate": "destructive_op",
                "reason": d_reason,
                "permission_events": [
                    {"type": "destructive_blocked", "reason": d_reason, "snippet": command[:200]}
                ],
            }

    # Admin-elevation detection. Not blocked — surfaced as a permission_event so
    # the caller knows to expect a UAC prompt on Windows or sudo on POSIX.
    a_reason = requires_admin(command)
    if a_reason:
        permission_events.append({
            "type": "admin_elevation_requested",
            "reason": a_reason,
            "snippet": command[:200],
        })

    # Build the subprocess invocation.
    argv = _build_argv(chosen_shell, command)

    # Merge env if provided, else inherit.
    proc_env = None
    if env is not None:
        proc_env = os.environ.copy()
        proc_env.update(env)

    start = time.perf_counter()
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            cwd=cwd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=proc_env,
        )
    except FileNotFoundError as e:
        # Shell binary not on PATH.
        return {
            "exit_code": -1,
            "stdout": "",
            "stderr": f"Shell binary not found: {e}",
            "duration_ms": (time.perf_counter() - start) * 1000,
            "command": command,
            "shell": chosen_shell,
            "cwd": cwd,
            "timed_out": False,
            "permission_events": permission_events,
            "blocked_by_gate": "shell_not_found",
        }

    timed_out = False
    try:
        stdout_bytes, stderr_bytes = await asyncio.wait_for(
            proc.communicate(), timeout=timeout
        )
    except asyncio.TimeoutError:
        timed_out = True
        try:
            proc.kill()
        except ProcessLookupError:
            pass
        # Best-effort: wait briefly for the killed proc to die so we can collect partial output.
        try:
            stdout_bytes, stderr_bytes = await asyncio.wait_for(proc.communicate(), timeout=2.0)
        except (asyncio.TimeoutError, Exception):
            stdout_bytes, stderr_bytes = b"", b""

    duration_ms = (time.perf_counter() - start) * 1000

    # Decode output. Use errors='replace' so we never crash on non-UTF8 garbage.
    stdout = stdout_bytes.decode("utf-8", errors="replace") if stdout_bytes else ""
    stderr = stderr_bytes.decode("utf-8", errors="replace") if stderr_bytes else ""

    return {
        "exit_code": proc.returncode if proc.returncode is not None else -1,
        "stdout": stdout,
        "stderr": stderr,
        "duration_ms": duration_ms,
        "command": command,
        "shell": chosen_shell,
        "cwd": cwd,
        "timed_out": timed_out,
        "permission_events": permission_events,
    }
