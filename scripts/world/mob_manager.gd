extends Node
## Все враги карты в одной системе (без отдельных скриптов и физики на каждом мобе).
## Сервер: ИИ и движение 20 раз/сек + пространственная сетка.
## Клиенты: сжатые снимки (11 байт на моба) + плавная интерполяция.
## Это «горячее» место — первый кандидат на перенос в C++ (GDExtension).

const SIM_STEP := 0.05
const SNAP_STEP := 0.1
const CELL := 6.0
const SEP_CELL := 2.0         # мелкая сетка для расталкивания в толпе
const MAX_NEIGHBORS := 6
const AGGRO_RANGE := 11.0
const LEASH_RANGE := 32.0       # м: дальше от своей полосы моб не уходит
const CHASE_DROP_RANGE := 40.0  # м: цель дальше этого — погоня брошена (больше дальности любого заклинания героя)
const REAGGRO_DELAY := 2.5      # сек.: бросив погоню по поводку, моб столько не отвлекается на героев
const REACH_SLACK_MELEE := 0.3  # м: запас дальности, пока моб уже бьёт цель
const REACH_SLACK_RANGED := 1.5

enum S { MOVE, CHASE, WALL, CASTLE, SPAWNING }
enum AN { IDLE, MOVE, ATTACK, DEAD, STUN, SPAWN, FROZEN }

class Mob:
	var unit: Unit
	var def: Dictionary
	var lane := 0
	var wp := 1
	var state: int = S.SPAWNING
	var target := 0
	var wall := 0
	var attack_ready := 0.0
	var swing := 0
	var anim_state: int = AN.SPAWN
	var next_think := 0.0
	var spawn_until := 0.0
	var pos2 := Vector2.ZERO
	var yaw := 0.0
	# визуал
	var node: Node3D
	var anim: AnimationPlayer
	var cur_anim := ""
	var vis_target := Vector3.ZERO
	var last_swing := 0
	var anim_acc := 0.0
	var anim_lock := 0.0
	var death_time := -1.0
	var geoms: Array = []
	var ice: MeshInstance3D = null
	var anim_speed := 1.0
	var taunt_until := 0.0
	var reaggro_at := 0.0          # после того как бросил погоню, до этого времени не берёт новую цель
	var in_reach := false          # уже атакует цель (чтобы не дёргаться на краю дальности)
	var shadow_on := true

var world: Node3D
var mobs: Dictionary = {}          # id -> Mob (живые)
var dying: Array = []              # Mob — проигрывают смерть
var walls: Dictionary = {}         # id -> {a, b, hp, max, stage, until}
var client_alive_count := 0

var _grid: Dictionary = {}
var _sep_grid: Dictionary = {}
var _static_obs: Array = []        # [a: Vector2, b: Vector2, r: float]
var _obs_grid: Dictionary = {}
var _pools: Dictionary = {}
var _next_id := 1000
var _next_wall := 1
var _sim_acc := 0.0
var _snap_acc := 0.0
var _frame := 0
var _pending_spawns: Array = []
var _pending_deaths := PackedInt32Array()

func _ready() -> void:
	world = get_parent()

func alive_count() -> int:
	return mobs.size()

func alive_units() -> Array:
	var out: Array = []
	for m: Mob in mobs.values():
		out.append(m.unit)
	return out

# ---------------------------------------------------------------- препятствия

func build_static_obstacles(colliders: Node) -> void:
	for body in colliders.get_children():
		if not body is StaticBody3D:
			continue
		var cs := body.get_child(0) as CollisionShape3D
		var xf: Transform3D = (body as Node3D).transform
		var o := Vector2(xf.origin.x, xf.origin.z)
		if cs.shape is BoxShape3D:
			var size: Vector3 = (cs.shape as BoxShape3D).size
			if size.x > 100.0 or size.z > 100.0:
				continue
			var long_x := size.x >= size.z
			var axis3: Vector3 = xf.basis.x if long_x else xf.basis.z
			var axis := Vector2(axis3.x, axis3.z).normalized()
			var l := maxf(size.x, size.z)
			var w := minf(size.x, size.z)
			var half := (l - w) * 0.5
			_add_static(o - axis * half, o + axis * half, w * 0.5)
		elif cs.shape is CylinderShape3D:
			_add_static(o, o, (cs.shape as CylinderShape3D).radius)

