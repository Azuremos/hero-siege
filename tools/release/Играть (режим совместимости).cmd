@echo off
rem Hero Siege: режим совместимости для старых видеокарт (OpenGL вместо Vulkan)
cd /d "%~dp0"
start "" "%~dp0HeroSiege.exe" --rendering-driver opengl3
