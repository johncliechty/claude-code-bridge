# Known issues — claude-code-bridge v0.3.0

Logged 2026-05-14 from a real session that hit each issue. Listed in order of severity / how often they bite.

## 1. Bridge can't invoke git binaries (high severity for any git workflow)

**Symptom.** Running `git --version` (or any git operation) via `mcp__Claude_Code_Bridge__run_command` produces exit code 0 with empty stdout. Routing through PowerShell's pipeline triggers *"Cannot run a document in the middle of a pipeline: C:\Program Files\Git\bin\git.exe."* Routing through `cmd` shell hangs until timeout.

**Root cause (working hypothesis).** The bridge daemon spawns child shells in a way that's hostile to git's stdout/stderr handling. Git on Windows opens console handles that work fine under an interactive shell but fail under the daemon's non-interactive child-process model. PowerShell's "document in pipeline" error is a downstream symptom — it kicks in when PowerShell tries to invoke a native binary it can't pipe.

**Workaround.** For git operations, run a host-side PowerShell script (a `.ps1` file launched via `powershell.exe -File`) and capture output to a log file using `Start-Process -RedirectStandardOutput`. Even that fails inside the bridge — but if the user runs the same script from a real PowerShell terminal, it works. So: write the script via the bridge; tell the user to run it once. One paste, not ten typed commands.

**Status:** unresolved. Pending diagnosis of `bridge/watcher.py`'s `bridge.shell.run_command` to see whether it spawns with a TTY-attached stdin/stdout pair or not. If not, attaching a fake TTY (via `ConPTY` on Windows) may fix it.

## 2. PATH inherited by the bridge's PowerShell is incomplete (medium)

**Symptom.** `git`, `gh`, and other commonly-installed binaries are on the System PATH but `git`/`gh`/etc. are reported as "not recognized as the name of a cmdlet, function, script file, or operable program" when invoked plainly via `mcp__Claude_Code_Bridge__run_command` with `shell: "powershell"`.

**Note.** `$env:Path -split ';'` inside the same invocation *does* show `C:\Program Files\Git\cmd` is present. So the PATH variable looks right; PowerShell's command-resolution lookup along that PATH is failing. This is correlated with issue #1 above — it's likely the same root cause (the daemon's child-process model breaks something about how Windows resolves and invokes external commands).

**Workaround.** Use the full path with the call operator: `& 'C:\Program Files\Git\bin\git.exe' --version`. The invocation parses OK (no "not recognized" error) but stdout still gets lost — issue #1 again.

**Status:** correlated with #1; probably same fix.

## 3. cmd shell escapes nested double-quotes wrong (medium)

**Symptom.** Sending `cd /d C:\dev && "C:\Program Files\Git\bin\git.exe" --version` through `shell: "cmd"` results in cmd seeing `'\"C:\Program Files\Git\bin\git.exe\"'` (the quotes have been backslash-escaped). cmd errors with *"is not recognized as an internal or external command."*

**Root cause.** The bridge's request-to-shell adapter escapes quotes for safety but does so unconditionally, breaking commands that legitimately need quoted paths.

**Workaround.** Stick to paths without spaces, or rely on PATH (which is also broken — see #2). Practically: use PowerShell shell with `& 'path with spaces'` syntax — but that hits #1.

**Status:** unresolved. The fix is in the watcher's command-prep layer.

## 4. Outbox files can't be unlinked from the sandbox side (low)

**Symptom.** A Cowork session writing a request and reading the response can't subsequently `os.unlink()` the outbox file. PermissionError / Operation not permitted across the host-sandbox mount.

**Root cause.** The daemon writes the response file with host-user permissions; the sandbox is a different user (`festive-trusting-carson`) and lacks delete permissions on host-owned files.

**Workaround.** None needed for correctness — the daemon auto-cleans outbox files after 5 minutes. Just leaves stale files for that window.

**Status:** harmless but cosmetic. Fix: have the daemon `chmod 0o666` (or set Windows ACL equivalent) on outbox files at write time so any reader can clean up.

## 5. Sandbox-host mount has stale cache on `.git/index.lock` (low, intermittent)

**Symptom.** Git operations from the Cowork sandbox (via `mcp__workspace__bash`) fail with *"fatal: Unable to create '...index.lock': File exists"* even immediately after the host has confirmed the lock is gone via `Test-Path` returning False. The sandbox's `stat`/`ls` show the lock file existing; the host's `Test-Path` shows it doesn't.

**Root cause.** The Linux sandbox's mount of the Windows host folder caches directory entries; deletes from the host side don't always invalidate the sandbox's cached entries promptly. This shows up especially for short-lived files like `.git/*.lock`.

**Workaround.** None reliable. The lock survives `git reset` style operations from the sandbox because git can't unlink across this cache mismatch. Forcing a delete from the host side (via this bridge) clears it from the host but not from the sandbox cache.

**Status:** open. Probably out of scope for the bridge itself; this is a Cowork mount-layer concern. But it makes git workflows from the sandbox unreliable enough that users should be told to run their `.git`-touching commands host-side, not sandbox-side.

---

## Summary of practical impact

For routine bridge usage — `echo`, file operations, `Test-Path`, `Get-ChildItem`, `Remove-Item`, simple cmdlets, `Set-Location`, registry reads, etc. — the bridge is solid (~170-200ms round-trips, consistent across days). Issues #1-#3 above bite specifically for external binary invocation and file-path-with-spaces cases. Issue #4 is cosmetic. Issue #5 is a Cowork mount concern, not a bridge concern.

Until #1 is fixed, git workflows that need to happen on the host should be packaged as `.ps1` scripts written to disk by the bridge, then executed manually by the user in a real PowerShell session. That's one paste, not ten typed commands — still a net win versus pre-bridge, but not the seamless host-shell experience the bridge aspires to.

A future Phase 5 of the bridge that attaches a `ConPTY` to the spawned child process is likely the right fix for #1, #2, and #3 together — they all smell like the same TTY/console-handle root cause.
