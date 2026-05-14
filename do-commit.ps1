#Requires -Version 5.1
# One-shot v0.3.0 commit script. Invoked from the Cowork session via the
# claude-code-bridge MCP. Self-deletes when done.
$ErrorActionPreference = 'Stop'
$root = 'C:\dev\claude-code-bridge'
Set-Location $root

$git = 'C:\Program Files\Git\bin\git.exe'
if (-not (Test-Path $git)) { $git = 'C:\Program Files\Git\cmd\git.exe' }
if (-not (Test-Path $git)) { throw "git.exe not found on host" }

# Clean any stale lock
Get-ChildItem "$root\.git\*.lock" -ErrorAction SilentlyContinue | Remove-Item -Force

$log = "$root\commit-log.tmp"
"--- starting at $(Get-Date -Format o) ---" | Out-File $log -Encoding utf8

& $git status --short *>> $log
"--- staging all ---" | Out-File $log -Append -Encoding utf8
& $git add -A *>> $log
"--- staged status ---" | Out-File $log -Append -Encoding utf8
& $git status --short *>> $log
"--- committing ---" | Out-File $log -Append -Encoding utf8
$msgFile = "$root\COMMIT_MSG.tmp"
& $git commit -F $msgFile *>> $log
$commitExit = $LASTEXITCODE
"--- commit exit code: $commitExit ---" | Out-File $log -Append -Encoding utf8
"--- log ---" | Out-File $log -Append -Encoding utf8
& $git log --oneline -5 *>> $log
"--- remotes ---" | Out-File $log -Append -Encoding utf8
& $git remote -v *>> $log

# Clean up COMMIT_MSG.tmp if commit succeeded
if ($commitExit -eq 0) {
    Remove-Item $msgFile -Force -ErrorAction SilentlyContinue
}

Write-Output "done; see commit-log.tmp; commit_exit=$commitExit"
