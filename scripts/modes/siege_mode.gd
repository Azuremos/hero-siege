class_name SiegeMode
extends GameMode
## Осада: волны нежити с 1–4 сторон идут по полосам к замку.
## Каждые 3 волны — передышка: сначала добить всех врагов, затем отдых (хост выбирает 30/60/90 сек.),
## здоровье и мана восполняются быстрее. Хост может начать волну раньше.
## Замок пал — поражение; отбиты все волны — победа (в бесконечной осаде победы нет).

const CASTLE_ID := 100
const BREAK_EVERY := 3
const DEFAULT_BREAK_TIME := 60.0
## Откуда идут враги: индексы полос (0 север, 1 восток, 2 юг, 3 запад). Порядок — по удобству для героя.
const LANE_ORDER := [2, 1, 3, 0]

# Состояние партии (сервер — истина, клиенты — копия). state: prep | running | clearing | break | victory | defeat
var wave := 0
var next_wave_in := 0.0
var wave_count := 20               # сколько волн в этой партии; 0 — бесконечная осада
var active_lanes: Array = [0, 1, 2, 3]
var break_time := DEFAULT_BREAK_TIME
## Какая фракция идёт по какой полосе (полоса -> id фракции). Выбор хоста: по сторонам, случайно, одна везде.
var lane_faction: Dictionary = {}

var castle: Unit
var castle_radius := 6.5
var lanes: Array = []              # Array[PackedVector2Array] от кладбища к замку
var hero_spawn := Vector3(0, 0, 14)

var _next_wave_at := 0.0
var _queue: Array = []             # [время, тип, полоса, множитель здоровья]
var _started := false
var _all_spawned := false
var _break_pending := false        # ждём, пока добьют врагов, чтобы начать передышку

func setup(w: Node3D) -> void:
	super.setup(w)
	wave_count = clampi(int(Net.settings.get("waves", GameData.WAVE_COUNT)), 0, GameData.MAX_WAVES)
	active_lanes = LANE_ORDER.slice(0, clampi(int(Net.settings.get("lanes", 4)), 1, 4))
	break_time = clampf(float(Net.settings.get("break", DEFAULT_BREAK_TIME)), 10.0, 300.0)
	_assign_factions()

func read_map(map: Node3D) -> void:
	for lane_node in map.get_node("Lanes").get_children():
		var pts := PackedVector2Array()
		for p in lane_node.get_children():
			var v: Vector3 = (p as Node3D).position
			pts.append(Vector2(v.x, v.z))
		lanes.append(pts)
	hero_spawn = (map.get_node("HeroSpawn") as Node3D).position
	var core := map.get_node("CastleCore") as Node3D
	castle_radius = float(core.get_meta("radius", 6.5))
	castle = Unit.new()
	castle.id = CASTLE_ID
	castle.kind = "castle"
	castle.team = Unit.Team.PLAYERS
	castle.display_name = "Замок"
	castle.max_hp = GameData.CASTLE_HP
	castle.hp = castle.max_hp
	castle.radius = castle_radius
	castle.pos = Vector3(core.position.x, 0, core.position.z)
	world.units[CASTLE_ID] = castle

func begin() -> void:
	_started = true
	var delay: float = GameData.FIRST_WAVE_DELAY if wave_count == 0 else minf(GameData.FIRST_WAVE_DELAY, 12.0 + 3.0 * wave_count)
	_next_wave_at = world.now() + delay
	var mode: String = "  (бесконечная осада)" if wave_count == 0 else ("" if wave_count == GameData.WAVE_COUNT else "  (волн: %d)" % wave_count)
	world.announce_all("Защитите замок! Первая волна через %d сек.%s" % [int(delay), mode])
	var parts: Array = []
	for l in active_lanes:
		var fd: Dictionary = GameData.FACTIONS[lane_faction[l]]
		parts.append("с %s — %s" % [["севера", "востока", "юга", "запада"][l], fd["name"].to_lower()])
	world.announce_all("Идут: %s." % ", ".join(parts), Color(1, 0.75, 0.5))

func is_resting() -> bool:
	return state == "break"

func is_combat() -> bool:
	return state == "running" or state == "clearing"

# ---------------------------------------------------------------- волны (сервер)

