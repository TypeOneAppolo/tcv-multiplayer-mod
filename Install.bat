@echo off
rem Double-click this, or drag your game exe onto it.
rem
rem This launcher deliberately does not download or run anything itself. An
rem earlier version fetched a copy of Python straight off the internet and ran
rem it, which is exactly what a malware dropper does, and antivirus flagged the
rem whole download because of it. If Python is missing we now ask winget, which
rem installs a signed package from Microsoft's own catalogue, or just point you
rem at python.org.

setlocal
cd /d "%~dp0"
title The Choicer Voicer - Multiplayer Mod Installer

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
echo This needs Python, and it isn't installed.
echo.

where winget >nul 2>&1
if errorlevel 1 goto manual

echo I can install it for you with winget, which is Microsoft's own package
echo manager, already built into Windows. It'll fetch the official signed
echo Python package. Or say no and grab it yourself.
echo.
set /p GETPY="Install Python with winget now? [Y/N] "
if /i not "%GETPY%"=="Y" goto manual

echo.
winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements
if errorlevel 1 goto manual

echo.
echo Python installed. You'll need to close this window and run Install.bat
echo again so it picks up the new install.
echo.
pause
exit /b 0

:run
echo.
"%PYEXE%" %PYARGS% install_mod.py %*
set "RESULT=%ERRORLEVEL%"
echo.
if not "%RESULT%"=="0" (
  echo Something went wrong. The message above says what.
  echo If you're stuck, open an issue on GitHub and paste it in.
)
pause
exit /b %RESULT%

:manual
echo.
echo Install Python from https://www.python.org/downloads/
echo Tick "Add python.exe to PATH" on the first screen of the installer.
echo Then run Install.bat again.
echo.
pause
exit /b 1
