"""Filesystem-IPC daemon for the bridge.

Watches `<bridge_root>/ipc/inbox/*.json` for shell-command requests from sandboxed
agent runtimes (Cowork). For each request, executes the command via
`bridge.shell.run_command` and writes the structured result to
`<bridge_root>/ipc/outbox/<same-uuid>.json`.

Architecture:
- Cowork session (sandboxed) needs to run a host shell command.
- Cowork has Write/Read file tools that reach anywhere under C:\\dev (trusted folder).
- Cowork writes:  C:\\dev\\claude-code-bridge\\ipc\\inbox\\<uuid>.json
- This daemon reads it, runs `run_command(...)`, writes:
  C:\\dev\\claude-code-bridge\\ipc\\outbox\\<uuid>.json
- Cowork polls outbox until the file appears, then reads result.
- Daemon also cleans up old outbox files after a TTL so the folder stays tidy.

The daemon has zero external dependencies beyond Python 3.10+ and the bridge
package itself (bridge.shell + bridge.permissions, both pure-Python). It does
NOT need the `mcp` package — that was only needed for the MCPB MCP-server path.

Run with: `python -m bridge.watcher` (from C:\\dev\\claude-code-bridge)
or: `C:\\Users\\john\\AppData\\Local\\Programs\\Python\\Python313\\python.exe C:\\dev\\claude-code-bridge\\bridge\\watcher.py`
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import sys
import time
from collections import OrderedDict
from pathlib import Path
from typing import Optional

# In-memory dedup set: tracks request filenames we've already processed in this
# daemon lifetime. Defense-in-depth — even if the post-process unlink() fails
# (file-system permission quirk, ACL race, antivirus locking the file), we won't
# re-execute the same command. Capped to MAX_PROCESSED_CACHE entries with FIFO
# eviction; that's enough for ~10K commands of memory before a dedup miss is
# possible, well beyond any realistic single-day usage.
MAX_PROCESSED_CACHE = 10_000
_PROCESSED_CACHE: "OrderedDict[str, bool]" = OrderedDict()


def _is_processed(name: str) -> bool:
    return name in _PROCESSED_CACHE


def _mark_processed(name: str) -> None:
    _PROCESSED_CACHE[name] = True
    if len(_PROCESSED_CACHE) > MAX_PROCESSED_CACHE:
        _PROCESSED_CACHE.popitem(last=False)

# Make sure we can import bridge.shell and bridge.permissions even if launched
# via absolute script path (Task Scheduler does this).
_BRIDGE_ROOT = Path(__file__).resolve().parent.parent
if str(_BRIDGE_ROOT) not in sys.path:
    sys.path.insert(0, str(_BRIDGE_ROOT))

from bridge.shell import run_command  # noqa: E402

# -------------------- Configuration --------------------

IPC_DIR = _BRIDGE_ROOT / "ipc"
INBOX = IPC_DIR / "inbox"
OUTBOX = IPC_DIR / "outbox"
LOG_DIR = _BRIDGE_ROOT / "logs"
LOG_FILE = LOG_DIR / "watcher.log"

POLL_INTERVAL_SECONDS = 0.1        # how often to scan inbox when empty
STALE_REQUEST_AGE_SECONDS = 600    # delete inbox requests older than 10 min unprocessed
OUTBOX_TTL_SECONDS = 300           # auto-clean outbox files older than 5 min
CLEANUP_INTERVAL_SECONDS = 30      # how often to run the outbox cleanup pass


# -------------------- Bootstrap --------------------

def _ensure_dirs() -> None:
    """Create IPC and log directories if missing."""
    for p in (INBOX, OUTBOX, LOG_DIR):
        p.mkdir(parents=True, exist_ok=True)


def _setup_logging() -> logging.Logger:
    """Set up rotating file logger + stderr."""
    _ensure_dirs()
    log = logging.getLogger("bridge.watcher")
    log.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
    # File handler
    fh = logging.FileHandler(str(LOG_FILE), encoding="utf-8")
    fh.setFormatter(fmt)
    log.addHandler(fh)
    # Stderr handler (useful when running in foreground)
    sh = logging.StreamHandler(sys.stderr)
    sh.setFormatter(fmt)
    log.addHandler(sh)
    return log


# -------------------- Request processing --------------------

async def _process_one(req_path: Path, log: logging.Logger) -> None:
    """Read a request file, execute, write result, delete request."""
    # Dedup: if we've already processed this filename in this daemon's lifetime,
    # skip and try one more time to delete the file. Prevents re-execution if
    # the prior unlink() failed for any reason.
    if _is_processed(req_path.name):
        try:
            req_path.unlink()
        except OSError:
            pass
        return

    req: Optional[dict] = None
    try:
        # Read request JSON
        try:
            with open(req_path, "r", encoding="utf-8") as f:
                req = json.load(f)
        except (json.JSONDecodeError, OSError) as e:
            log.warning(f"unreadable/malformed request {req_path.name}: {e}; deleting")
            try:
                req_path.unlink()
            except OSError:
                pass
            return

        cmd_preview = (req.get("command", "") or "")[:120]
        log.info(f"request {req_path.name}: cmd={cmd_preview!r} shell={req.get('shell')}")

        # Execute via the existing bridge.shell.run_command
        result = await run_command(
            command=req["command"],
            cwd=req.get("cwd"),
            shell=req.get("shell"),
            timeout=float(req.get("timeout", 60.0)),
            allow_destructive=bool(req.get("allow_destructive", False)),
            env=req.get("env"),
        )

        # Echo back the request_id for the client's convenience
        if "request_id" in req:
            result["request_id"] = req["request_id"]

        # Atomic write: temp then rename
        out_path = OUTBOX / req_path.name
        tmp_path = out_path.with_suffix(".tmp")
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(result, f, default=str)
        tmp_path.replace(out_path)
        log.info(
            f"result {out_path.name}: exit_code={result.get('exit_code')} "
            f"duration={result.get('duration_ms', 0):.1f}ms"
        )

        # Mark as processed BEFORE unlink so a delete failure doesn't cause re-exec
        _mark_processed(req_path.name)

        # Remove processed request
        try:
            req_path.unlink()
        except OSError as e:
            log.warning(f"could not unlink {req_path.name}: {e}; dedup will prevent re-exec")

    except Exception as e:
        log.exception(f"error processing {req_path.name}: {e}")
        # Best-effort: write an error result so the caller doesn't hang forever
        try:
            err_result = {
                "success": False,
                "error": f"{type(e).__name__}: {e}",
                "request": req,
            }
            out_path = OUTBOX / req_path.name
            tmp_path = out_path.with_suffix(".tmp")
            with open(tmp_path, "w", encoding="utf-8") as f:
                json.dump(err_result, f, default=str)
            tmp_path.replace(out_path)
        except Exception:
            log.exception("also failed to write error result")
        try:
            req_path.unlink()
        except Exception:
            pass


# -------------------- Cleanup --------------------

def _cleanup_outbox(log: logging.Logger) -> int:
    """Delete outbox files older than OUTBOX_TTL_SECONDS. Returns count deleted."""
    now = time.time()
    deleted = 0
    for path in OUTBOX.glob("*.json"):
        try:
            age = now - path.stat().st_mtime
            if age > OUTBOX_TTL_SECONDS:
                path.unlink()
                deleted += 1
        except FileNotFoundError:
            pass
        except Exception as e:
            log.warning(f"cleanup error on {path.name}: {e}")
    # Also clean up stale .tmp files from interrupted writes
    for path in OUTBOX.glob("*.tmp"):
        try:
            age = now - path.stat().st_mtime
            if age > 60:
                path.unlink()
        except Exception:
            pass
    return deleted


def _cleanup_stale_inbox(log: logging.Logger) -> int:
    """Delete inbox files older than STALE_REQUEST_AGE_SECONDS. Returns count deleted."""
    now = time.time()
    deleted = 0
    for path in INBOX.glob("*.json"):
        try:
            age = now - path.stat().st_mtime
            if age > STALE_REQUEST_AGE_SECONDS:
                log.warning(f"deleting stale inbox request {path.name} (age={age:.0f}s)")
                path.unlink()
                deleted += 1
        except FileNotFoundError:
            pass
        except Exception as e:
            log.warning(f"stale-inbox cleanup error on {path.name}: {e}")
    return deleted


# -------------------- Main loop --------------------

async def watch_loop(log: logging.Logger) -> None:
    """Process inbox requests and run periodic cleanup. Runs forever until interrupted."""
    log.info(f"watcher starting; INBOX={INBOX}; OUTBOX={OUTBOX}")
    last_cleanup = 0.0
    while True:
        try:
            # Periodic cleanup
            now = time.time()
            if now - last_cleanup > CLEANUP_INTERVAL_SECONDS:
                deleted_out = _cleanup_outbox(log)
                deleted_in = _cleanup_stale_inbox(log)
                if deleted_out or deleted_in:
                    log.info(f"cleanup: deleted {deleted_out} old outbox, {deleted_in} stale inbox")
                last_cleanup = now

            # Pick up oldest-first requests (sorted by filename, which is UUID-random
            # but at least deterministic)
            requests = sorted(INBOX.glob("*.json"))
            if not requests:
                await asyncio.sleep(POLL_INTERVAL_SECONDS)
                continue

            for req_path in requests:
                await _process_one(req_path, log)

        except asyncio.CancelledError:
            log.info("watch_loop cancelled")
            raise
        except KeyboardInterrupt:
            log.info("watch_loop interrupted")
            return
        except Exception as e:
            log.exception(f"unhandled error in watch_loop: {e}")
            await asyncio.sleep(1.0)


def main() -> int:
    log = _setup_logging()
    log.info("=" * 60)
    log.info(f"bridge.watcher main() pid={os.getpid()} python={sys.version.split()[0]}")
    try:
        asyncio.run(watch_loop(log))
    except KeyboardInterrupt:
        log.info("interrupted by user")
        return 0
    except Exception as e:
        log.exception(f"watcher died: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
