@echo off
rem enhanced-glab: `glab add|list|use|remove` go to glab-accounts.ps1 (next to this file); every other command to the real glab.exe.
setlocal
if defined GLAB_REAL goto found
rem The first glab.exe on PATH is the real one (this folder holds glab.cmd, not glab.exe).
for %%I in (glab.exe) do set "GLAB_REAL=%%~$PATH:I"
if not defined GLAB_REAL (
  echo glab: the real glab.exe is not on PATH: install glab, or set GLAB_REAL 1>&2
  exit /b 1
)
:found
if /i "%~1"=="add" goto accounts
if /i "%~1"=="list" goto accounts
if /i "%~1"=="use" goto accounts
if /i "%~1"=="remove" goto accounts
"%GLAB_REAL%" %*
exit /b %ERRORLEVEL%
:accounts
rem -ExecutionPolicy Bypass for this one script: it is not signed, and many PCs refuse unsigned scripts.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0glab-accounts.ps1" %*
exit /b %ERRORLEVEL%
