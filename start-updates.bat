@echo off
REM Put Windows Update back - double-click this. It asks for admin by itself.
title Start updates

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Asking Windows for admin rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-updates.ps1" %*
echo.
echo Finished. Press any key to close.
pause >nul