func _add_static(a: Vector2, b: Vector2, r: float) -> void:
	var idx := _static_obs.size()
	_static_obs.append([a, b, r])
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2.ONE * (r + 2.0)
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + Vector2.ONE * (r + 2.0)
	for cx in range(floori(lo.x / CELL), floori(hi.x / CELL) + 1):
		for cy in range(floori(lo.y / CELL), floori(hi.y / CELL) + 1):
			var key := Vector2i(cx, cy)
			if not _obs_grid.has(key):
				_obs_grid[key] = []
			_obs_grid[key].append(idx)

func add_wall(a: Vector2, b: Vector2, hp: float, until: float) -> int:
	var id := _next_wall
	_next_wall += 1
	walls[id] = {"a": a, "b": b, "hp": hp, "max": maxf(hp, 1.0), "stage": 0, "until": until}
	return id

func _remove_wall(id: int) -> void:
	if walls.erase(id):
		world.spells.ev_zone_end.rpc(id)
		for m: Mob in mobs.values():
			if m.state == S.WALL and m.wall == id:
				m.state = S.MOVE

# ---------------------------------------------------------------- появление и смерть

func spawn(type: String, lane: int, wave: int, players: int, hp_scale: float = 1.0) -> void:
	var def: Dictionary = GameData.MOBS[type]
	var m := Mob.new()
	var u := Unit.new()
	u.id = _next_id
	_next_id += 1
	u.kind = "mob"
	u.team = Unit.Team.ENEMIES
	u.type_id = type
	u.display_name = def["name"]
	u.max_hp = float(def["hp"]) * GameData.mob_hp_mult(wave, players) * hp_scale
	u.hp = u.max_hp
	u.power = GameData.mob_dmg_mult(wave)
	u.phys_power = u.power
	u.armor = def["armor"]
	u.radius = def["radius"]
	u.level = wave
	m.unit = u
	m.def = def
	m.lane = lane
	var start: Vector2 = world.lanes[lane][0]
	m.pos2 = start + Vector2(randf_range(-2.5, 2.5), randf_range(-2.5, 2.5))
	var t: float = world.now()
	m.spawn_until = t + 1.3
	m.next_think = t + 1.3 + randf() * 0.4
	var nxt: Vector2 = world.lanes[lane][1]
	m.yaw = atan2(-(nxt.x - start.x), -(nxt.y - start.y))
	u.pos = Vector3(m.pos2.x, 0, m.pos2.y)
	mobs[u.id] = m
	world.units[u.id] = u
	_make_visual(m)
	_pending_spawns.append([u.id, type, m.pos2.x, m.pos2.y, m.yaw, u.max_hp, wave])

func kill(u: Unit, killer: Unit) -> void:
	var m: Mob = mobs.get(u.id, null)
	if m == null:
		return
	mobs.erase(u.id)
	world.units.erase(u.id)
	var xp := int(float(m.def["xp"]) * (1.0 + 0.1 * float(u.level - 1)))
	world.award_kill(u.pos, xp, int(m.def["gold"]))
	world.economy.roll_loot(u.pos, u.level, m.def.get("boss", false))
	_pending_deaths.append(u.id)
	_begin_dying(m)

## Провокация: моб бросается на героя и не отвлекается до конца эффекта.
func taunt(u: Unit, src: Unit, until: float) -> void:
	var m: Mob = mobs.get(u.id, null)
	if m == null or not src.alive:
		return
	m.state = S.CHASE
	m.target = src.id
	m.taunt_until = until

func on_damaged(u: Unit, src: Unit) -> void:
	var m: Mob = mobs.get(u.id, null)
	if m == null or src == null or src.kind != "hero":
		return
	if (m.state == S.MOVE or m.state == S.CASTLE) and world.now() >= m.reaggro_at:
		m.state = S.CHASE
		m.target = src.id
		m.in_reach = false

# ---------------------------------------------------------------- серверная симуляция

