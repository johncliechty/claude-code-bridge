# run-overnight.ps1
# Bulletproof unattended bridge build finisher.
# - Runs in background (spawned via Start-Process -WindowStyle Hidden).
# - Never prompts — handles all errors internally.
# - Sources ANTHROPIC_API_KEY from C:\dev\Agentic-Home\.env if not in env.
# - Logs everything to C:\dev\claude-code-bridge\logs\overnight-<timestamp>.log.
# - Writes a machine-readable summary to C:\dev\claude-code-bridge\STATUS.json
#   on completion so the next session can pick up cleanly.
# - Idempotent — safe to re-run.

$ErrorActionPreference = 'Continue'  # Never abort: we want a full log no matter what.
$bridgeRoot = 'C:\dev\claude-code-bridge'
$timestamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
$logDir = Join-Path $bridgeRoot 'logs'
$logFile = Join-Path $logDir "overnight-$timestamp.log"
$statusFile = Join-Path $bridgeRoot 'STATUS.json'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Log {
    param([string]$msg)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
}

$status = [ordered]@{
    started_at = (Get-Date -Format o)
    bridge_root = $bridgeRoot
    log_file = $logFile
    steps = @()
    overall_status = 'in_progress'
    completed_at = $null
}

function RecordStep {
    param([string]$name, [string]$result, [string]$detail = '')
    $status.steps += [ordered]@{ name = $name; result = $result; detail = $detail; at = (Get-Date -Format o) }
    Log "STEP $name -> $result. $detail"
}

Log "=== overnight build starting ==="
Log "bridgeRoot: $bridgeRoot"
Log "PowerShell: $($PSVersionTable.PSVersion)"
Log "User: $env:USERNAME"
Log "Host: $env:COMPUTERNAME"

