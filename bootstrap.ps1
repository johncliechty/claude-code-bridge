# bootstrap.ps1 -- end-to-end installer for the Claude Code Bridge.
#
# This is the script the user's double-click experience runs. The flow:
#   1. Resolve Python (auto-install via winget if missing).
#   2. Resolve git (auto-install via winget if missing).
#   3. Clone (or update) https://github.com/johncliechty/claude-code-bridge to $InstallPath.
#   4. Create a venv + pip install -e . (so the .claude-plugin path works).
#   5. Invoke install-watcher.ps1 to register the IPC daemon Scheduled Task and self-test.
#
# Compatible with PowerShell 5.0+ Desktop. Idempotent. No admin required when winget
# uses --scope user. ASCII-only.
#
# INVOCATION FORMS supported (all four work -- that's the point of the wrapper below):
#   1. Direct file run:    powershell -ExecutionPolicy Bypass -File bootstrap.ps1
#   2. iex one-liner:      iex (iwr -useb 'https://.../bootstrap.ps1').Content
#   3. scriptblock form:   & ([scriptblock]::Create((iwr -useb '...').Content))
#   4. Via Install-Claude-Code-Bridge.bat (which uses form 3 internally).
#
# Forms 2-3 require the entire executable body to live inside a scriptblock
# (the `& { ... }` wrapper below), because [CmdletBinding()]+param() at the
# top-level of a script are illegal in expression context (iex) but legal
# inside a scriptblock.
#
# Optional overrides -- set these as env vars BEFORE running the installer:
#   $env:CCB_INSTALL_PATH         where to clone   (default: C:\dev\claude-code-bridge)
#   $env:CCB_REPO_URL             which repo URL   (default: johncliechty/claude-code-bridge)
#   $env:CCB_SKIP_VENV       = '1'  skip the .venv + pip install (IPC daemon only)
#   $env:CCB_NON_INTERACTIVE = '1'  never prompt; auto-confirm any installs

& {
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Host "PowerShell 5.0+ required (you have $($PSVersionTable.PSVersion))." -ForegroundColor Red
        exit 1
    }

    $ErrorActionPreference = 'Stop'

    # Overrides via env vars (previously script-level params).
    $InstallPath    = if ($env:CCB_INSTALL_PATH)     { $env:CCB_INSTALL_PATH }     else { 'C:\dev\claude-code-bridge' }
    $RepoUrl        = if ($env:CCB_REPO_URL)         { $env:CCB_REPO_URL }         else { 'https://github.com/johncliechty/claude-code-bridge' }
    $SkipVenv       = [bool]$env:CCB_SKIP_VENV
    $NonInteractive = [bool]$env:CCB_NON_INTERACTIVE

function Banner {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " Claude Code Bridge -- Installer" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "This installer will set up the Claude Code Bridge on this PC." -ForegroundColor Gray
    Write-Host "It will:" -ForegroundColor Gray
    Write-Host "  - Install Python 3.13 if missing (no admin needed)" -ForegroundColor Gray
    Write-Host "  - Install git if missing" -ForegroundColor Gray
    Write-Host "  - Clone the bridge to $InstallPath" -ForegroundColor Gray
    Write-Host "  - Register a background Scheduled Task that runs at logon" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Estimated time: 1-3 minutes. Internet connection required." -ForegroundColor Gray
    Write-Host ""
}

function Section($msg) { Write-Host ""; Write-Host "=== $msg ===" -ForegroundColor Cyan }
function OK($msg)      { Write-Host "  PASS: $msg" -ForegroundColor Green }
function Warn($msg)    { Write-Host "  WARN: $msg" -ForegroundColor Yellow }
function Fail($msg)    { Write-Host "  FAIL: $msg" -ForegroundColor Red }
function Info($msg)    { Write-Host "  INFO: $msg" -ForegroundColor Gray }

