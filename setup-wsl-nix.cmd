@echo off
setlocal
set "PS1=%~dp0setup-wsl-nix.ps1"

if not exist "%PS1%" (
    echo ERROR: setup-wsl-nix.ps1 not found next to this wrapper:
    echo   %PS1%
    exit /b 1
)

REM  Not inside an if ( ... ) block: cmd expands %ERRORLEVEL% when it reads the
REM  block, before powershell.exe has run, so the script's exit code (4 = units
REM  still failed, 1 = a step threw) would come back as 0. Delayed expansion is
REM  no way out either: it eats the "!" in a passed -SshPassphrase.
if "%~1"=="" goto :menu
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %ERRORLEVEL%

:menu
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
