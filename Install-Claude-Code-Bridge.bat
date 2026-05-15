@echo off
REM ============================================================
REM  Claude Code Bridge -- one-click installer
REM  Double-click this file. It launches PowerShell silently,
REM  fetches bootstrap.ps1 from GitHub, and runs the install.
REM ============================================================

setlocal

echo.
echo ============================================================
echo  Claude Code Bridge Installer
echo ============================================================
echo.
echo This will set up the Claude Code Bridge on this PC.
echo It will:
echo   - Install Python 3.13 if not already present (no admin needed)
echo   - Install Git if not already present
echo   - Clone the bridge to C:\dev\claude-code-bridge
echo   - Register a background Scheduled Task that runs at logon
echo.
echo Internet connection required. Typical time: 1-3 minutes.
echo.
choice /c YN /n /m "Press Y to continue, or N to cancel: "
if errorlevel 2 (
    echo Cancelled.
    pause
    exit /b 0
)

echo.
echo Launching installer...
echo.

REM IMPORTANT: bootstrap.ps1 declares `[CmdletBinding()]` + `param(...)` at the top.
REM Those are legal only inside a script file or a scriptblock -- NOT inside the
REM expression context that `Invoke-Expression`/`iex` evaluates. So we cannot use
REM `iex (iwr ...).Content` here; PowerShell 5.1 will refuse to parse the fetched
REM text with "Unexpected attribute 'CmdletBinding'".
REM
REM The correct pattern is `& ([scriptblock]::Create(<text>))`, which parses the
REM text as a scriptblock (param + CmdletBinding fully supported) and then invokes
REM it. This also preserves script scope so the `&` call operator behaves normally
REM when bootstrap.ps1 invokes git/python from space-containing paths.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; try { $script = (iwr -useb 'https://raw.githubusercontent.com/johncliechty/claude-code-bridge/main/bootstrap.ps1').Content; & ([scriptblock]::Create($script)) } catch { Write-Host 'Installer failed:' $_.Exception.Message -ForegroundColor Red; exit 1 }"

set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (
    echo Install completed successfully.
) else (
    echo Install exited with code %RC%. Review the messages above.
    echo If you need help, see https://github.com/johncliechty/claude-code-bridge/blob/main/M0.md
)
echo.
pause
endlocal