# --- Python resolver (mirror of install-watcher.ps1's) -------------------
# Trust by location: if python.exe lives at a known Python install path, it IS
# Python. Don't probe --version (`& $exe --version` doesn't capture stdout in
# all subprocess contexts; trusting the path is simpler and safer).
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
    $pathHit = Get-Command 'python.exe' -ErrorAction SilentlyContinue
    if ($pathHit -and ($pathHit.Source -notlike '*\WindowsApps\*') -and (Test-Path $pathHit.Source)) {
        return $pathHit.Source
    }
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

function Confirm-Action($prompt) {
    if ($NonInteractive) { return $true }
    if (-not [Environment]::UserInteractive) { return $true }
    $resp = Read-Host "  $prompt [Y/n]"
    return ($resp -eq '' -or $resp -match '^[Yy]')
}

function Resolve-Winget {
    $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if ($winget) { return $winget.Source }
    # Last-ditch: a few known absolute paths (winget service-context PATH is sometimes sparse)
    $candidates = @(
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Install-PythonViaWinget {
    $winget = Resolve-Winget
    if (-not $winget) {
        Fail "winget not found. Cannot auto-install Python."
        Info "Install Python 3.13 manually from https://www.python.org/downloads/ and re-run this installer."
        return $false
    }
    Write-Host "  Installing Python 3.13 via winget (user scope, no admin needed)..." -ForegroundColor Cyan
    & $winget install --id Python.Python.3.13 `
        --silent `
        --disable-interactivity `
        --accept-package-agreements `
        --accept-source-agreements `
        --scope user
    if ($LASTEXITCODE -ne 0) {
        Fail "winget install exited with code $LASTEXITCODE."
        return $false
    }
    OK "Python install finished."
    return $true
}

function Install-GitViaWinget {
    $winget = Resolve-Winget
    if (-not $winget) {
        Fail "winget not found. Cannot auto-install git."
        Info "Install Git for Windows manually from https://git-scm.com/download/win and re-run."
        return $false
    }
    Write-Host "  Installing Git via winget..." -ForegroundColor Cyan
    & $winget install --id Git.Git `
        --silent `
        --disable-interactivity `
        --accept-package-agreements `
        --accept-source-agreements `
        --scope user
    if ($LASTEXITCODE -ne 0) {
        Fail "winget install (Git) exited with code $LASTEXITCODE."
        return $false
    }
    OK "Git install finished."
    return $true
}

function Resolve-Git {
    $g = Get-Command 'git.exe' -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    # Fallback known locations (post-winget user-scope install)
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\git.exe",
        "C:\Program Files\Git\cmd\git.exe",
        "C:\Program Files\Git\bin\git.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

# --- Banner --------------------------------------------------------------
Banner

# --- Step 1: ensure Python ----------------------------------------------
Section 'Step 1: ensure Python 3.10+'
$python = Resolve-Python
if (-not $python) {
    Warn "Python 3.10+ not found."
    if (-not (Confirm-Action 'Install Python 3.13 via winget now?')) {
        Fail "Cannot continue without Python."
        exit 1
    }
    if (-not (Install-PythonViaWinget)) { exit 1 }
    $python = Resolve-Python
    if (-not $python) {
        Fail "Python was installed but is not yet resolvable."
        Info "Open a new PowerShell window and re-run this installer. (PATH propagates per-process; a new shell will see the install.)"
        exit 1
    }
}
OK "Python at $python"

# --- Step 2: ensure git --------------------------------------------------
Section 'Step 2: ensure git'
$git = Resolve-Git
if (-not $git) {
    Warn "git not found."
    if (-not (Confirm-Action 'Install Git for Windows via winget now?')) {
        Fail "Cannot continue without git."
        exit 1
    }
    if (-not (Install-GitViaWinget)) { exit 1 }
    $git = Resolve-Git
    if (-not $git) {
        Fail "Git was installed but is not yet resolvable."
        Info "Open a new PowerShell window and re-run this installer."
        exit 1
    }
}
OK "git at $git"

# --- Step 3: clone or update ---------------------------------------------
Section 'Step 3: clone or update repo'
$parent = Split-Path -Parent $InstallPath
if (-not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    OK "Created parent folder $parent"
}

if (Test-Path (Join-Path $InstallPath '.git')) {
    OK "Repo already present at $InstallPath; pulling latest"
    Push-Location $InstallPath
    try {
        & $git fetch --quiet origin 2>&1 | Out-Null
        & $git pull --ff-only --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Warn "git pull failed (probably local changes). Continuing with existing checkout."
        } else {
            OK "Repo updated to latest"
        }
    } finally {
        Pop-Location
    }
} else {
    if (Test-Path $InstallPath) {
        Fail "$InstallPath exists but is not a git repo. Move or rename it, then re-run."
        exit 1
    }
    Write-Host "  Cloning $RepoUrl -> $InstallPath" -ForegroundColor Cyan
    & $git clone $RepoUrl $InstallPath
    if ($LASTEXITCODE -ne 0) {
        Fail "git clone failed with exit code $LASTEXITCODE."
        exit 1
    }
    OK "Cloned successfully"
}

# --- Step 4: optional venv + pip install -e . ----------------------------
if (-not $SkipVenv) {
    Section 'Step 4: virtual environment + pip install'
    $venvPath = Join-Path $InstallPath '.venv'
    $venvPython = Join-Path $venvPath 'Scripts\python.exe'
    if (-not (Test-Path $venvPython)) {
        Write-Host "  Creating venv at $venvPath" -ForegroundColor Cyan
        & $python -m venv $venvPath
        if ($LASTEXITCODE -ne 0) {
            Fail "venv creation failed."
            exit 1
        }
        OK "venv created"
    } else {
        OK "venv already present at $venvPath"
    }

    # Upgrade pip silently
    Write-Host "  Upgrading pip..." -ForegroundColor Gray
    & $venvPython -m pip install --upgrade pip --quiet 2>&1 | Out-Null

    Write-Host "  Installing the bridge package (editable mode)..." -ForegroundColor Cyan
    Push-Location $InstallPath
    try {
        & $venvPython -m pip install -e . --quiet
        if ($LASTEXITCODE -ne 0) {
            Fail "pip install -e . failed."
            exit 1
        }
    } finally {
        Pop-Location
    }
    OK "Bridge package installed in venv. The .claude-plugin/ MCP entrypoint now works."
} else {
    Info "Skipping venv/pip step (SkipVenv set). The Claude Code plugin path will not work until you run pip install."
}

# --- Step 5: register the IPC daemon Scheduled Task ----------------------
Section 'Step 5: register IPC daemon Scheduled Task + self-test'
$installWatcher = Join-Path $InstallPath 'install-watcher.ps1'
if (-not (Test-Path $installWatcher)) {
    Fail "install-watcher.ps1 not found at $installWatcher (after clone)."
    exit 1
}
# Pass our resolved Python so the watcher script does not have to resolve again
& powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File $installWatcher `
    -PythonPath $python `
    -BridgeRoot $InstallPath
if ($LASTEXITCODE -ne 0) {
    Fail "install-watcher.ps1 exited with code $LASTEXITCODE."
    exit 1
}

# --- Done ----------------------------------------------------------------
Section 'BOOTSTRAP COMPLETE'
Write-Host "  Repo:           $InstallPath" -ForegroundColor Green
Write-Host "  Python:         $python" -ForegroundColor Green
if (-not $SkipVenv) {
    Write-Host "  venv Python:    $venvPython" -ForegroundColor Green
}
Write-Host "  Scheduled Task: ClaudeCodeBridgeWatcher (auto-starts at logon)" -ForegroundColor Green
Write-Host ""
Write-Host "What this means for the Cowork side:" -ForegroundColor Gray
Write-Host "  - The bridge daemon is running NOW and will auto-start at next logon." -ForegroundColor Gray
Write-Host "  - In a Cowork chat, the run_command MCP tool can now execute shell" -ForegroundColor Gray
Write-Host "    commands on this PC (with destructive-op gating)." -ForegroundColor Gray
Write-Host "  - See $InstallPath\M0.md for verification steps and troubleshooting." -ForegroundColor Gray
Write-Host ""

} # end of `& { ... }` iex-tolerance wrapper -- DO NOT add code after this brace.
