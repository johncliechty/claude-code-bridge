# Known issues — claude-code-bridge v0.3.0

Logged 2026-05-14 from a real session that hit each issue. Listed in order of severity / how often they bite.

## 1. Bridge can't capture stdout from script-spawned binaries (medium — bigger bark than bite)

**Symptom (first half).** Running `git --version` (or any external-binary operation) inline via `mcp__Claude_Code_Bridge__run_command` produces exit code 0 with empty stdout. Routing through PowerShell's pipeline triggers *"Cannot run a document in the middle of a pipeline: C:\Program Files\Git\bin\git.exe."* Routing through `cmd` shell hangs until timeout.

**Refined picture after 2026-05-14 retesting.** The bridge **can** run host-side `.ps1` scripts that invoke external binaries via `Start-Process -FilePath $exe -ArgumentList ... -RedirectStandardOutput $out -RedirectStandardError $err`. The binary runs, exit codes are correct, side effects happen. The bridge just **silently drops the stdout** of the spawned PowerShell process — `Write-Output` from inside the script never makes it back to the MCP response. So the bridge IS capable of running multi-step workflows; what it can't do is *report* their output back inline.

**Workaround that works.** Write a `.ps1` to disk via the bridge that:

- Invokes binaries via `Start-Process` with `-RedirectStandardOutput` / `-RedirectStandardError` pointing at files in `$env:TEMP` (not the working dir — those get tracked by `git add -A`).
- Appends a structured transcript to a `.log` file in `$env:TEMP`.
- Self-deletes on success.