func server_tick(delta: float, t: float) -> void:
	if world.game_state == "victory" or world.game_state == "defeat":
		for m: Mob in mobs.values():
			m.anim_state = AN.IDLE
		return
	_sim_acc += delta
	while _sim_acc >= SIM_STEP:
		_sim_acc -= SIM_STEP
		_rebuild_grid()
		for m: Mob in mobs.values():
			_sim(m, SIM_STEP, t)
		var expired: Array = []
		for id in walls:
			if t >= walls[id]["until"]:
				expired.append(id)
		for id in expired:
			_remove_wall(id)
	_snap_acc += delta
	if _snap_acc >= SNAP_STEP:
		_snap_acc = 0.0
		if not _pending_spawns.is_empty():
			ev_spawn.rpc(_pending_spawns)
			_pending_spawns = []
		if not _pending_deaths.is_empty():
			ev_death.rpc(_pending_deaths)
			_pending_deaths = PackedInt32Array()
		if not multiplayer.get_peers().is_empty():
			ev_snapshot.rpc(_encode_snapshot())

func _rebuild_grid() -> void:
	_grid.clear()
	_sep_grid.clear()
	for m: Mob in mobs.values():
		var key := Vector2i(floori(m.pos2.x / CELL), floori(m.pos2.y / CELL))
		if not _grid.has(key):
			_grid[key] = []
		_grid[key].append(m)
		var sk := _sep_key(floori(m.pos2.x / SEP_CELL), floori(m.pos2.y / SEP_CELL))
		if not _sep_grid.has(sk):
			_sep_grid[sk] = []
		_sep_grid[sk].append(m)

static func _sep_key(cx: int, cy: int) -> int:
	return (cx + 4096) * 8192 + (cy + 4096)

## Враги в радиусе (для заклинаний по области).
func query_radius(p: Vector2, r: float) -> Array:
	var out: Array = []
	for cx in range(floori((p.x - r) / CELL), floori((p.x + r) / CELL) + 1):
		for cy in range(floori((p.y - r) / CELL), floori((p.y + r) / CELL) + 1):
			for m: Mob in _grid.get(Vector2i(cx, cy), []):
				if m.unit.alive and m.pos2.distance_to(p) <= r + m.unit.radius:
					out.append(m.unit)
	return out

func _sim(m: Mob, dt: float, t: float) -> void:
	var u := m.unit
	if t < m.spawn_until:
		return
	if m.state == S.SPAWNING:
		m.state = S.MOVE
	if u.is_stunned(t):
		m.anim_state = AN.FROZEN if u.is_frozen(t) else AN.STUN
		return
	if t >= m.next_think:
		m.next_think = t + 0.35 + randf() * 0.15
		_think(m)

	if _dbg_on:
		_dbg_track(m, t)
	var goal := m.pos2
	var moving := false
	var reach := float(m.def["range"])
	match m.state:
		S.CHASE:
			var tu: Unit = world.get_unit(m.target)
			if tu == null or not tu.alive:
				_drop_chase(m, false)
			else:
				var tp := Vector2(tu.pos.x, tu.pos.z)
				var need := reach + tu.radius + u.radius * 0.5
				if m.in_reach:
					need += REACH_SLACK_RANGED if m.def.get("ranged", false) else REACH_SLACK_MELEE
				if m.pos2.distance_to(tp) <= need:
					m.in_reach = true
					_attack(m, tu, t)
				else:
					m.in_reach = false
					goal = tp
					moving = true
		S.WALL:
			var w: Dictionary = walls.get(m.wall, {})
			if w.is_empty():
				m.state = S.MOVE
			else:
				_attack_wall(m, w, t)
		S.CASTLE:
			_attack(m, world.castle, t)
	if m.state == S.MOVE:
		var lane: PackedVector2Array = world.lanes[m.lane]
		var castle_d := m.pos2.length()
		if castle_d <= world.castle_radius + reach + u.radius:
			m.state = S.CASTLE
		else:
			if m.wp < lane.size() - 1 and m.pos2.distance_to(lane[m.wp]) < 4.0:
				m.wp += 1
			goal = lane[m.wp]
			moving = true

	if moving and not u.is_rooted(t):
		_move(m, goal, dt, t)
		m.anim_state = AN.MOVE
	elif m.anim_state == AN.MOVE or m.anim_state == AN.STUN or m.anim_state == AN.SPAWN:
		m.anim_state = AN.IDLE
	u.pos = Vector3(m.pos2.x, 0, m.pos2.y)

