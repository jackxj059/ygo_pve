@echo off
rem Double-click to play. First run downloads tools and builds (several minutes).
rem start-game.cmd -Editor opens the Godot editor instead.
cd /d "%~dp0"
set PS=powershell -NoProfile -ExecutionPolicy Bypass -File

if not exist "tools\godot\Godot_v4.7.2-stable_win64.exe" (
  echo [1/2] Downloading tools...
  %PS% scripts\bootstrap.ps1 || goto fail
)
if not exist "game\addons\ygo_battle\bin\ygo_battle.windows.template_debug.x86_64.dll" (
  echo [2/2] Building...
  %PS% scripts\build.ps1 || goto fail
)
%PS% scripts\run-game.ps1 %* || goto fail
exit /b 0

:fail
echo.
echo Startup failed, see the messages above.
pause
exit /b 1