func server_tick(_delta: float, t: float) -> void:
	if not _started or is_over():
		return
	while not _queue.is_empty() and t >= _queue[0][0]:
		var e: Array = _queue.pop_front()
		world.mobs.spawn(e[1], e[2], wave, world.heroes.size(), e[3], {"champion": e[4] == "champion"})
	if _all_spawned:
		next_wave_in = 0.0
		if _queue.is_empty() and world.mobs.alive_count() == 0:
			finish(true)
		return
	if _break_pending:
		next_wave_in = 0.0
		if _queue.is_empty() and world.mobs.alive_count() == 0:
			_break_pending = false
			state = "break"
			_next_wave_at = t + break_time
			world.sound_all("level_up")
			world.announce_all("Передышка! Следующая волна через %d сек. — восстановите силы." % int(break_time), Color(0.6, 1.0, 0.7))
		return
	next_wave_in = maxf(0.0, _next_wave_at - t)
	if t >= _next_wave_at:
		_start_wave(t)

## Хост досрочно заканчивает передышку (или подготовку перед первой волной).
func skip() -> void:
	if state == "break" or state == "prep":
		_next_wave_at = world.now()

func _start_wave(t: float) -> void:
	wave += 1
	world.meter.new_segment("Волна %d" % wave)
	state = "running"
	var w: int = wave
	# В короткой партии (меньше 5 волн) последняя волна заканчивается боссом
	var short_final: bool = wave_count > 0 and wave_count < 5 and w == wave_count
	var factions_by_index: Array = active_lanes.map(func(l): return lane_faction[l])
	var plan: Dictionary = GameData.wave_plan(w, factions_by_index, world.heroes.size(), short_final)
	var comp: Array = plan["list"]
	var per_lane_time: Dictionary = {}
	var headliners: Array = []
	for e in comp:
		var lane: int = active_lanes[int(e[1]) % active_lanes.size()]
		var at: float = t + float(per_lane_time.get(lane, 0.0))
		per_lane_time[lane] = float(per_lane_time.get(lane, 0.0)) + 0.8
		var hp_scale: float = 0.35 if short_final and GameData.MOBS[e[0]].get("boss", false) else 1.0
		if GameData.MOBS[e[0]].get("boss", false) or e[2] == "champion":
			at += 3.0
			headliners.append(("чемпион %s" % GameData.MOBS[e[0]]["name"].to_lower()) if e[2] == "champion" else GameData.MOBS[e[0]]["name"])
		_queue.append([at, e[0], lane, hp_scale, e[2]])
	_queue.sort_custom(func(a, b): return a[0] < b[0])
	var boss := ""
	if not headliners.is_empty():
		boss = " Идёт %s!" % ", ".join(headliners)
	if plan["special"] != "":
		boss += "  %s!" % GameData.FactionData.SPECIAL_WAVES[plan["special"]]["name"]
	world.sound_all("bell")
	# боевые кличи фракций — со стороны их логов
	for l in active_lanes:
		var fs: Dictionary = GameData.FACTIONS[lane_faction[l]]["sounds"]
		var sp: Vector2 = lanes[l][0]
		world.ev_sound_at.rpc(fs["war_cry"], Vector3(sp.x * 0.45, 2.0, sp.y * 0.45), 4.0, float(fs["pitch"]))
	world.sound_all("horde")
	var last: bool = wave_count > 0 and w >= wave_count
	var after := "" if w % BREAK_EVERY != 0 or last else "  После неё — передышка."
	var of_total := "" if wave_count == 0 else " из %d" % wave_count
	world.announce_all("Волна %d%s.%s%s" % [w, of_total, boss, after], Color(1, 0.6, 0.3) if boss != "" else Color(1, 0.9, 0.6))
	if last:
		_all_spawned = true
	elif w % BREAK_EVERY == 0:
		_break_pending = true
		state = "clearing"
	else:
		_next_wave_at = t + GameData.WAVE_INTERVAL

func on_unit_destroyed(u: Unit) -> void:
	if u == castle:
		finish(false)

# ---------------------------------------------------------------- герои

func hero_spawn_point(index: int, count: int) -> Vector3:
	return hero_spawn + Vector3((index - (count - 1) * 0.5) * 2.5, 0, 0)

func hero_spawn_yaw() -> float:
	return PI

func respawn_point(_hero) -> Vector3:
	return hero_spawn + Vector3(randf_range(-2, 2), 0, randf_range(-1, 1))

# ---------------------------------------------------------------- цель движения мобов: полоса → замок

func mob_start(source: int) -> Array:
	var lane: PackedVector2Array = lanes[source]
	return [lane[0], lane[1]]

func mob_spawned(m) -> void:
	m.wp = 0

