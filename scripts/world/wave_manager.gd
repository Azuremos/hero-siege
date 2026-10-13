extends Node
## Волны нежити (только сервер).
## Каждые 3 волны — передышка: сначала добить всех врагов, затем 30 сек. отдыха
## (здоровье и мана восполняются быстрее). Хост может начать волну раньше.

const BREAK_EVERY := 3
const BREAK_TIME := 30.0

var world: Node3D
var _next_wave_at := 0.0
var _queue: Array = []            # [время, тип, полоса, множитель здоровья]
var _started := false
var _all_spawned := false
var _break_pending := false       # ждём, пока добьют врагов, чтобы начать передышку

func _ready() -> void:
	world = get_parent()

func begin() -> void:
	_started = true
	var delay: float = minf(GameData.FIRST_WAVE_DELAY, 12.0 + 3.0 * world.wave_count)
	_next_wave_at = world.now() + delay
	var mode: String = "" if world.wave_count >= GameData.WAVE_COUNT else "  (волн: %d)" % world.wave_count
	world.announce_all("Защитите замок! Первая волна через %d сек.%s" % [int(delay), mode])

func server_tick(_delta: float, t: float) -> void:
	if not _started or world.game_state == "victory" or world.game_state == "defeat":
		return
	while not _queue.is_empty() and t >= _queue[0][0]:
		var e: Array = _queue.pop_front()
		world.mobs.spawn(e[1], e[2], world.wave, world.heroes.size(), e[3])
	if _all_spawned:
		world.next_wave_in = 0.0
		if _queue.is_empty() and world.mobs.alive_count() == 0:
			world.end_game(true)
		return
	if _break_pending:
		world.next_wave_in = 0.0
		if _queue.is_empty() and world.mobs.alive_count() == 0:
			_break_pending = false
			world.game_state = "break"
			_next_wave_at = t + BREAK_TIME
			world.sound_all("level_up")
			world.announce_all("Передышка! Следующая волна через %d сек. — восстановите силы." % int(BREAK_TIME), Color(0.6, 1.0, 0.7))
		return
	world.next_wave_in = maxf(0.0, _next_wave_at - t)
	if t >= _next_wave_at:
		_start_wave(t)

## Хост досрочно заканчивает передышку (или подготовку перед первой волной).
func skip_break() -> void:
	if world.game_state == "break" or world.game_state == "prep":
		_next_wave_at = world.now()

func _start_wave(t: float) -> void:
	world.wave += 1
	world.game_state = "running"
	var w: int = world.wave
	# В короткой партии (меньше 5 волн) последняя волна заканчивается боссом
	var short_final: bool = world.wave_count < 5 and w == world.wave_count
	var lanes: Array = world.active_lanes
	var comp: Array = GameData.wave_composition(w, lanes.size(), short_final)
	var per_lane_time: Dictionary = {}
	for e in comp:
		var lane: int = lanes[int(e[1]) % lanes.size()]
		var at: float = t + float(per_lane_time.get(lane, 0.0))
		per_lane_time[lane] = float(per_lane_time.get(lane, 0.0)) + 0.8
		var hp_scale: float = 0.35 if short_final and GameData.MOBS[e[0]].get("boss", false) else 1.0
		if GameData.MOBS[e[0]].get("boss", false):
			at += 3.0
		_queue.append([at, e[0], lane, hp_scale])
	_queue.sort_custom(func(a, b): return a[0] < b[0])
	var boss := ""
	if w % 5 == 0 or short_final:
		boss = " Идёт %s!" % GameData.MOBS["boss_lich" if w % 10 == 0 else "boss_warlord"]["name"]
	world.sound_all("bell")
	world.sound_all("horde")
	var after := "" if w % BREAK_EVERY != 0 or w >= world.wave_count else "  После неё — передышка."
	world.announce_all("Волна %d из %d.%s%s" % [w, world.wave_count, boss, after], Color(1, 0.6, 0.3) if boss != "" else Color(1, 0.9, 0.6))
	if w >= world.wave_count:
		_all_spawned = true
	elif w % BREAK_EVERY == 0:
		_break_pending = true
		world.game_state = "clearing"
	else:
		_next_wave_at = t + GameData.WAVE_INTERVAL

func break_pending() -> bool:
	return _break_pending
