@echo off
REM Stop the sucker - double-click this. It asks for admin by itself.
title Stop the sucker

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Asking Windows for admin rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-the-sucker.ps1" %*
echo.
echo Finished. Press any key to close.
pause >nul