func mob_goal(m) -> Vector2:
	var lane: PackedVector2Array = lanes[m.route]
	if m.wp < lane.size() - 1 and m.pos2.distance_to(lane[m.wp]) < 4.0:
		m.wp += 1
	return lane[m.wp]

func mob_objective(_m) -> Unit:
	return castle

## Бросив погоню, моб идёт к точке маршрута впереди себя.
## Раньше он шёл к старой точке, которая за время погони оставалась позади, и снова замечал героя.
func mob_resume(m) -> void:
	var lane: PackedVector2Array = lanes[m.route]
	m.wp = mini(_nearest_segment(m) + 1, lane.size() - 1)

func mob_leash_dist(m) -> float:
	var lane: PackedVector2Array = lanes[m.route]
	var i := _nearest_segment(m)
	return Geometry2D.get_closest_point_to_segment(m.pos2, lane[i], lane[i + 1]).distance_to(m.pos2)

## Ближайший к мобу отрезок его полосы (индекс начальной точки).
## Ищем по всей полосе: во время погони m.wp не обновляется, и поиск рядом с ним
## считал моба далеко от полосы, даже когда он шёл прямо по ней.
func _nearest_segment(m) -> int:
	var lane: PackedVector2Array = lanes[m.route]
	var best := INF
	var best_i := 0
	for i in lane.size() - 1:
		var d := Geometry2D.get_closest_point_to_segment(m.pos2, lane[i], lane[i + 1]).distance_squared_to(m.pos2)
		if d < best:
			best = d
			best_i = i
	return best_i

# ---------------------------------------------------------------- сеть

func state_snapshot() -> Array:
	return [state, wave, next_wave_in, castle.hp, castle.max_hp]

func apply_snapshot(s: Array) -> void:
	state = s[0]
	wave = s[1]
	next_wave_in = s[2]
	castle.hp = s[3]
	castle.max_hp = s[4]

# ---------------------------------------------------------------- интерфейс

func hud_panel(alive_mobs: int) -> Dictionary:
	var total := "∞" if wave_count == 0 else str(wave_count)
	var title := "Подготовка" if wave == 0 else "Волна %d / %s" % [wave, total]
	if state == "clearing":
		title += "\nдобейте врагов — затем передышка"
	elif state == "break":
		title = "Передышка\nволна %d через %d сек." % [wave + 1, int(ceil(next_wave_in))]
	elif next_wave_in > 0.0:
		title += "\nследующая через %d сек." % int(ceil(next_wave_in))
	return {
		"title": title,
		"bar_visible": true, "bar": castle.hp, "bar_max": castle.max_hp,
		"bar_text": "Замок: %d / %d      Врагов: %d" % [int(castle.hp), int(castle.max_hp), alive_mobs],
		"can_skip": state == "break" or state == "prep", "skip_text": "Начать волну сейчас",
	}

func game_over_text(victory: bool) -> String:
	return "ПОБЕДА! Замок выстоял." if victory else "Замок пал..."

func game_over_details(victory: bool) -> String:
	if victory:
		return "Все волны отбиты (%d). Замок выстоял!" % wave_count
	return "Замок пал на волне %d." % wave

## Фракции по полосам. «По сторонам» (по умолчанию): юг — нежить, восток — орки, запад — демоны,
## север — гоблины и огры; направления открываются в том же порядке, поэтому при 1 направлении — нежить.
## «Случайно» — фракции перемешаны (зерно партии); «одна» — все полосы одной фракции (--faction=).
func _assign_factions() -> void:
	var mode_f := str(Net.settings.get("factions", "sides"))
	var single := str(Net.settings.get("faction", "undead"))
	if Net.cli.has("faction"):
		mode_f = "single"
		single = str(Net.cli["faction"])
	if not GameData.FACTIONS.has(single):
		single = "undead"
	var order: Array = GameData.FactionData.ORDER.duplicate()
	if mode_f == "random":
		var rng := RandomNumberGenerator.new()
		rng.seed = int(Net.settings.get("seed", 1))
		for i in range(order.size() - 1, 0, -1):
			var j := rng.randi() % (i + 1)
			var tmp = order[i]
			order[i] = order[j]
			order[j] = tmp
	for i in LANE_ORDER.size():
		var lane: int = LANE_ORDER[i]
		if mode_f == "single":
			lane_faction[lane] = single
		elif mode_f == "random":
			lane_faction[lane] = order[i]
		else:
			for f in GameData.FACTIONS:
				if int(GameData.FACTIONS[f]["lane"]) == lane:
					lane_faction[lane] = f
