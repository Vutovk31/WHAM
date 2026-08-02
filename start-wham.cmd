@echo off
cd /d "%~dp0"
start "WHAM Quick Replies" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File "%~dp0WHAM.QuickReplies.ps1"
