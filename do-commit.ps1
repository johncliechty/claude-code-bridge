#Requires -Version 5.1
# One-shot v0.3.0 commit script using Start-Process to avoid the
# "Cannot run a document in the middle of a pipeline" issue with git.exe
# inside the bridge's non-interactive PowerShell.

$ErrorActionPreference = 'Continue'
$root = 'C:\dev\claude-code-bridge'
Set-Location $root

$git = 'C:\Program Files\Git\bin\git.exe'
if (-not (Test-Path $git)) { $git = 'C:\Program Files\Git\cmd\git.exe' }
if (-not (Test-Path $git)) { throw "git.exe not found on host" }

# Clean any stale locks
Get-ChildItem "$root\.git\*.lock" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

$log = "$root\commit-log.tmp"
"start $(Get-Date -Format o)" | Out-File $log -Encoding utf8

function RunGit([string[]]$gitArgs, [string]$tag) {
    $outFile = "$root\__gitout.tmp"
    $errFile = "$root\__giterr.tmp"
    $p = Start-Process -FilePath $git -ArgumentList $gitArgs -NoNewWindow -Wait -PassThru -WorkingDirectory $root -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    "--- $tag (exit=$($p.ExitCode)) ---" | Out-File $log -Append -Encoding utf8
    if (Test-Path $outFile) { Get-Content $outFile -Raw | Out-File $log -Append -Encoding utf8 -NoNewline }
    "--- stderr ---" | Out-File $log -Append -Encoding utf8
    if (Test-Path $errFile) { Get-Content $errFile -Raw | Out-File $log -Append -Encoding utf8 -NoNewline }
    Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
    return $p.ExitCode
}

RunGit @('status','--short') 'status-before'
RunGit @('add','-A') 'add-all'
RunGit @('status','--short') 'status-staged'
$commitExit = RunGit @('commit','-F',"$root\COMMIT_MSG.tmp") 'commit'
RunGit @('log','--oneline','-5') 'log'
RunGit @('remote','-v') 'remotes'

if ($commitExit -eq 0) {
    Remove-Item "$root\COMMIT_MSG.tmp" -Force -ErrorAction SilentlyContinue
}

"done commit_exit=$commitExit" | Out-File $log -Append -Encoding utf8
Write-Output "commit_exit=$commitExit"
