extends Node
## Звуки игры. Пул проигрывателей + ограничение одинаковых звуков,
## чтобы 200 скелетов не превращались в какофонию (и не грузили процессор).
## Авторы звуков — assets/sounds/LICENSE.txt

const DIR := "res://assets/sounds/"

## имя -> [файлы (выбирается случайный), громкость дБ, макс. одновременно, мин. интервал сек]
const SOUNDS := {
	"cast_start": [["cast_start.ogg"], -14.0, 2, 0.1],
	"arcane": [["arcane.ogg"], -8.0, 3, 0.05],
	"frost_bolt": [["frost_bolt.wav"], -8.0, 3, 0.05],
	"frost_big": [["frost_big.wav"], -5.0, 2, 0.2],
	"ice_shatter": [["ice_shatter_1.ogg", "ice_shatter_2.ogg", "ice_shatter_3.ogg"], -10.0, 3, 0.06],
	"fire": [["fire_1.ogg", "fire_2.ogg", "fire_3.ogg", "fire_4.ogg"], -8.0, 3, 0.05],
	"fire_big": [["fire_big.ogg"], -4.0, 2, 0.15],
	"fire_burn": [["fire_burn.ogg", "fire_whoosh.ogg"], -9.0, 2, 0.2],
	"holy": [["holy_smite.wav"], -9.0, 2, 0.1],
	"shield": [["holy_shield.wav"], -9.0, 2, 0.15],
	"heal": [["heal_1.wav", "heal_2.wav", "heal_3.wav"], -11.0, 3, 0.08],
	"sword": [["sword_swing_1.ogg", "sword_swing_2.ogg", "sword_swing_3.ogg"], -8.0, 2, 0.05],
	"hit_metal": [["hit_metal_1.ogg", "hit_metal_2.ogg", "hit_metal_3.ogg"], -10.0, 3, 0.05],
	"hit_bone": [["hit_bone_1.ogg", "hit_bone_2.ogg", "hit_bone_3.ogg"], -9.0, 4, 0.04],
	"bones_fall": [["bones_fall_1.ogg", "bones_fall_2.ogg", "bones_fall_3.ogg"], -8.0, 4, 0.05],
	"hurt": [["hurt_1.ogg", "hurt_2.ogg"], -8.0, 2, 0.15],
	"mob_swing": [["mob_swing_1.ogg", "mob_swing_2.ogg"], -16.0, 3, 0.08],
	"boss_roar": [["boss_roar.ogg"], -2.0, 1, 1.0],
	"horde": [["horde.ogg"], -6.0, 1, 1.0],
	"bell": [["bell.ogg"], -6.0, 1, 0.5],
	"level_up": [["level_up.ogg"], -6.0, 1, 0.5],
	"victory": [["victory.ogg"], -4.0, 1, 1.0],
	"defeat": [["defeat.ogg"], -4.0, 1, 1.0],
	"ui_click": [["ui_click.ogg"], -10.0, 2, 0.03],
	"ui_error": [["ui_error.ogg"], -12.0, 1, 0.4],
	"ui_learn": [["ui_learn.ogg"], -8.0, 2, 0.05],
	"ui_drop": [["ui_drop.ogg"], -8.0, 1, 0.05],
	"ui_open": [["ui_open.ogg"], -10.0, 1, 0.05],
	"ui_close": [["ui_close.ogg"], -10.0, 1, 0.05],
	"book_open": [["book_open.ogg"], -6.0, 1, 0.05],
	"book_close": [["book_close.ogg"], -6.0, 1, 0.05],
	"coins": [["coins.ogg"], -14.0, 1, 0.3],
}

const POOL_2D := 8
const POOL_3D := 24

var _streams: Dictionary = {}
var _p2d: Array = []
var _p3d: Array = []
var _last: Dictionary = {}
var _active: Dictionary = {}     # имя -> [проигрыватели]

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in POOL_2D:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_p2d.append(p)
	for i in POOL_3D:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 10.0
		p.max_distance = 80.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.panning_strength = 0.8
		add_child(p)
		_p3d.append(p)
	set_volume(load_volume())

func _stream(file: String) -> AudioStream:
	if not _streams.has(file):
		_streams[file] = load(DIR + file)
	return _streams[file]

func _allowed(name: String) -> bool:
	if not SOUNDS.has(name):
		return false
	var def: Array = SOUNDS[name]
	var now := Time.get_ticks_msec() * 0.001
	if now - float(_last.get(name, -10.0)) < float(def[3]):
		return false
	var list: Array = _active.get(name, [])
	list = list.filter(func(p): return is_instance_valid(p) and p.playing and p.get_meta("snd", "") == name)
	_active[name] = list
	if list.size() >= int(def[2]):
		return false
	_last[name] = now
	return true

func _pick(pool: Array) -> Node:
	for p in pool:
		if not p.playing:
			return p
	return pool[randi() % pool.size()]

func _setup(p: Node, name: String, vol: float) -> void:
	var def: Array = SOUNDS[name]
	var files: Array = def[0]
	p.stream = _stream(files[randi() % files.size()])
	p.volume_db = float(def[1]) + vol
	p.pitch_scale = randf_range(0.93, 1.07)
	p.set_meta("snd", name)
	_active[name].append(p)

## Звук интерфейса / без положения в мире.
func play(name: String, vol: float = 0.0) -> void:
	if not _allowed(name):
		return
	var p: AudioStreamPlayer = _pick(_p2d)
	_setup(p, name, vol)
	p.play()

## Звук в точке мира (с затуханием по расстоянию).
func play_at(name: String, pos: Vector3, vol: float = 0.0) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam and cam.global_position.distance_squared_to(pos) > 85.0 * 85.0:
		return
	if not _allowed(name):
		return
	var p: AudioStreamPlayer3D = _pick(_p3d)
	_setup(p, name, vol)
	p.global_position = pos
	p.play()

# ---------------------------------------------------------------- громкость

func set_volume(v: float) -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(v, 0.0001)))
	AudioServer.set_bus_mute(0, v <= 0.001)

func load_volume() -> float:
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		return float(cfg.get_value("audio", "volume", 0.8))
	return 0.8

func save_volume(v: float) -> void:
	var cfg := ConfigFile.new()
	cfg.load("user://settings.cfg")
	cfg.set_value("audio", "volume", v)
	cfg.save("user://settings.cfg")
