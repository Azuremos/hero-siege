@echo off
rem compatibility mode for old GPUs
cd /d "%~dp0"
if exist "godot\Godot_v4.7.2-stable_win64.exe" (
  start "" "godot\Godot_v4.7.2-stable_win64.exe" --path "%~dp0." --rendering-driver opengl3
) else (
  start "" "C:\Users\abbas\Godot\Godot_v4.7.2-stable_win64.exe" --path "%~dp0." --rendering-driver opengl3
)
