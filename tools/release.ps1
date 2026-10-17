# Сборка релиза Hero Siege: экспорт в exe -> архив export\HeroSiege-vX.Y.zip -> размер и контрольная сумма.
# Запуск (PowerShell, из папки проекта):  powershell -ExecutionPolicy Bypass -File tools\release.ps1
# Нужны шаблоны экспорта Godot 4.7.2 (официальные, %APPDATA%\Godot\export_templates\4.7.2.stable) — см. docs\BUILD.md.
# Архив: HeroSiege.exe (игра внутри exe), herosiege_native...dll (мобы на C++), «КАК ИГРАТЬ.txt»,
# «Играть (режим совместимости).cmd», папка «Лицензии». Релиз на GitHub скрипт НЕ публикует.
param(
    [string]$Godot = "C:\Users\abbas\Godot\Godot_v4.7.2-stable_win64_console.exe"
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$ver = (Select-String -Path (Join-Path $root "project.godot") -Pattern 'config/version="([^"]+)"').Matches[0].Groups[1].Value
$out = Join-Path $root "export"
$stage = Join-Path $out "HeroSiege-v$ver"
$zip = Join-Path $out "HeroSiege-v$ver.zip"
Write-Host "Hero Siege $ver — экспорт..."
if (Test-Path $out) { Remove-Item $out -Recurse -Force -Confirm:$false }
New-Item -ItemType Directory -Force (Join-Path $out "build") | Out-Null
& $Godot --headless --path $root --export-release "Windows Desktop" (Join-Path $out "build\HeroSiege.exe") 2>&1 | Out-Host
if (-not (Test-Path (Join-Path $out "build\HeroSiege.exe"))) { throw "Экспорт не удался: нет HeroSiege.exe" }
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item (Join-Path $out "build\*") $stage -Recurse
Copy-Item (Join-Path $root "КАК ИГРАТЬ.txt") $stage
Copy-Item (Join-Path $root "tools\release\Играть (режим совместимости).cmd") $stage
$lic = Join-Path $stage "Лицензии"
New-Item -ItemType Directory -Force $lic | Out-Null
Copy-Item (Join-Path $root "assets\licenses\*") $lic
Get-ChildItem (Join-Path $root "assets") -Recurse -Filter "LICENSE*.txt" | ForEach-Object {
    $rel = $_.Directory.Name + "_" + $_.Name
    Copy-Item $_.FullName (Join-Path $lic $rel)
}
if (Test-Path $zip) { Remove-Item $zip -Force -Confirm:$false }
Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal
$f = Get-Item $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
Write-Host ("Архив: {0}" -f $f.FullName)
Write-Host ("Размер: {0:N1} МБ" -f ($f.Length / 1MB))
Write-Host ("SHA256: {0}" -f $hash)
