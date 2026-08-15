@echo off
rem Double-click this any time something's wrong -- an install that failed, a
rem multiplayer match that wouldn't connect, anything. It bundles the
rem installer's own logs and the game's logs into one zip on your Desktop,
rem ready to attach to a GitHub issue.

setlocal
cd /d "%~dp0"
title The Choicer Voicer - Diagnostics

if not exist "%~dp0install_mod.py" goto notextracted

set "PYEXE="
set "PYARGS="

py -3 --version >nul 2>&1
if not errorlevel 1 (
  set "PYEXE=py"
  set "PYARGS=-3"
  goto run
)

python --version >nul 2>&1
if not errorlevel 1 (
  set "PYEXE=python"
  goto run
)

echo.
echo This needs Python, and it isn't installed. Run Install.bat first --
echo it'll offer to install Python for you.
echo.
pause
exit /b 1

:run
echo.
"%PYEXE%" %PYARGS% install_mod.py --zip-logs
echo.
pause
exit /b 0

:notextracted
echo.
echo I can't find install_mod.py, which should be sat right next to this file.
echo Extract the whole download first rather than running this out of the zip
echo or rar -- see the notes in Install.bat for why.
echo.
pause
exit /b 1
