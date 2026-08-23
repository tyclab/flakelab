@echo off
REM ===========================================================================
REM  setup-wsl-nix.cmd - convenience wrapper around setup-wsl-nix.ps1
REM
REM  Saves you from typing the PowerShell execution-policy boilerplate, and
REM  gives the provisioning run its own Windows console - which is the point:
REM  a run started over interop from inside a distro dies part-way when
REM  `nixos-rebuild switch` wipes WSLInterop. See known-issues.md.
REM
REM  Usage (from cmd or PowerShell, in a real Windows terminal):
REM      setup-wsl-nix.cmd status
REM      setup-wsl-nix.cmd provision -DryRun
REM      setup-wsl-nix.cmd provision -CopyLiveCredentials -SshPassphrase "pw" -Shutdown
REM
REM  Or just double-click it for an interactive status/dry-run/provision menu.
REM  Any arguments are passed straight through to setup-wsl-nix.ps1.
REM ===========================================================================
setlocal
set "PS1=%~dp0setup-wsl-nix.ps1"

if not exist "%PS1%" (
    echo ERROR: setup-wsl-nix.ps1 not found next to this wrapper:
    echo   %PS1%
    exit /b 1
)

REM --- Pass-through mode: arguments supplied on the command line ---
if not "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
    exit /b %ERRORLEVEL%
)

REM --- Interactive mode: no arguments (e.g. double-click) ---
echo setup-wsl-nix : provision the NixOS-WSL distro
echo.
echo   [S] Status      - read-only: overlay / key / secrets / distro / interop
echo   [D] Dry run     - rehearse 'provision', change nothing
echo   [P] Provision   - the real run (wipes WSL interop, offers wsl --shutdown)
echo   [Q] Quit
echo.
choice /c SDPQ /n /m "Choose [S/D/P/Q]: "
if errorlevel 4 goto :quit
if errorlevel 3 goto :provision
if errorlevel 2 goto :dryrun
if errorlevel 1 goto :status

:status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" status
goto :pause_end

:dryrun
set "EXTRA=-DryRun"
goto :overlay_check

:provision
echo.
echo WARNING: this run wipes WSLInterop VM-wide and ends with an offer to run
echo          'wsl --shutdown', which kills every WSL session on this machine.
choice /c YN /n /m "Continue? [Y/N]: "
if errorlevel 2 goto :quit
set "EXTRA="
goto :overlay_check

REM --- The overlay decision, mirrored from setup-wsl-nix.ps1 --------------
REM  The menu passes no -Config. With no sibling overlay the .ps1 asks its
REM  four questions itself (this console is interactive, so it can); a prepared
REM  config can still be named here to skip them. wslnix-config is the
REM  pre-2026-08-21 name of the same sibling, which the .ps1 still accepts.
:overlay_check
set "CFGARG="
if exist "%~dp0..\flakelab-config\flake.nix" goto :run
if exist "%~dp0..\wslnix-config\flake.nix" goto :run
echo.
echo No overlay flake next to this checkout ("%~dp0..\flakelab-config").
echo One is generated now - from a user_data.yaml you already have (same schema
echo as files\config\user_data.example.yaml), or from four questions asked next.
echo.
set "CFG="
set /p "CFG=Path to your user_data.yaml (Enter = answer the questions instead): "
if defined CFG set CFGARG=-Config "%CFG%"

:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" provision %EXTRA% %CFGARG%
goto :pause_end

:pause_end
echo.
pause
goto :quit

:quit
endlocal
