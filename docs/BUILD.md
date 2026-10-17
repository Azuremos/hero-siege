# Сборка Hero Siege

Две вещи собираются отдельно: **игра в exe** (экспорт Godot) и **расширение на C++** (`bin/herosiege_native…dll`, мобы).
Готовая `.dll` лежит в репозитории — на машине без компилятора игра и экспорт работают сразу. Пересобирать её нужно,
только если меняли `native/src/`.

## 1. Игра в exe

1. Godot 4.7.2: `C:\Users\abbas\Godot\Godot_v4.7.2-stable_win64_console.exe` (или свой путь — параметр `-Godot` у скрипта).
2. Шаблоны экспорта 4.7.2 — **только официальные**: `Godot_v4.7.2-stable_export_templates.tpz` со страницы релиза
   https://github.com/godotengine/godot/releases/tag/4.7.2-stable (там же `SHA512-SUMS.txt` — сверьте сумму).
   Это zip: из папки `templates/` достаточно `windows_*_x86_64*.exe` и `version.txt`, положить в
   `%APPDATA%\Godot\export_templates\4.7.2.stable\`. (Или в редакторе: Редактор → Управление шаблонами экспорта → Загрузить.)
3. Из папки проекта:
   ```
   powershell -ExecutionPolicy Bypass -File tools\release.ps1
   ```
   Скрипт экспортирует пресет «Windows Desktop» (`export_presets.cfg`: игра встроена в exe, иконка, версия в свойствах файла)
   в `export\build\`, собирает `export\HeroSiege-vX.Y\` (exe, dll, «КАК ИГРАТЬ.txt», «Играть (режим совместимости).cmd»,
   папка «Лицензии») и архив `export\HeroSiege-vX.Y.zip`, печатает размер и SHA256. Папка `export/` — в `.gitignore`.
   Релиз на GitHub скрипт не публикует.

Проверка экспорта: `export\HeroSiege-v0.16\HeroSiege.exe -- --solo --class=mage --bot --fastwaves --quit-after=40 > log.txt`
— флаги тестового запуска работают и в exe (после `--`), вывод — в файл.

## 2. Расширение на C++ (мобы)

Код — `native/src/` (`mob_sim.*` — класс `MobSimNative`, `register_types.cpp`), библиотека godot-cpp — подмодуль `native/godot-cpp`.

Что поставить (всё — из официальных источников, без прав администратора):
```
winget install --id Python.Python.3.12 --scope user
winget install --id BrechtSanders.WinLibs.POSIX.UCRT
%LOCALAPPDATA%\Programs\Python\Python312\python.exe -m pip install --user scons
git submodule update --init native/godot-cpp
```
WinLibs — GCC (MinGW-w64, UCRT) от Brecht Sanders; winget кладёт его в
`%LOCALAPPDATA%\Microsoft\WinGet\Packages\BrechtSanders.WinLibs.POSIX.UCRT_…\mingw64\bin` — добавьте эту папку в PATH
на время сборки. MSVC Build Tools тоже подойдут (тогда без `use_mingw=yes`).

Описание API движка — из того же Godot, под который собираем:
```
Godot_v4.7.2-stable_win64_console.exe --headless --dump-extension-api
move extension_api.json native\
```

Сборка (из `native/`, первая — несколько минут, дальше — секунды):
```
python -m SCons platform=windows use_mingw=yes target=template_release custom_api_file=extension_api.json -j6
```
Результат — `bin/herosiege_native.windows.template_release.x86_64.dll`; её подхватывает `bin/herosiege.gdextension`
(одна и та же библиотека для редактора и для exe). После пересборки один раз откройте проект в редакторе или выполните
`Godot … --headless --path . --import` — Godot перечитает расширения.

Проверка:
- `-- --mobsimtest` — тест эквивалентности путей GDScript и C++ (в консоль, «MOBSIM EQUIV: OK»);
- `-- --solo --class=mage --bot --godmode --stress=500 --mobsim=cpp` и то же с `--mobsim=gd` — время тика мобов и FPS.

Если `.dll` не загрузилась (нет файла, другая версия Godot), игра сама работает на GDScript-пути — медленнее при сотнях мобов,
но правильно.
