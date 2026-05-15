# install-watcher.ps1 -- one-shot installer + self-test for the filesystem-IPC bridge daemon.
#
# Run from a PowerShell window:
#   powershell -ExecutionPolicy Bypass -File C:\dev\claude-code-bridge\install-watcher.ps1
#
# Or pass an explicit Python path (used by bootstrap.ps1):
#   powershell -ExecutionPolicy Bypass -File install-watcher.ps1 -PythonPath C:\Python313\python.exe
#
# Safe to re-run. Idempotent. ASCII-only (no Unicode pitfalls).
# Compatible with PowerShell 5.1 Desktop (the default on Windows 10/11) and PS 7+.

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PythonPath = '',
    [string]$BridgeRoot = 'C:\dev\claude-code-bridge'
)

$ErrorActionPreference = 'Continue'
$bridgeRoot = $BridgeRoot
$script     = "$bridgeRoot\bridge\watcher.py"
$taskName   = 'ClaudeCodeBridgeWatcher'
$ipcInbox   = "$bridgeRoot\ipc\inbox"
$ipcOutbox  = "$bridgeRoot\ipc\outbox"
$logDir     = "$bridgeRoot\logs"
$logFile    = "$logDir\watcher.log"

function Section($msg) { Write-Host ""; Write-Host "=== $msg ===" -ForegroundColor Cyan }
function OK($msg)      { Write-Host "  PASS: $msg" -ForegroundColor Green }
function Warn($msg)    { Write-Host "  WARN: $msg" -ForegroundColor Yellow }
function Fail($msg)    { Write-Host "  FAIL: $msg" -ForegroundColor Red }
function Info($msg)    { Write-Host "  INFO: $msg" -ForegroundColor Gray }

# --- Python resolver -----------------------------------------------------
# Strategy: search known Python install locations and return the first existing
# one. We don't probe with `--version` because (a) the known paths are well-
# defined Python install locations - if python.exe lives there, it's Python -
# and (b) `& $exe --version` doesn't reliably capture stdout in all subprocess
# contexts (the Cowork-host bridge service shell is a real case in point).
# Filters out the Microsoft Store stub which is a launcher, not a Python.
function Resolve-Python {
    $up = $env:USERPROFILE
    $known = @(
        "$up\AppData\Local\Programs\Python\Python313\python.exe",
        "$up\AppData\Local\Programs\Python\Python312\python.exe",
        "$up\AppData\Local\Programs\Python\Python311\python.exe",
        "$up\AppData\Local\Programs\Python\Python310\python.exe",
        "C:\Program Files\Python313\python.exe",
        "C:\Program Files\Python312\python.exe",
        "C:\Program Files\Python311\python.exe",
        "C:\Program Files\Python310\python.exe",
        "C:\Python313\python.exe",
        "C:\Python312\python.exe",
        "C:\Python311\python.exe",
        "C:\Python310\python.exe"
    )
    foreach ($p in $known) {
        if (Test-Path $p) { return $p }
    }
    # PATH-based fallback (excluding the Microsoft Store stub)
    $pathHit = Get-Command 'python.exe' -ErrorAction SilentlyContinue
    if ($pathHit -and ($pathHit.Source -notlike '*\WindowsApps\*') -and (Test-Path $pathHit.Source)) {
        return $pathHit.Source
    }
    # Last resort: ask the py launcher (with Start-Process so stdout is captured reliably)
    $pyLauncher = Get-Command 'py.exe' -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        $tmpOut = [System.IO.Path]::GetTempFileName()
        try {
            $proc = Start-Process -FilePath $pyLauncher.Source `
                -ArgumentList '-3','-c','import sys; print(sys.executable)' `
                -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput $tmpOut
            if ($proc.ExitCode -eq 0) {
                $resolved = (Get-Content $tmpOut -Raw).Trim()
                if ($resolved -and (Test-Path $resolved)) { return $resolved }
            }
        } catch { } finally {
            Remove-Item $tmpOut -ErrorAction SilentlyContinue
        }
    }
    return $null
}