func _think(m: Mob) -> void:
	if m.state == S.CHASE:
		var tu: Unit = world.get_unit(m.target)
		if world.now() < m.taunt_until and tu and tu.alive:
			return
		if tu == null or not tu.alive:
			_drop_chase(m, false)
		elif Vector2(tu.pos.x, tu.pos.z).distance_to(m.pos2) > CHASE_DROP_RANGE or _lane_dist(m) > LEASH_RANGE:
			_drop_chase(m, true)
		return
	if m.state == S.MOVE and world.now() < m.reaggro_at:
		return
	var aggro := AGGRO_RANGE * (1.4 if m.def.get("ranged", false) else 1.0) * (1.3 if m.def.get("boss", false) else 1.0)
	if m.state == S.WALL:
		aggro = float(m.def["range"]) + 1.0
	var best: Unit = null
	var best_d := aggro
	for h in world.heroes.values():
		var hu: Unit = h.unit
		if not hu.alive:
			continue
		# таланты «агро» (Вызов Света): такого героя враги выбирают охотнее
		var d := Vector2(hu.pos.x, hu.pos.z).distance_to(m.pos2) / (1.0 + hu.flag("threat"))
		if d < best_d:
			best_d = d
			best = hu
	if best:
		m.state = S.CHASE
		m.target = best.id
		m.in_reach = false

## Моб бросает погоню и идёт дальше по полосе — к точке маршрута впереди себя.
## Раньше он шёл к старой точке, которая за время погони оставалась позади, и снова замечал героя.
## leash — погоня брошена по поводку: какое-то время моб не отвлекается на героев.
func _drop_chase(m: Mob, leash: bool) -> void:
	m.state = S.MOVE
	m.target = 0
	m.in_reach = false
	if leash:
		m.reaggro_at = world.now() + REAGGRO_DELAY
	var lane: PackedVector2Array = world.lanes[m.lane]
	m.wp = mini(_nearest_segment(m) + 1, lane.size() - 1)

## Ближайший к мобу отрезок его полосы (индекс начальной точки).
## Ищем по всей полосе: во время погони m.wp не обновляется, и поиск рядом с ним
## считал моба далеко от полосы, даже когда он шёл прямо по ней.
func _nearest_segment(m: Mob) -> int:
	var lane: PackedVector2Array = world.lanes[m.lane]
	var best := INF
	var best_i := 0
	for i in lane.size() - 1:
		var d := Geometry2D.get_closest_point_to_segment(m.pos2, lane[i], lane[i + 1]).distance_squared_to(m.pos2)
		if d < best:
			best = d
			best_i = i
	return best_i

func _lane_dist(m: Mob) -> float:
	var lane: PackedVector2Array = world.lanes[m.lane]
	var i := _nearest_segment(m)
	return Geometry2D.get_closest_point_to_segment(m.pos2, lane[i], lane[i + 1]).distance_to(m.pos2)

func _move(m: Mob, goal: Vector2, dt: float, t: float) -> void:
	var u := m.unit
	var to := goal - m.pos2
	if to.length() < 0.05:
		return
	var dir := to.normalized()
	var v := dir * float(m.def["speed"]) * u.speed_mult(t)
	# расталкивание соседей
	var kx := floori(m.pos2.x / SEP_CELL)
	var ky := floori(m.pos2.y / SEP_CELL)
	var pushes := 0
	for cx in range(kx - 1, kx + 2):
		for cy in range(ky - 1, ky + 2):
			for n: Mob in _sep_grid.get(_sep_key(cx, cy), []):
				if n == m:
					continue
				var diff := m.pos2 - n.pos2
				var min_d := u.radius + n.unit.radius
				var d2 := diff.length_squared()
				if d2 < min_d * min_d and d2 > 0.0001:
					var d := sqrt(d2)
					v += diff / d * (min_d - d) * 5.0
					pushes += 1
					if pushes >= MAX_NEIGHBORS:
						break
			if pushes >= MAX_NEIGHBORS:
				break
		if pushes >= MAX_NEIGHBORS:
			break
	var np := m.pos2 + v * dt
	# ледяные стены
	for id in walls:
		var w: Dictionary = walls[id]
		var cp := Geometry2D.get_closest_point_to_segment(np, w["a"], w["b"])
		if cp.distance_to(np) < u.radius + 0.9:
			var was := Geometry2D.get_closest_point_to_segment(m.pos2, w["a"], w["b"])
			if cp.distance_to(np) < was.distance_to(m.pos2) + 0.01:
				np = m.pos2
				if m.state == S.MOVE or (m.state == S.CHASE and not m.def.get("ranged", false)):
					m.state = S.WALL
					m.wall = id
				break
	# стены города и здания
	var okey := Vector2i(floori(np.x / CELL), floori(np.y / CELL))
	for idx in _obs_grid.get(okey, []):
		var ob: Array = _static_obs[idx]
		var cp := Geometry2D.get_closest_point_to_segment(np, ob[0], ob[1])
		var diff := np - cp
		var min_d: float = ob[2] + u.radius
		var d := diff.length()
		if d < min_d:
			if d < 0.001:
				diff = -dir
				d = 1.0
			np = cp + diff / d * min_d
	m.pos2 = np
	if v.length_squared() > 0.01:
		m.yaw = atan2(-v.x, -v.y)

