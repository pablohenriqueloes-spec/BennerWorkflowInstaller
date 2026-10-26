@echo off
setlocal
set "SCRIPT=%~dp0BennerHub.ps1"
if not exist "%SCRIPT%" (
    echo Arquivo BennerHub.ps1 nao encontrado.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File','""%SCRIPT%""')"
if errorlevel 1 pause
