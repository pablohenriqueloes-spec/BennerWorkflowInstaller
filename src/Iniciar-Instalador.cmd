@echo off
setlocal
set "SCRIPT=%~dp0BennerWorkflowInstaller.ps1"
if not exist "%SCRIPT%" (
    echo Arquivo BennerWorkflowInstaller.ps1 nao encontrado.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File','""%SCRIPT%""')"
if errorlevel 1 pause
