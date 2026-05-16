#!/usr/bin/env bash
# install-watcher-linux.sh -- one-shot installer for the filesystem-IPC bridge daemon on Linux.
#
# Run from a terminal:
#   bash ~/claude-code-bridge/install-watcher-linux.sh
#
# Uses systemd --user units (no root required). Safe to re-run. Mirrors the
# macOS and Windows installers.

set -u

# --- Configurable paths ---
BRIDGE_ROOT="${BRIDGE_ROOT:-$HOME/claude-code-bridge}"
PYTHON="${PYTHON:-$(command -v python3 || true)}"
UNIT_NAME='claude-code-bridge.service'
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_PATH="$UNIT_DIR/$UNIT_NAME"
SCRIPT="$BRIDGE_ROOT/bridge/watcher.py"
IPC_INBOX="$BRIDGE_ROOT/ipc/inbox"
IPC_OUTBOX="$BRIDGE_ROOT/ipc/outbox"
LOG_DIR="$BRIDGE_ROOT/logs"
LOG_FILE="$LOG_DIR/watcher.log"

# --- Pretty output helpers ---
RED=$(printf '\033[31m'); GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m'); CYAN=$(printf '\033[36m'); RESET=$(printf '\033[0m')
section() { printf "\n${CYAN}=== %s ===${RESET}\n" "$1"; }
ok()      { printf "  ${GREEN}PASS:${RESET} %s\n" "$1"; }
warn()    { printf "  ${YELLOW}WARN:${RESET} %s\n" "$1"; }
fail()    { printf "  ${RED}FAIL:${RESET} %s\n" "$1"; }

# --- Step 0: ensure git, then ensure the bridge repo is cloned -----------
# This block makes the script work as a one-paste install:
#   curl -fsSL https://raw.githubusercontent.com/johncliechty/claude-code-bridge/main/install-watcher-linux.sh | bash
# When the script reaches Step 1, $BRIDGE_ROOT exists and contains the repo.
section 'Step 0: ensure git + clone bridge repo if missing'

if ! command -v git >/dev/null 2>&1; then
    fail 'git not found on PATH. Install via your distro:'
    fail '    sudo apt install git        # Debian/Ubuntu'
    fail '    sudo dnf install git        # Fedora/RHEL'
    fail '    sudo pacman -S git          # Arch'
    exit 1
fi
ok "git available ($(git --version 2>&1))"

if [[ ! -d "$BRIDGE_ROOT/.git" ]]; then
    mkdir -p "$(dirname "$BRIDGE_ROOT")"
    section "Cloning https://github.com/johncliechty/claude-code-bridge -> $BRIDGE_ROOT"
    if ! git clone https://github.com/johncliechty/claude-code-bridge "$BRIDGE_ROOT"; then
        fail 'git clone failed. Check your network connection and try again.'
        exit 1
    fi
    ok 'Repo cloned.'
else
    ok "Repo already present at $BRIDGE_ROOT."
    if git -C "$BRIDGE_ROOT" fetch --quiet origin 2>/dev/null && \
       git -C "$BRIDGE_ROOT" pull --ff-only --quiet 2>/dev/null; then
        ok 'Pulled latest from origin.'
    else
        warn 'Could not fast-forward; continuing with existing checkout.'
    fi
fi

# --- Step 1: prerequisites ---
section 'Step 1: prerequisites'

if [[ -z "$PYTHON" || ! -x "$PYTHON" ]]; then
    fail 'python3 not found on PATH. Install via your distro:'
    fail '    apt install python3      # Debian/Ubuntu'
    fail '    dnf install python3      # Fedora/RHEL'
    fail '    pacman -S python         # Arch'
    fail 'Or set PYTHON=/path/to/python3 and re-run.'
    exit 1
fi
ok "python3 at $PYTHON ($($PYTHON --version 2>&1))"

if ! command -v systemctl >/dev/null 2>&1; then
    fail 'systemctl not found. This installer requires systemd.'
    fail 'For non-systemd systems, run the daemon directly:'
    fail "    nohup $PYTHON $SCRIPT > $LOG_FILE 2>&1 &"
    fail 'and add an equivalent to your shell init for auto-start.'
    exit 1
fi
ok 'systemd available'

# systemd --user requires either a logind session or lingering enabled. Detect.
if ! systemctl --user status >/dev/null 2>&1; then
    warn 'systemd --user appears not to be running. The service will be installed,'
    warn 'but auto-start at boot may require: sudo loginctl enable-linger $USER'
fi

if [[ ! -f "$SCRIPT" ]]; then
    fail "Watcher script not found at $SCRIPT."
    fail "Expected the repo at $BRIDGE_ROOT. Set BRIDGE_ROOT=<path> to override."
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

# --- Step 3: write the systemd --user unit ---
section "Step 3: install user unit at $UNIT_PATH"

# Stop and disable any prior version cleanly.
if systemctl --user is-active --quiet "$UNIT_NAME" 2>/dev/null; then
    systemctl --user stop "$UNIT_NAME" 2>/dev/null || true
    ok 'Stopped existing service for clean reinstall'
fi
if systemctl --user is-enabled --quiet "$UNIT_NAME" 2>/dev/null; then
    systemctl --user disable "$UNIT_NAME" 2>/dev/null || true
fi

mkdir -p "$UNIT_DIR"
cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=Claude Code Bridge: filesystem-IPC daemon
Documentation=file://$BRIDGE_ROOT/IPC-PROTOCOL.md
After=default.target

[Service]
Type=simple
WorkingDirectory=$BRIDGE_ROOT
Environment=PYTHONUNBUFFERED=1
ExecStart=$PYTHON $SCRIPT
Restart=on-failure
RestartSec=2

# Drop privileges where systemd allows for a --user unit (most apply at session level already).
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
UNIT
ok "Wrote $UNIT_PATH"

# --- Step 4: enable and start the daemon ---
section 'Step 4: enable + start the daemon'
systemctl --user daemon-reload
systemctl --user enable --now "$UNIT_NAME"

sleep 1

if systemctl --user is-active --quiet "$UNIT_NAME"; then
    PID=$(systemctl --user show "$UNIT_NAME" --property=MainPID --value 2>/dev/null)
    ok "Daemon active (PID $PID)"
else
    fail "Daemon failed to start. Diagnostic output:"
    systemctl --user status "$UNIT_NAME" --no-pager | sed 's/^/    /'
    exit 1
fi

# Confirm the daemon logged its startup line
sleep 1
if [[ -f "$LOG_FILE" ]] && tail -n 5 "$LOG_FILE" | grep -q 'watcher starting'; then
    ok 'Daemon logged "watcher starting" successfully'
else
    warn "No 'watcher starting' line in $LOG_FILE yet. May still be initialising; check journalctl --user -u $UNIT_NAME"
fi

# --- Step 5: end-to-end self-test ---
section 'Step 5: end-to-end self-test (the real proof)'
REQ_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]')
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

DEADLINE=$(($(date +%s) + 15))
RESPONSE=''
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

if [[ -z "$RESPONSE" ]]; then
    fail 'Round-trip timed out after 15s. Service is enabled but not processing requests.'
    fail "Try: journalctl --user -u $UNIT_NAME -e"
    exit 1
fi

# --- Step 6: print final state ---
section 'Step 6: install complete'
echo "  Unit file:    $UNIT_PATH"
echo "  Service:      $UNIT_NAME (systemd --user)"
echo "  Daemon log:   $LOG_FILE"
echo
echo "  Useful commands:"
echo "    systemctl --user status $UNIT_NAME"
echo "    systemctl --user stop $UNIT_NAME"
echo "    systemctl --user start $UNIT_NAME"
echo "    journalctl --user -u $UNIT_NAME -e -f"
echo
echo "  Auto-starts at every login (or boot, if 'loginctl enable-linger' set for your user)."
echo "  To uninstall:"
echo "    systemctl --user disable --now $UNIT_NAME && rm $UNIT_PATH"
