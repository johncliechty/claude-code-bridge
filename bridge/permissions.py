"""Phase 2 v0.1.0 permission gates for the orchestrator.

Pre-validates prompts and runtime tool calls against:
- Destructive-op blocklist (rm -rf, Remove-Item -Recurse -Force, git push --force, etc.)
- Admin-elevation patterns (Start-Process -Verb RunAs, sudo, runas)

This is v0.1.0 scope. Tiered cost checkpoints and loop-detection (repeat-tool-call
sliding window) come in v0.2.0 per the build plan's Q4 resolution.
"""
import re
from typing import Optional, Tuple

# (regex, human-readable reason). Patterns are case-insensitive via (?i).
# Seeded from win-cli-mcp-server's defaults, extended for git-destructive ops.
DESTRUCTIVE_PATTERNS = [
    (r"(?i)\brm\s+(-[a-z]*r[a-z]*f|-rf|-fr)\b", "rm -rf (recursive force-delete)"),
    (r"(?i)Remove-Item\s+[^|]*-Recurse\b[^|]*-Force\b", "Remove-Item -Recurse -Force"),
    (r"(?i)Remove-Item\s+[^|]*-Force\b[^|]*-Recurse\b", "Remove-Item -Force -Recurse"),
    (r"(?i)\bdel\s+/[a-z]*s[a-z]*\b", "del /s (recursive delete on Windows)"),
    (r"(?i)\bgit\s+push\s+[^|]*--force(-with-lease)?\b", "git push --force"),
    (r"(?i)\bgit\s+reset\s+--hard\b", "git reset --hard"),
    (r"(?i)\bgit\s+branch\s+-D\b", "git branch -D (force-delete branch)"),
    (r"(?i)Format-Volume\b", "Format-Volume"),
    (r"(?i)\bformat\s+[a-z]:", "format <drive>:"),
    (r"(?i)\bshutdown(?:\s+/[a-z])?\b", "shutdown"),
    (r"(?i)Restart-Computer\b", "Restart-Computer"),
    (r"(?i)\bregedit\b", "regedit"),
    (r"(?i)\bdiskpart\b", "diskpart"),
    (r"(?i)~[/\\]\.ssh\b", "anything writing to ~/.ssh"),
]

ADMIN_PATTERNS = [
    (r"(?i)Start-Process\s+[^|]*-Verb\s+RunAs\b", "Start-Process -Verb RunAs"),
    (r"(?i)(^|\s)sudo\s+", "sudo"),
    (r"(?i)(^|\s)runas\s+", "runas"),
    (r"(?i)pwsh\s+[^|]*-Verb\s+RunAs\b", "pwsh -Verb RunAs"),
]


def is_destructive(text: str) -> Optional[str]:
    """Return human-readable reason if `text` matches a destructive pattern, else None."""
    if not text:
        return None
    for pattern, reason in DESTRUCTIVE_PATTERNS:
        if re.search(pattern, text):
            return reason
    return None


def requires_admin(text: str) -> Optional[str]:
    """Return human-readable reason if `text` requests admin elevation, else None."""
    if not text:
        return None
    for pattern, reason in ADMIN_PATTERNS:
        if re.search(pattern, text):
            return reason
    return None


def validate_prompt(prompt: str) -> Tuple[bool, Optional[str]]:
    """Pre-validate a prompt for obviously destructive intent.

    This is a coarse check on the prompt text itself. The runtime check on each
    streamed tool call is more authoritative.

    Returns (is_safe, reason_if_unsafe).
    """
    reason = is_destructive(prompt)
    if reason:
        return False, f"Prompt contains potentially destructive operation: {reason}"
    return True, None
