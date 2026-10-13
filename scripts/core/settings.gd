extends Node
## Настройки игры (автозагрузка «Settings»): звук, графика, интерфейс. Хранятся в user://settings.cfg.

const PATH := "user://settings.cfg"
const UI_PATH := "user://ui_layout.cfg"

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