func _face(m: Mob, p: Vector2) -> void:
	var to := p - m.pos2
	if to.length_squared() > 0.01:
		m.yaw = atan2(-to.x, -to.y)

func _attack(m: Mob, tu: Unit, t: float) -> void:
	_face(m, Vector2(tu.pos.x, tu.pos.z))
	if t < m.attack_ready:
		if m.anim_state != AN.ATTACK:
			m.anim_state = AN.IDLE
		return
	m.attack_ready = t + float(m.def["atk_speed"])
	m.swing = (m.swing + 1) % 32
	m.anim_state = AN.ATTACK
	var fx := [{"type": "damage", "min": m.def["min"], "max": m.def["max"]}]
	if m.def.get("ranged", false):
		world.spells._launch_projectile(m.unit, tu, fx, "mob", "shadow", 20.0, "bolt_shadow", t)
	else:
		world.spells.apply_effects(m.unit, tu, fx, "mob", "physical")
		if m.def.has("cleave"):
			for h in world.heroes.values():
				var hu: Unit = h.unit
				if hu != tu and hu.alive and Vector2(hu.pos.x, hu.pos.z).distance_to(Vector2(tu.pos.x, tu.pos.z)) < float(m.def["cleave"]):
					world.spells.apply_effects(m.unit, hu, fx, "mob", "physical")

func _attack_wall(m: Mob, w: Dictionary, t: float) -> void:
	var cp := Geometry2D.get_closest_point_to_segment(m.pos2, w["a"], w["b"])
	_face(m, cp)
	if t < m.attack_ready:
		if m.anim_state != AN.ATTACK:
			m.anim_state = AN.IDLE
		return
	m.attack_ready = t + float(m.def["atk_speed"])
	m.swing = (m.swing + 1) % 32
	m.anim_state = AN.ATTACK
	w["hp"] -= randf_range(m.def["min"], m.def["max"]) * m.unit.power
	if w["hp"] <= 0.0:
		_remove_wall(m.wall)
		return
	# стадии повреждения видны всем: меньше половины и меньше четверти прочности
	var frac: float = w["hp"] / w["max"]
	var stage := 2 if frac <= 0.25 else (1 if frac <= 0.5 else 0)
	if stage > int(w["stage"]):
		w["stage"] = stage
		ev_wall_damage.rpc(m.wall, stage)

# ---------------------------------------------------------------- сеть

@rpc("authority", "call_local", "reliable")
func ev_wall_damage(id: int, stage: int) -> void:
	Vfx.damage_wall(id, stage)

func _encode_snapshot() -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(2 + mobs.size() * 11)
	buf.encode_u16(0, mobs.size())
	var o := 2
	for m: Mob in mobs.values():
		buf.encode_u32(o, m.unit.id)
		buf.encode_s16(o + 4, int(clampf(m.pos2.x * 100.0, -32767, 32767)))
		buf.encode_s16(o + 6, int(clampf(m.pos2.y * 100.0, -32767, 32767)))
		buf.encode_u8(o + 8, int(fposmod(m.yaw, TAU) / TAU * 255.0))
		buf.encode_u8(o + 9, (m.anim_state & 7) | ((m.swing & 31) << 3))
		buf.encode_u8(o + 10, int(m.unit.hp_frac() * 255.0))
		o += 11
	return buf