function Install-PythonViaWinget {
    $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if (-not $winget) {
        Fail "winget (Windows Package Manager) is not available."
        Info "Install Python 3.13 manually from https://www.python.org/downloads/ and re-run this script."
        return $false
    }
    Write-Host ""
    Write-Host "  Installing Python 3.13 via winget (user scope, no admin needed)..." -ForegroundColor Cyan
    Write-Host "  This usually takes ~30 seconds." -ForegroundColor Gray
    & $winget.Source install --id Python.Python.3.13 `
        --silent `
        --disable-interactivity `
        --accept-package-agreements `
        --accept-source-agreements `
        --scope user
    if ($LASTEXITCODE -ne 0) {
        Fail "winget install exited with code $LASTEXITCODE."
        Info "Try installing manually from https://www.python.org/downloads/ and re-run."
        return $false
    }
    OK "Python install finished. Re-resolving..."
    return $true
}

# --- Step 1: prerequisites and folders ---
Section 'Step 1: prerequisites'

# Python: caller-provided > resolver > winget-install > resolver
if ($PythonPath -and (Test-Path $PythonPath)) {
    $python = $PythonPath
    OK "Python at $python (provided by caller)"
} else {
    $python = Resolve-Python
    if (-not $python) {
        Warn "Python 3.10+ not found on this machine."
        # Headless mode: if this script was invoked with no console (e.g. by a
        # parent installer that already handled the prompt), do the install
        # automatically. Otherwise prompt.
        $autoInstall = $true
        if ([Environment]::UserInteractive -and $Host.UI.RawUI) {
            $resp = Read-Host "  Install Python 3.13 via winget now? [Y/n]"
            $autoInstall = ($resp -eq '' -or $resp -match '^[Yy]')
        }
        if (-not $autoInstall) {
            Fail "Cannot proceed without Python."
            exit 1
        }
        if (-not (Install-PythonViaWinget)) { exit 1 }
        $python = Resolve-Python
        if (-not $python) {
            Fail "Python was installed but is not yet resolvable on this PATH."
            Info "Open a new PowerShell window and re-run this script. (PATH propagates per-process; the new shell will see the install.)"
            exit 1
        }
    }
    OK "Python at $python"
}

if (-not (Test-Path $script)) {
    Fail "Watcher script not found at $script."
    Info "Make sure the repo was cloned to $bridgeRoot. See M0.md for the one-step installer."
    exit 1
}
OK "Watcher script at $script"

New-Item -ItemType Directory -Path $ipcInbox  -Force | Out-Null
New-Item -ItemType Directory -Path $ipcOutbox -Force | Out-Null
New-Item -ItemType Directory -Path $logDir    -Force | Out-Null
OK "IPC folders: $ipcInbox, $ipcOutbox"
OK "Log folder: $logDir"

# --- Step 2: import smoke test ---
Section 'Step 2: bridge.shell imports cleanly'
$importTest = & $python -c "import sys; sys.path.insert(0, r'$bridgeRoot'); from bridge.shell import run_command; from bridge.permissions import is_destructive; print('OK')" 2>&1
if ($LASTEXITCODE -ne 0 -or $importTest -notmatch 'OK') {
    Fail "bridge.shell import failed:"
    Write-Host $importTest
    exit 1
}
OK 'bridge.shell + bridge.permissions importable'

# --- Step 3: register Scheduled Task ---
Section 'Step 3: register Scheduled Task'
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    OK "Removed existing task '$taskName' for clean reinstall"
}

$action = New-ScheduledTaskAction `
    -Execute $python `
    -Argument "`"$script`"" `
    -WorkingDirectory $bridgeRoot

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0)

$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

