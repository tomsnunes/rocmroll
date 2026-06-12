@echo off
setlocal

set "LAUNCHER_DIR=%~dp0"
set "ROOT_DIR={RootFolder}"
set "ENV_DIR={EnvironmentFolder}"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LAUNCHER_DIR%{InstanceName}.ps1" %*
exit /b %ERRORLEVEL%
