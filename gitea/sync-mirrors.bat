@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-mirrors.ps1" %*