try {
    # Step 1: cwd
    Set-Location $bridgeRoot -ErrorAction Stop
    Log "cwd: $(Get-Location)"

    # Step 2: source ANTHROPIC_API_KEY from .env if not already set
    if (-not $env:ANTHROPIC_API_KEY) {
        $envFile = 'C:\dev\Agentic-Home\.env'
        if (Test-Path $envFile) {
            $keyLine = Get-Content $envFile | Where-Object { $_ -match '^ANTHROPIC_API_KEY=' } | Select-Object -First 1
            if ($keyLine) {
                $rawValue = ($keyLine -split '=', 2)[1]
                $env:ANTHROPIC_API_KEY = $rawValue.Trim().Trim('"').Trim("'")
                RecordStep 'source_api_key' 'success' "Loaded from $envFile (length: $($env:ANTHROPIC_API_KEY.Length))"
            } else {
                RecordStep 'source_api_key' 'warn' "ANTHROPIC_API_KEY line not found in $envFile"
            }
        } else {
            RecordStep 'source_api_key' 'warn' "$envFile does not exist; SDK-dependent tests may fail"
        }
    } else {
        RecordStep 'source_api_key' 'success' 'Already set in env (length: ' + $env:ANTHROPIC_API_KEY.Length + ')'
    }

    # Step 3: activate venv
    $venvActivate = Join-Path $bridgeRoot '.venv\Scripts\Activate.ps1'
    if (Test-Path $venvActivate) {
        try {
            . $venvActivate
            RecordStep 'activate_venv' 'success' '.venv activated'
        } catch {
            RecordStep 'activate_venv' 'fail' "exception: $($_.Exception.Message)"
        }
    } else {
        RecordStep 'activate_venv' 'warn' '.venv not found at expected path; using system python'
    }

    # Step 4: pip install -e . (picks up new mcp, pytest-asyncio deps)
    Log "Running pip install -e ."
    $pipStart = Get-Date
    $pipOutput = & python -m pip install -e . --quiet --no-input 2>&1 | Out-String
    $pipDuration = ((Get-Date) - $pipStart).TotalSeconds
    Add-Content -Path $logFile -Value "--- pip install output (${pipDuration}s) ---"
    Add-Content -Path $logFile -Value $pipOutput
    if ($LASTEXITCODE -eq 0) {
        RecordStep 'pip_install' 'success' "took ${pipDuration}s"
    } else {
        RecordStep 'pip_install' 'fail' "exit code $LASTEXITCODE; see log"
    }

    # Step 5: pytest the full suite (Phase 1 smoke + Phase 2 permissions + Phase 3 MCP)
    Log "Running pytest tests/ -v --tb=short"
    $pytestStart = Get-Date
    $pytestOutput = & python -m pytest tests/ -v --tb=short --color=no 2>&1 | Out-String
    $pytestDuration = ((Get-Date) - $pytestStart).TotalSeconds
    Add-Content -Path $logFile -Value "--- pytest output (${pytestDuration}s) ---"
    Add-Content -Path $logFile -Value $pytestOutput

    # Extract a brief summary line from pytest output
    $pytestSummary = ''
    foreach ($line in ($pytestOutput -split "`n")) {
        if ($line -match '(passed|failed|error|skipped)') {
            $pytestSummary = $line.Trim()
        }
    }

    if ($LASTEXITCODE -eq 0) {
        RecordStep 'pytest' 'success' "all tests pass. $pytestSummary"
        $status.pytest_summary = $pytestSummary
    } else {
        RecordStep 'pytest' 'fail' "exit code $LASTEXITCODE. $pytestSummary"
        $status.pytest_summary = $pytestSummary
    }

    # Step 6: git add + commit (only if changes exist)
    $gitStatus = & git status --porcelain 2>&1 | Out-String
    if ($gitStatus.Trim() -ne '') {
        Log "Git: changes detected; staging and committing"
        & git add . 2>&1 | Out-Null
        $commitMsg = "v0.1.0: phase 2 (permission gates) + phase 3 (MCP server stdio) + overnight verification"
        $commitOutput = & git commit -m $commitMsg 2>&1 | Out-String
        Add-Content -Path $logFile -Value "--- git commit output ---"
        Add-Content -Path $logFile -Value $commitOutput
        if ($LASTEXITCODE -eq 0) {
            $sha = (& git rev-parse --short HEAD 2>&1).Trim()
            RecordStep 'git_commit' 'success' "commit $sha"
            $status.commit_sha = $sha
        } else {
            RecordStep 'git_commit' 'fail' "commit failed; see log"
        }
    } else {
        RecordStep 'git_commit' 'skipped' 'no changes to commit'
    }

    # Step 7: list final state for the morning report
    $listing = & Get-ChildItem -Recurse $bridgeRoot -Exclude .venv,__pycache__,.git,logs,.pytest_cache 2>&1 |
        Select-Object -ExpandProperty FullName |
        Out-String
    Add-Content -Path $logFile -Value "--- final file listing ---"
    Add-Content -Path $logFile -Value $listing

    $gitLog = & git log --oneline -n 10 2>&1 | Out-String
    Add-Content -Path $logFile -Value "--- recent git log ---"
    Add-Content -Path $logFile -Value $gitLog

    # Determine overall status: success only if pip + pytest both passed
    $pipStep = $status.steps | Where-Object { $_.name -eq 'pip_install' } | Select-Object -First 1
    $pytestStep = $status.steps | Where-Object { $_.name -eq 'pytest' } | Select-Object -First 1
    if ($pipStep.result -eq 'success' -and $pytestStep.result -eq 'success') {
        $status.overall_status = 'success'
    } elseif ($pytestStep.result -eq 'fail') {
        $status.overall_status = 'tests_failed'
    } else {
        $status.overall_status = 'partial'
    }

} catch {
    $errMsg = $_.Exception.Message
    Log "UNHANDLED EXCEPTION: $errMsg"
    RecordStep 'unhandled_exception' 'fail' $errMsg
    $status.overall_status = 'failed_with_exception'
}

$status.completed_at = (Get-Date -Format o)
try {
    $status | ConvertTo-Json -Depth 5 | Set-Content -Path $statusFile -Encoding UTF8
} catch {
    Log "Failed to write STATUS.json: $($_.Exception.Message)"
}
Log "=== overnight build done. overall_status: $($status.overall_status) ==="
Log "Status file: $statusFile"
Log "Log file:    $logFile"
