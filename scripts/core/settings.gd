extends Node
## Настройки игры (автозагрузка «Settings»): звук, графика, интерфейс. Хранятся в user://settings.cfg.

const PATH := "user://settings.cfg"
const UI_PATH := "user://ui_layout.cfg"
const BUILDS_PATH := "user://builds.cfg"   # заготовки талантов: [класс] имя = {order, choices}

var master := 0.8
var music := 0.55
var sfx := 0.9
var fullscreen := false
var vsync := true
var shadows := 2          # 0 — выкл, 1 — средние, 2 — высокие

func _ready() -> void:
	_ensure_bus("Music")
	_ensure_bus("SFX")
	_load()
	apply()

func _ensure_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) >= 0:
		return
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, "Master")

func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	master = float(cfg.get_value("audio", "volume", master))
	music = float(cfg.get_value("audio", "music", music))
	sfx = float(cfg.get_value("audio", "sfx", sfx))
	fullscreen = bool(cfg.get_value("graphics", "fullscreen", fullscreen))
	vsync = bool(cfg.get_value("graphics", "vsync", vsync))
	shadows = int(cfg.get_value("graphics", "shadows", shadows))

## Тестовые запуски с параметрами (--solo, --bot, --host…) — без музыки, чтобы не мешать; --music=0.5 — вернуть.
## Сохранённые настройки игрока не меняются (тестовые запуски их не записывают).
func _test_music() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		return
	music = 0.0
	for a in args:
		if a.begins_with("--music="):
			music = clampf(float(a.trim_prefix("--music=")), 0.0, 1.0)

func save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(PATH)
	cfg.set_value("audio", "volume", master)
	cfg.set_value("audio", "music", music)
	cfg.set_value("audio", "sfx", sfx)
	cfg.set_value("graphics", "fullscreen", fullscreen)
	cfg.set_value("graphics", "vsync", vsync)
	cfg.set_value("graphics", "shadows", shadows)
	cfg.save(PATH)

func _vol(bus_name: String, v: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(v, 0.0001)))
	AudioServer.set_bus_mute(idx, v <= 0.001)

func apply() -> void:
	_test_music()
	_vol("Master", master)
	_vol("Music", music)
	_vol("SFX", sfx)
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)

## Тени солнца по настройке качества.
func apply_shadows(sun: DirectionalLight3D) -> void:
	if sun == null:
		return
	sun.shadow_enabled = shadows > 0
	sun.directional_shadow_max_distance = 60.0 if shadows >= 2 else 35.0

## Параметр раскладки интерфейса (те же, что в игровом режиме настройки).
func get_ui_opt(key: String, def):
	var cfg := ConfigFile.new()
	cfg.load(UI_PATH)
	return cfg.get_value("opt", key, def)

func set_ui_opt(key: String, value) -> void:
	var cfg := ConfigFile.new()
	cfg.load(UI_PATH)
	cfg.set_value("opt", key, value)
	cfg.save(UI_PATH)

func reset_ui_positions() -> void:
	var cfg := ConfigFile.new()
	cfg.load(UI_PATH)
	if cfg.has_section("pos"):
		cfg.erase_section("pos")
	cfg.save(UI_PATH)

# ---------------------------------------------------------------- режим совместимости (сессия 08)
## Для старых видеокарт: отрисовка через OpenGL 3 (Compatibility) вместо Vulkan. Действует после перезапуска.
## Godot читает override.cfg рядом с HeroSiege.exe (в запуске из папки проекта — в корне проекта) и подменяет
## им настройки проекта. Если Vulkan и D3D12 не стартуют вообще, Godot 4.7 и так сам перейдёт на OpenGL.
const OVERRIDE_TEXT := "; Режим совместимости Hero Siege (Настройки → Графика). Удалите файл, чтобы вернуть Vulkan.\n[rendering]\n\nrenderer/rendering_method=\"gl_compatibility\"\nrenderer/rendering_method.mobile=\"gl_compatibility\"\n"

func override_path() -> String:
	if OS.has_feature("template"):
		return OS.get_executable_path().get_base_dir().path_join("override.cfg")
	return ProjectSettings.globalize_path("res://override.cfg")

func compat_mode() -> bool:
	return FileAccess.file_exists(override_path())

## Сейчас игра рисует через OpenGL (режим совместимости или автоматический откат).
func compat_running() -> bool:
	return RenderingServer.get_current_rendering_method() == "gl_compatibility"

## Включить или выключить режим совместимости. "" — получилось, иначе текст ошибки.
func set_compat_mode(on: bool) -> String:
	var p := override_path()
	if on:
		var f := FileAccess.open(p, FileAccess.WRITE)
		if f == null:
			return "Не удалось записать %s — запустите игру из папки, куда можно писать (или ярлыком «режим совместимости»)." % p
		f.store_string(OVERRIDE_TEXT)
		f.close()
	elif FileAccess.file_exists(p):
		if DirAccess.remove_absolute(p) != OK:
			return "Не удалось удалить %s" % p
	return ""

## Режим совместимости (OpenGL) рисует ту же сцену заметно светлее Vulkan (замер: средняя яркость кадра
## на 28% выше). Чтобы картинка была одинаковой во всех режимах, в OpenGL свет карты приглушается.
## Коэффициенты подобраны снимками с одной камеры (отчёт 08).
const COMPAT_SUN := 0.6
const COMPAT_AMBIENT := 0.55
const COMPAT_EXPOSURE := 0.72

func apply_lighting(map: Node) -> void:
	if map == null or not compat_running():
		return
	var sun := map.get_node_or_null("Sun") as DirectionalLight3D
	if sun:
		sun.light_energy *= COMPAT_SUN
	for we in map.find_children("*", "WorldEnvironment", true, false):
		var env: Environment = (we as WorldEnvironment).environment
		if env:
			env = env.duplicate()
			env.ambient_light_energy *= COMPAT_AMBIENT
			env.tonemap_exposure *= COMPAT_EXPOSURE
			(we as WorldEnvironment).environment = env

# ---------------------------------------------------------------- заготовки талантов
## Заготовка — план героя из «Талантов класса» главного меню: order — таланты в порядке изучения
## (id повторяется по рангам), choices — выбор в рядах книги {ряд: id}. В игре изучаются сами.
## Тестовые запуски с флагами заготовки читают, но не меняют выбранную.

func builds(class_id: String) -> Dictionary:
	var cfg := ConfigFile.new()
	cfg.load(BUILDS_PATH)
	var out := {}
	if cfg.has_section(class_id):
		for k in cfg.get_section_keys(class_id):
			out[k] = cfg.get_value(class_id, k, {})
	return out

func save_build(class_id: String, build_name: String, data: Dictionary) -> void:
	var cfg := ConfigFile.new()
	cfg.load(BUILDS_PATH)
	cfg.set_value(class_id, build_name, data)
	cfg.save(BUILDS_PATH)

func delete_build(class_id: String, build_name: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(BUILDS_PATH)
	if cfg.has_section_key(class_id, build_name):
		cfg.erase_section_key(class_id, build_name)
	cfg.save(BUILDS_PATH)

## Выбранная для класса заготовка (пустая строка — нет).
func selected_build(class_id: String) -> String:
	return str(get_ui_opt("build_" + class_id, ""))

func select_build(class_id: String, build_name: String) -> void:
	set_ui_opt("build_" + class_id, build_name)
