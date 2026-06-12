@echo off
chcp 65001 >nul 2>&1
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -InputFormat None -File "%~dp0source\rocmroll.ps1" %*
exit /b %ERRORLEVEL%