@rpc("authority", "unreliable_ordered")
func ev_snapshot(buf: PackedByteArray) -> void:
	var count := buf.decode_u16(0)
	var o := 2
	for i in count:
		var id := buf.decode_u32(o)
		var m: Mob = mobs.get(id, null)
		if m:
			m.pos2 = Vector2(buf.decode_s16(o + 4) * 0.01, buf.decode_s16(o + 6) * 0.01)
			m.yaw = float(buf.decode_u8(o + 8)) / 255.0 * TAU
			var st := buf.decode_u8(o + 9)
			m.anim_state = st & 7
			m.swing = st >> 3
			m.unit.hp = float(buf.decode_u8(o + 10)) / 255.0 * m.unit.max_hp
		o += 11

@rpc("authority", "reliable")
func ev_spawn(list: Array) -> void:
	for e in list:
		var def: Dictionary = GameData.MOBS[e[1]]
		var m := Mob.new()
		var u := Unit.new()
		u.id = e[0]
		u.kind = "mob"
		u.team = Unit.Team.ENEMIES
		u.type_id = e[1]
		u.display_name = def["name"]
		u.max_hp = e[5]
		u.hp = u.max_hp
		u.radius = def["radius"]
		u.level = e[6]
		m.unit = u
		m.def = def
		m.pos2 = Vector2(e[2], e[3])
		m.yaw = e[4]
		m.anim_state = AN.SPAWN
		u.pos = Vector3(m.pos2.x, 0, m.pos2.y)
		mobs[u.id] = m
		world.units[u.id] = u
		_make_visual(m)

@rpc("authority", "reliable")
func ev_death(ids: PackedInt32Array) -> void:
	for id in ids:
		var m: Mob = mobs.get(id, null)
		if m == null:
			continue
		mobs.erase(id)
		world.units.erase(id)
		m.unit.alive = false
		_begin_dying(m)

# ---------------------------------------------------------------- визуал

func _make_visual(m: Mob) -> void:
	var type: String = m.unit.type_id
	var pool: Array = _pools.get(type, [])
	if pool.is_empty():
		m.node = ModelFactory.build_mob(type)
		world.add_child(m.node)
	else:
		m.node = pool.pop_back()
		m.node.visible = true
	m.anim = ModelFactory.find_anim(m.node)
	m.geoms = m.node.find_children("*", "GeometryInstance3D", true, false)
	m.shadow_on = true
	if m.anim:
		m.anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	m.vis_target = Vector3(m.pos2.x, 0, m.pos2.y)
	m.node.position = m.vis_target
	m.node.rotation.y = m.yaw
	m.cur_anim = ""
	m.last_swing = m.swing
	m.anim_lock = 0.0
	if m.ice:
		m.ice.visible = false
	_play(m, "Spawn_Ground_Skeletons", 0.0)
	m.anim_lock = 1.2
	if m.def.get("boss", false):
		Sfx.play_at("boss_roar", m.node.position + Vector3(0, 2, 0), 6.0)
	m.unit.node = m.node

func _set_ice(m: Mob, on: bool) -> void:
	if on and m.ice == null:
		m.ice = MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.75
		cm.bottom_radius = 0.95
		cm.height = 2.7
		cm.radial_segments = 6
		cm.rings = 1
		m.ice.mesh = cm
		m.ice.position.y = 1.2
		m.ice.material_override = Vfx.ice_material()
		m.ice.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		m.node.add_child(m.ice)
	if m.ice:
		m.ice.visible = on

func _begin_dying(m: Mob) -> void:
	_set_ice(m, false)
	Sfx.play_at("bones_fall", m.node.position + Vector3(0, 0.5, 0))
	m.death_time = 2.6
	m.unit.alive = false
	_play(m, "Death_C_Skeletons", 0.1)
	dying.append(m)