try {
    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description 'Claude Code Bridge: filesystem-IPC daemon. Watches ipc/inbox for shell commands; executes them; writes results to ipc/outbox.' `
        | Out-Null
    OK "Scheduled task '$taskName' registered (runs at logon, auto-restart on failure)"
} catch {
    Fail "Could not register task: $_"
    exit 1
}

# --- Step 4: start daemon now ---
Section 'Step 4: start the daemon now'

# Kill any straggler python process running watcher.py
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'watcher\.py' } | ForEach-Object {
    try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
}
Start-Sleep -Milliseconds 500

# Spawn the daemon DIRECTLY via Start-Process. We don't rely on Start-ScheduledTask
# because Windows refuses to manually fire AtLogOn-triggered tasks with LogonType=Interactive
# (it returns SCHED_S_TASK_HAS_NOT_RUN / 0x41301). The Scheduled Task in Step 3 is still
# there for auto-start at the next logon and on auto-restart after a crash.
$proc = Start-Process `
    -FilePath $python `
    -ArgumentList "`"$script`"" `
    -WorkingDirectory $bridgeRoot `
    -WindowStyle Hidden `
    -PassThru `
    -ErrorAction SilentlyContinue

if ($proc) {
    OK "Daemon spawned (PID $($proc.Id))"
} else {
    Fail 'Could not Start-Process the daemon'
    exit 1
}

# Verify the spawned process is alive. We use the PID we got from Start-Process -PassThru
# rather than scanning CommandLines via CIM, because CIM Win32_Process.CommandLine is empty
# on some Windows configs without admin rights (a false-negative trap that caused earlier
# installs to report FAIL even though the daemon was running perfectly).
Start-Sleep -Milliseconds 800  # let the daemon's __init__ + initial log line settle

$proc = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
if ($null -eq $proc -or $proc.HasExited) {
    Fail 'Daemon process exited immediately. Diagnostics below:'
    if (Test-Path $logFile) {
        Write-Host '  --- last 30 lines of watcher.log ---'
        Get-Content $logFile -Tail 30 | ForEach-Object { Write-Host "    $_" }
    } else {
        Warn "No $logFile yet. Daemon may have crashed before logging."
    }
    Write-Host '  --- running daemon in foreground for 2s to capture stderr ---'
    $tmpOut = New-TemporaryFile
    $tmpErr = New-TemporaryFile
    $fgProc = Start-Process -FilePath $python -ArgumentList "`"$script`"" `
        -WorkingDirectory $bridgeRoot -NoNewWindow -PassThru `
        -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
    Start-Sleep -Seconds 2
    try { Stop-Process -Id $fgProc.Id -Force -ErrorAction SilentlyContinue } catch {}
    if (Test-Path $tmpOut) { Write-Host '  stdout:'; Get-Content $tmpOut | ForEach-Object { Write-Host "    $_" } }
    if (Test-Path $tmpErr) { Write-Host '  stderr:'; Get-Content $tmpErr | ForEach-Object { Write-Host "    $_" } }
    Remove-Item $tmpOut,$tmpErr -ErrorAction SilentlyContinue
    exit 1
}
OK "Daemon running (PID $($proc.Id))"

# Sanity check: confirm the daemon logged its startup line
if (Test-Path $logFile) {
    $lastLog = Get-Content $logFile -Tail 5 | Out-String
    if ($lastLog -match 'watcher starting') {
        OK 'Daemon logged "watcher starting" successfully'
    } else {
        Warn 'Daemon process is alive but no "watcher starting" line yet (may still be initialising)'
    }
}

# --- Step 5: end-to-end round-trip test ---
# This is the AUTHORITATIVE liveness check. If the round-trip succeeds, the daemon
# is provably handling requests regardless of what process-listing returns.
Section 'Step 5: end-to-end self-test (the real proof)'
$reqId = [guid]::NewGuid().ToString()
$reqPath = Join-Path $ipcInbox "$reqId.json"
$outPath = Join-Path $ipcOutbox "$reqId.json"
$reqBody = @{
    request_id = $reqId
    command    = "Write-Output 'bridge-selftest-ok'"
    shell      = 'powershell'
    timeout    = 10
} | ConvertTo-Json -Compress

$tmpPath = "$reqPath.tmp"
[System.IO.File]::WriteAllText($tmpPath, $reqBody, [System.Text.UTF8Encoding]::new($false))
Move-Item -Path $tmpPath -Destination $reqPath -Force
Write-Host "  request written: $reqPath"

$deadline = (Get-Date).AddSeconds(15)
$response = $null
while ((Get-Date) -lt $deadline) {
    if (Test-Path $outPath) {
        try {
            $raw = [System.IO.File]::ReadAllText($outPath)
            $response = $raw | ConvertFrom-Json
            break
        } catch {
            Start-Sleep -Milliseconds 50
            continue
        }
    }
    Start-Sleep -Milliseconds 100
}

if (-not $response) {
    Fail "No response from daemon within 15s. Inbox file still present: $(Test-Path $reqPath). Check $logFile."
    if (Test-Path $logFile) { Get-Content $logFile -Tail 20 | ForEach-Object { Write-Host "    $_" } }
    exit 1
}

OK "round-trip completed: exit_code=$($response.exit_code), duration=$([math]::Round($response.duration_ms,1))ms"
if ($response.stdout -match 'bridge-selftest-ok') {
    OK "stdout contains expected token 'bridge-selftest-ok'"
} else {
    Fail "stdout does NOT contain expected token. Got: $($response.stdout)"
    exit 1
}

Remove-Item -Path $outPath -Force -ErrorAction SilentlyContinue

# --- Step 6: destructive-op gate test ---
Section 'Step 6: destructive-op gate'
$reqId2 = [guid]::NewGuid().ToString()
$reqPath2 = Join-Path $ipcInbox "$reqId2.json"
$outPath2 = Join-Path $ipcOutbox "$reqId2.json"
$reqBody2 = @{
    request_id = $reqId2
    command    = "rm -rf /tmp"
    shell      = 'bash'
} | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText("$reqPath2.tmp", $reqBody2, [System.Text.UTF8Encoding]::new($false))
Move-Item -Path "$reqPath2.tmp" -Destination $reqPath2 -Force

$deadline = (Get-Date).AddSeconds(10)
$resp2 = $null
while ((Get-Date) -lt $deadline) {
    if (Test-Path $outPath2) {
        try { $resp2 = [System.IO.File]::ReadAllText($outPath2) | ConvertFrom-Json; break }
        catch { Start-Sleep -Milliseconds 50 }
    }
    Start-Sleep -Milliseconds 100
}
if (-not $resp2) {
    Warn 'Destructive-op test: no response. Skipping check.'
} elseif ($resp2.blocked_by_gate -eq 'destructive_op') {
    OK "destructive-op blocked correctly: $($resp2.reason)"
} else {
    Fail "destructive-op was NOT blocked. blocked_by_gate=$($resp2.blocked_by_gate)"
}
Remove-Item -Path $outPath2 -Force -ErrorAction SilentlyContinue

# --- Done ---
Section 'INSTALL COMPLETE'
Write-Host "  Scheduled Task: $taskName (auto-starts at logon)" -ForegroundColor Green
Write-Host "  IPC inbox:      $ipcInbox" -ForegroundColor Green
Write-Host "  IPC outbox:     $ipcOutbox" -ForegroundColor Green
Write-Host "  Daemon log:     $logFile" -ForegroundColor Green
Write-Host ""
Write-Host 'To check daemon status:  Get-ScheduledTaskInfo -TaskName ClaudeCodeBridgeWatcher' -ForegroundColor Gray
Write-Host "To tail the log:         Get-Content $logFile -Wait -Tail 20" -ForegroundColor Gray
Write-Host 'To uninstall:            Unregister-ScheduledTask -TaskName ClaudeCodeBridgeWatcher -Confirm:$false' -ForegroundColor Gray
