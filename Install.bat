@echo off
rem Double-click this, or drag your game exe onto it.
rem Finds Python if you have it, quietly fetches a small private copy if you don't.

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

if exist ".cache\python\python.exe" (
  set "PYEXE=.cache\python\python.exe"
  goto run
)

echo Python isn't installed. Fetching a small copy just for this installer.
echo Nothing is added to your system, it lives in .cache and you can delete it after.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; New-Item -ItemType Directory -Force '.cache' ^| Out-Null; Invoke-WebRequest -UseBasicParsing -Uri 'https://www.python.org/ftp/python/3.12.8/python-3.12.8-embed-amd64.zip' -OutFile '.cache\python.zip'; Expand-Archive -Force '.cache\python.zip' '.cache\python'; Remove-Item '.cache\python.zip' } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 goto nopython
if not exist ".cache\python\python.exe" goto nopython
set "PYEXE=.cache\python\python.exe"

:run
echo.
"%PYEXE%" %PYARGS% install_mod.py %*
set "RESULT=%ERRORLEVEL%"
echo.
if not "%RESULT%"=="0" (
  echo Something went wrong. The message above says what.
  echo If you're stuck, open an issue and paste it in.
)
pause
exit /b %RESULT%

:nopython
echo.
echo Couldn't download Python automatically.
echo Install it from https://www.python.org/downloads/ and run this again.
echo.
pause
exit /b 1