func _process(delta: float) -> void:
	_frame += 1
	var cam := get_viewport().get_camera_3d()
	var cam_pos := cam.global_position if cam else Vector3.ZERO
	var k := 1.0 - exp(-12.0 * delta)
	for m: Mob in mobs.values():
		m.vis_target = Vector3(m.pos2.x, 0, m.pos2.y)
		m.node.position = m.node.position.lerp(m.vis_target, k)
		m.node.rotation.y = lerp_angle(m.node.rotation.y, m.yaw, k)
		if not Net.is_server():
			m.unit.pos = m.node.position
		_choose_anim(m, delta)
		_advance_anim(m, delta, cam_pos)
	var i := 0
	while i < dying.size():
		var m: Mob = dying[i]
		m.death_time -= delta
		_advance_anim(m, delta, cam_pos)
		if m.death_time <= 0.0:
			m.node.visible = false
			var type: String = m.unit.type_id
			if not _pools.has(type):
				_pools[type] = []
			_pools[type].append(m.node)
			dying.remove_at(i)
		else:
			i += 1

func _choose_anim(m: Mob, delta: float) -> void:
	_set_ice(m, m.anim_state == AN.FROZEN)
	if m.anim_state == AN.FROZEN:
		return
	if m.anim_lock > 0.0:
		m.anim_lock -= delta
		if m.anim_state != AN.MOVE or m.cur_anim == "Spawn_Ground_Skeletons":
			return
	if m.swing != m.last_swing:
		m.last_swing = m.swing
		var atk := "1H_Melee_Attack_Chop"
		if m.def.get("ranged", false):
			atk = "Spellcast_Shoot"
		elif m.unit.type_id == "rogue":
			atk = "Dualwield_Melee_Attack_Slice"
		elif m.def.get("boss", false):
			atk = "2H_Melee_Attack_Chop"
		_play(m, atk, 0.08, true)
		m.anim_lock = 0.7
		Sfx.play_at("mob_swing", m.node.position + Vector3(0, 1.2, 0))
		return
	match m.anim_state:
		AN.MOVE:
			# темп бега под скорость моба, чтобы ноги не скользили по земле
			_play(m, "Running_A", 0.2)
			m.anim_speed = clampf(float(m.def["speed"]) / (4.6 * float(m.def.get("scale", 1.0))), 0.6, 1.4)
			return
		AN.STUN:
			_play(m, "Hit_B", 0.1)
		_:
			_play(m, "Idle_Combat" if m.state != S.MOVE else "Idle", 0.2)

func _advance_anim(m: Mob, delta: float, cam_pos: Vector3) -> void:
	if m.anim == null or m.anim_state == AN.FROZEN:
		return
	m.anim_acc += delta
	var d2 := m.node.position.distance_squared_to(cam_pos)
	# тени только у ближних мобов — экономит вызовы отрисовки
	var want_shadow := d2 < 32.0 * 32.0
	if want_shadow != m.shadow_on:
		m.shadow_on = want_shadow
		for g: GeometryInstance3D in m.geoms:
			g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if want_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var every := 1
	if d2 > 90.0 * 90.0:
		every = 6
	elif d2 > 55.0 * 55.0:
		every = 3
	elif d2 > 30.0 * 30.0:
		every = 2
	if (_frame + m.unit.id) % every == 0:
		m.anim.advance(m.anim_acc * (m.anim_speed if m.anim_state == AN.MOVE else 1.0))
		m.anim_acc = 0.0

func _play(m: Mob, n: String, blend: float, force: bool = false) -> void:
	if m.anim == null or (m.cur_anim == n and not force):
		return
	if m.anim.has_animation(n):
		m.cur_anim = n
		m.anim.play(n, blend)
		if force:
			m.anim.seek(0.0, false)

# ---------------------------------------------------------------- --chasedebug
## Счётчик «беготни»: моб бросил погоню (CHASE → MOVE) и меньше чем через 2 с снова погнался (MOVE → CHASE).
var _dbg_on: bool = Net.cli.has("chasedebug")
var _dbg_state: Dictionary = {}
var _dbg_drop: Dictionary = {}
var dbg_drops := 0
var dbg_flips := 0
var dbg_chases := 0

func _dbg_track(m: Mob, t: float) -> void:
	var id: int = m.unit.id
	var prev: int = _dbg_state.get(id, -1)
	if prev == S.CHASE and m.state == S.MOVE:
		_dbg_drop[id] = t
		dbg_drops += 1
	if prev != S.CHASE and m.state == S.CHASE:
		dbg_chases += 1
	elif prev == S.MOVE and m.state == S.CHASE and t - float(_dbg_drop.get(id, -100.0)) < 2.0:
		dbg_flips += 1
	_dbg_state[id] = m.state