Then invoke the script via `mcp__Claude_Code_Bridge__run_command` with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script>`. The bridge won't show you the output, but the work happens. Read the transcript file afterward via a second `mcp__Claude_Code_Bridge__run_command` (or via the Read tool if the file is in a mounted folder).

**Root cause (working hypothesis).** The bridge daemon's stdout capture for spawned child processes uses pipes that either close prematurely or aren't drained when the child terminates quickly. The "document in pipeline" PowerShell error from inline invocations is the same root cause showing through a different surface — PowerShell tries to set up a pipeline that the daemon's child-process model doesn't support.

**Status:** unresolved at the daemon level, but the file-redirect workaround is good enough that workflows from Cowork sessions complete end-to-end as long as the script is structured to log to disk.

## 2. PATH inherited by the bridge's PowerShell is incomplete in practice (medium)

**Symptom.** `git`, `gh`, and other commonly-installed binaries are on the System PATH but `git`/`gh`/etc. are reported as "not recognized as the name of a cmdlet, function, script file, or operable program" when invoked plainly via `mcp__Claude_Code_Bridge__run_command` with `shell: "powershell"`.

**Note.** `$env:Path -split ';'` inside the same invocation *does* show `C:\Program Files\Git\cmd` is present. So the PATH variable looks right; PowerShell's command-resolution lookup along that PATH is failing. This is correlated with issue #1 above — it's likely the same root cause (the daemon's child-process model breaks something about how Windows resolves and invokes external commands).

**Workaround.** Use the full path with the call operator: `& 'C:\Program Files\Git\bin\git.exe' --version`. The invocation parses OK (no "not recognized" error) but stdout still gets lost — issue #1 again. For multi-binary workflows where one binary spawns another, the spawned binary may ALSO fail to find its dependencies — see issue #6.

**Status:** correlated with #1; probably same fix.

## 3. cmd shell escapes nested double-quotes wrong (medium)

**Symptom.** Sending `cd /d C:\dev && "C:\Program Files\Git\bin\git.exe" --version` through `shell: "cmd"` results in cmd seeing `'\"C:\Program Files\Git\bin\git.exe\"'` (the quotes have been backslash-escaped). cmd errors with *"is not recognized as an internal or external command."*

**Root cause.** The bridge's request-to-shell adapter escapes quotes for safety but does so unconditionally, breaking commands that legitimately need quoted paths.

**Workaround.** Stick to paths without spaces, or rely on PATH (which is also broken — see #2). Practically: use PowerShell shell with `& 'path with spaces'` syntax — but that hits #1.

**Status:** unresolved. The fix is in the watcher's command-prep layer.

## 4. Outbox files can't be unlinked from the sandbox side (low)

**Symptom.** A Cowork session writing a request and reading the response can't subsequently `os.unlink()` the outbox file. PermissionError / Operation not permitted across the host-sandbox mount.

**Root cause.** The daemon writes the response file with host-user permissions; the sandbox is a different user (`festive-trusting-carson` or similar) and lacks delete permissions on host-owned files.

**Workaround.** None needed for correctness — the daemon auto-cleans outbox files after 5 minutes. Just leaves stale files for that window.

**Status:** harmless but cosmetic. Fix: have the daemon `chmod 0o666` (or set Windows ACL equivalent) on outbox files at write time so any reader can clean up.

## 5. Sandbox-host mount has stale cache on `.git/index.lock` (low, intermittent)

**Symptom.** Git operations from the Cowork sandbox (via `mcp__workspace__bash`) fail with *"fatal: Unable to create '...index.lock': File exists"* even immediately after the host has confirmed the lock is gone via `Test-Path` returning False. The sandbox's `stat`/`ls` show the lock file existing; the host's `Test-Path` shows it doesn't.

**Root cause.** The Linux sandbox's mount of the Windows host folder caches directory entries; deletes from the host side don't always invalidate the sandbox's cached entries promptly. This shows up especially for short-lived files like `.git/*.lock`.

**Workaround.** None reliable. The lock survives `git reset` style operations from the sandbox because git can't unlink across this cache mismatch.

**Status:** open. Probably out of scope for the bridge itself; this is a Cowork mount-layer concern. But it makes git workflows from the sandbox unreliable enough that users should be told to run their `.git`-touching commands host-side, not sandbox-side.

## 6. `gh repo create` via Start-Process can't find a valid git repo (medium — surfaced 2026-05-14 PM)

**Symptom.** `gh repo create <name> --source=C:\dev\claude-code-bridge --push --public` invoked via `Start-Process` from a bridge-launched PowerShell script fails with *"C:\dev\claude-code-bridge is not a git repository."* The directory IS a valid git repo (`git status` from the same script seconds earlier works fine and commits land). Tried: `Set-Location $root`, `[System.IO.Directory]::SetCurrentDirectory($root)`, `-WorkingDirectory $root` on Start-Process, prepending Git's cmd dir to `$env:Path`, passing `--source=$root` explicitly. None resolved it.

**Root cause (working hypothesis).** gh runs `git rev-parse --is-inside-work-tree` internally to validate the source directory. That subprocess inherits an environment from gh which in turn inherited it from Start-Process which was spawned by the bridge daemon. Somewhere in that chain, either git isn't findable for the grandchild process (despite PATH manipulation in the script's process) or the CWD doesn't actually take effect for gh's child, and gh's verification returns false.

**Additional issue uncovered.** `Start-Process -ArgumentList @('--description','some long text with spaces')` quotes the elements inconsistently on .NET in older PowerShell; gh sees the description text word-split into ~17 separate args and errors with *"accepts at most 1 arg(s), received 25"*. Even `--description=long text` as a single array element gets split. This is a long-standing PowerShell `Start-Process` quirk; the typical fix is to pre-build the command line string yourself rather than letting Start-Process construct it from an array.

**Workaround.** Run `gh repo create` from a real interactive PowerShell or Windows Terminal, not from a bridge-spawned script. The local commits land via the bridge fine (see #1's workaround); just the GitHub-publishing step needs to be manual until the gh-via-bridge gap is solved.

**Status:** unresolved. Probably solvable by writing a `cmd /c` invocation with explicit quoting (sidestepping both PowerShell's Start-Process arg-quoting and gh's apparent cwd-inheritance problem), but that hits issue #3.

## 7. Wrapped `powershell -ExecutionPolicy Bypass -Command "iex (iwr ...).Content"` blocked by Win11 Smart App Control (high — student-facing)

**Symptom.** A user on Windows 11 22H2+ pastes the install one-liner in the form

```
powershell -ExecutionPolicy Bypass -Command "iex (iwr -useb 'https://raw.githubusercontent.com/johncliechty/claude-code-bridge/main/bootstrap.ps1').Content"
```

into an existing PowerShell session and gets:

```
Program 'powershell.exe' failed to run: Access is denied
At line:1 char:1
+ C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionP ...
    + CategoryInfo          : ResourceUnavailable: (:) [], ApplicationFailedException
    + FullyQualifiedErrorId : NativeCommandFailed
```

The error fires at `CreateProcess` time — *before* `bootstrap.ps1` is even fetched. No `iwr` runs; no `iex` parses. The bridge's content never enters the picture.

**Root cause (working hypothesis).** Microsoft Defender Smart App Control (default-on for new Win11 22H2+ installs) inspects child-process spawns from PowerShell and refuses unsigned `powershell.exe -ExecutionPolicy Bypass -Command "iex ..."` patterns at `CreateProcess` time — that command line is a textbook SAC-flagged "download-and-execute remote script" pattern. The same pattern also trips some corporate AppLocker policies and some third-party EDR products with PowerShell self-elevation rules.

`Install-Claude-Code-Bridge.bat` uses the same wrapped pattern internally (`powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "..."` against the fetched script), so it fails on the same machines with the same error.

**Workaround.** Use the **bare-iex form**, run inside the user's existing PowerShell session, with no `powershell -Command` wrapper at all:

```
iex (iwr -useb 'https://raw.githubusercontent.com/johncliechty/claude-code-bridge/main/bootstrap.ps1').Content
```

This runs entirely inside the parent PowerShell — no child process spawn, no SAC gate. Combined with the iex-tolerance fix in `bootstrap.ps1` (commit `6a68959`, which wraps the script body in `& { ... }`), the bare form parses cleanly. Verified working on a Win11 machine with SAC active where the wrapped form had just failed.

**Student-facing implication.** The Anchor curriculum's STYLE.md was updated to instruct the agent to *only* give students the bare-iex line. The wrapped form and the `.bat` are kept on the repo for non-SAC machines (older Win10/11, corporate-imaged boxes with SAC off, etc.) but are *not* the recommended path for first-time students.

**Status:** worked-around at the documentation + curriculum layer. Real fix would require either a code-signed installer (out of scope for this stage) or rewriting `bootstrap.ps1` to not look like SAC's blocked pattern from the outside (but the iex form sidesteps this entirely so it's not pressing).

---

## Summary of practical impact

For routine bridge usage — `echo`, file operations, `Test-Path`, `Get-ChildItem`, `Remove-Item`, simple cmdlets, `Set-Location`, registry reads, etc. — the bridge is solid (~170-200ms round-trips, consistent across days). Issues #1-#3 bite for external binary invocation and file-path-with-spaces cases. Issue #4 is cosmetic. Issue #5 is a Cowork mount concern. Issue #6 specifically blocks the `gh repo create` flow. Issue #7 is the student-facing install gotcha; documented workaround is the bare-iex form.

For git workflows on the host: write a `.ps1` that uses `Start-Process` with `RedirectStandardOutput`, log to `$env:TEMP`, and the work lands. For `gh` workflows specifically: do it from a real terminal until issue #6 is solved.

A future Phase 5 of the bridge that attaches a `ConPTY` to the spawned child process is likely the right fix for #1-#3 together — they all smell like the same TTY/console-handle root cause. Issue #6 may require additional work around environment inheritance for grandchild processes (gh's git subprocesses).
