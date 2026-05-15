#!/usr/bin/env bash
# install-watcher-macos.sh -- one-shot installer for the filesystem-IPC bridge daemon on macOS.
#
# Run from Terminal:
#   bash ~/claude-code-bridge/install-watcher-macos.sh
#
# Safe to re-run. Idempotent. Mirrors install-watcher.ps1 for Windows.

set -u  # treat unset vars as errors; do not exit on first failed command (we want diagnostics)

# --- Configurable paths ---
BRIDGE_ROOT="${BRIDGE_ROOT:-$HOME/claude-code-bridge}"
PYTHON="${PYTHON:-$(command -v python3 || true)}"
LABEL='com.claudecodebridge.watcher'
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT="$BRIDGE_ROOT/bridge/watcher.py"
IPC_INBOX="$BRIDGE_ROOT/ipc/inbox"
IPC_OUTBOX="$BRIDGE_ROOT/ipc/outbox"
LOG_DIR="$BRIDGE_ROOT/logs"
LOG_FILE="$LOG_DIR/watcher.log"
STDOUT_LOG="$LOG_DIR/launchagent.out.log"
STDERR_LOG="$LOG_DIR/launchagent.err.log"

# --- Pretty output helpers ---
RED=$(printf '\033[31m'); GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m'); CYAN=$(printf '\033[36m'); RESET=$(printf '\033[0m')
section() { printf "\n${CYAN}=== %s ===${RESET}\n" "$1"; }
ok()      { printf "  ${GREEN}PASS:${RESET} %s\n" "$1"; }
warn()    { printf "  ${YELLOW}WARN:${RESET} %s\n" "$1"; }
fail()    { printf "  ${RED}FAIL:${RESET} %s\n" "$1"; }

# --- Step 1: prerequisites ---
section 'Step 1: prerequisites'

if [[ -z "$PYTHON" || ! -x "$PYTHON" ]]; then
    fail "python3 not found on PATH. Install with Homebrew: brew install python@3.12"
    fail "Or set PYTHON=/path/to/python3 in the environment and re-run."
    exit 1
fi
ok "python3 at $PYTHON ($($PYTHON --version 2>&1))"

if [[ ! -f "$SCRIPT" ]]; then
    fail "Watcher script not found at $SCRIPT."
    fail "Expected the repo to be at $BRIDGE_ROOT. Set BRIDGE_ROOT=<path> to override."
    exit 1
fi
ok "Watcher script at $SCRIPT"

mkdir -p "$IPC_INBOX" "$IPC_OUTBOX" "$LOG_DIR"
ok "IPC folders: $IPC_INBOX, $IPC_OUTBOX"
ok "Log folder: $LOG_DIR"

# --- Step 2: import smoke test ---
section 'Step 2: bridge.shell imports cleanly'
IMPORT_OUT=$("$PYTHON" -c "import sys; sys.path.insert(0, '$BRIDGE_ROOT'); from bridge.shell import run_command; from bridge.permissions import is_destructive; print('OK')" 2>&1)
if [[ "$IMPORT_OUT" != *"OK"* ]]; then
    fail 'bridge.shell import failed:'
    echo "$IMPORT_OUT" | sed 's/^/    /'
    exit 1
fi
ok 'bridge.shell + bridge.permissions importable'

# --- Step 3: write the LaunchAgent plist ---
section "Step 3: install LaunchAgent at $PLIST_PATH"

# If a previous agent is loaded, unload it first so we can write a fresh plist.
if launchctl list "$LABEL" >/dev/null 2>&1; then
    launchctl unload -w "$PLIST_PATH" 2>/dev/null || true
    ok "Unloaded existing $LABEL for clean reinstall"
fi

mkdir -p "$(dirname "$PLIST_PATH")"
cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>$SCRIPT</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$BRIDGE_ROOT</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$STDOUT_LOG</string>
    <key>StandardErrorPath</key>
    <string>$STDERR_LOG</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PYTHONUNBUFFERED</key>
        <string>1</string>
    </dict>
</dict>
</plist>
PLIST
ok "Wrote $PLIST_PATH"

# --- Step 4: load and start the daemon ---
section 'Step 4: load and start the daemon'
launchctl load -w "$PLIST_PATH"
sleep 1

if launchctl list "$LABEL" >/dev/null 2>&1; then
    PID=$(launchctl list | awk -v label="$LABEL" '$3 == label { print $1 }')
    if [[ "$PID" != "-" && -n "$PID" ]]; then
        ok "Daemon running (PID $PID, managed by launchd)"
    else
        warn "LaunchAgent registered but not currently running. Check $STDERR_LOG for boot errors."
    fi
else
    fail "LaunchAgent failed to register. Check the plist syntax and $STDERR_LOG."
    exit 1
fi

# Sanity check: confirm the daemon logged its startup line
sleep 1
if [[ -f "$LOG_FILE" ]] && tail -n 5 "$LOG_FILE" | grep -q 'watcher starting'; then
    ok 'Daemon logged "watcher starting" successfully'
elif [[ -f "$STDOUT_LOG" ]] && tail -n 5 "$STDOUT_LOG" | grep -q 'watcher starting'; then
    ok 'Daemon logged "watcher starting" (in launchd stdout)'
else
    warn "No 'watcher starting' line yet. Daemon may still be initialising."
fi

# --- Step 5: end-to-end self-test ---
section 'Step 5: end-to-end self-test (the real proof)'
REQ_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
REQ_PATH="$IPC_INBOX/$REQ_ID.json"
OUT_PATH="$IPC_OUTBOX/$REQ_ID.json"
TMP_PATH="$REQ_PATH.tmp"

cat > "$TMP_PATH" <<JSON
{
    "request_id": "$REQ_ID",
    "command": "echo bridge-selftest-ok",
    "shell": "bash",
    "timeout": 10
}
JSON
mv "$TMP_PATH" "$REQ_PATH"

# Poll for the response up to 15 seconds
DEADLINE=$(($(date +%s) + 15))
while [[ $(date +%s) -lt $DEADLINE ]]; do
    if [[ -f "$OUT_PATH" ]]; then
        RESPONSE=$(cat "$OUT_PATH")
        rm -f "$OUT_PATH"
        if [[ "$RESPONSE" == *"bridge-selftest-ok"* && "$RESPONSE" == *'"exit_code": 0'* ]]; then
            ok 'Round-trip succeeded: daemon executed the request and wrote the expected outbox response'
            break
        else
            fail 'Round-trip response was malformed or wrong:'
            echo "$RESPONSE" | sed 's/^/    /'
            exit 1
        fi
    fi
    sleep 0.2
done

if [[ ! -f "$OUT_PATH" && "${RESPONSE:-}" == "" ]]; then
    fail 'Round-trip timed out after 15s. Daemon is registered but not processing requests.'
    fail "Tail $STDERR_LOG and $LOG_FILE to diagnose."
    exit 1
fi

# --- Step 6: print final state ---
section 'Step 6: install complete'
echo "  LaunchAgent:  $PLIST_PATH (label $LABEL)"
echo "  Daemon log:   $LOG_FILE"
echo "  launchd out:  $STDOUT_LOG"
echo "  launchd err:  $STDERR_LOG"
echo
echo "  Useful commands:"
echo "    launchctl list | grep $LABEL          # check status"
echo "    launchctl unload $PLIST_PATH          # stop"
echo "    launchctl load -w $PLIST_PATH         # start"
echo "    tail -f $LOG_FILE                     # follow log"
echo
echo "  Auto-starts at every login. To uninstall:"
echo "    launchctl unload -w $PLIST_PATH && rm $PLIST_PATH"
