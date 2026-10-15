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

enum S { MOVE, CHASE, WALL, OBJECTIVE, SPAWNING }   # OBJECTIVE — бьёт цель режима (замок)
enum AN { IDLE, MOVE, ATTACK, DEAD, STUN, SPAWN, FROZEN, CAST }

class Mob:
	var unit: Unit
	var def: Dictionary
	var route := 0                 # данные режима: откуда вышел (у осады — полоса)
	var wp := 1                    # и какая точка маршрута следующая
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
	# способности
	var ab_ready: Dictionary = {}     # id способности -> когда готова
	var used: Dictionary = {}         # использованные «один раз»
	var locked: Dictionary = {}       # школа -> до какого времени заблокирована (прерывание)
	var cast: Dictionary = {}         # текущий каст: {ab, until, pick, center}
	var extra_abilities: Array = []   # от аффиксов элитных
	var fleeing := false              # вор убегает с золотом
	var trail_at := 0.0               # огненный след элитного
	var stolen := 0
	var stolen_from := 0

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
		# у рощи в одном теле по цилиндру на каждое дерево
		for child in body.get_children():
			var cs := child as CollisionShape3D
			if cs == null:
				continue
			var xf: Transform3D = (body as Node3D).transform * cs.transform
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

## opts: champion — чемпион фракции (сильнее, позже — 3 аффикса); pos — место появления (призыв).
func spawn(type: String, source: int, wave: int, players: int, hp_scale: float = 1.0, opts: Dictionary = {}) -> int:
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
	if Net.cli.has("mobhp"):
		u.max_hp *= float(Net.cli["mobhp"])    # тест: враги живут дольше, бой без пауз
	u.hp = u.max_hp
	u.power = GameData.mob_dmg_mult(wave)
	u.phys_power = u.power
	u.armor = def["armor"]
	u.radius = def["radius"]
	u.level = wave
	u.def_ranged = def.get("ranged", false)
	m.unit = u
	m.def = def
	m.route = source
	var want_elite: bool = opts.get("champion", false) or (not def.get("boss", false) and (not opts.has("pos") or Net.cli.has("elite")) and def["role"] != "test"
		and (Net.cli.has("elite") or randf() < GameData.AffixData.elite_chance(wave)))
	if want_elite:
		_make_elite(m, opts.get("champion", false), wave)
	var ends: Array = world.mode.mob_start(source)
	var start: Vector2 = ends[0]
	m.pos2 = start + Vector2(randf_range(-2.5, 2.5), randf_range(-2.5, 2.5))
	if opts.has("pos"):
		m.pos2 = opts["pos"]
	var t: float = world.now()
	m.spawn_until = t + 1.3
	m.next_think = t + 1.3 + randf() * 0.4
	for aid in def.get("abilities", []):
		m.ab_ready[aid] = t + 2.0 + randf() * 3.0     # не все разом в первую же секунду
	var nxt: Vector2 = ends[1]
	world.mode.mob_spawned(m)
	m.yaw = atan2(-(nxt.x - start.x), -(nxt.y - start.y))
	u.pos = Vector3(m.pos2.x, 0, m.pos2.y)
	mobs[u.id] = m
	world.units[u.id] = u
	_make_visual(m)
	_pending_spawns.append([u.id, type, m.pos2.x, m.pos2.y, m.yaw, u.max_hp, wave, u.affixes, u.elite])
	return u.id

func kill(u: Unit, killer: Unit) -> void:
	var m: Mob = mobs.get(u.id, null)
	if m == null:
		return
	mobs.erase(u.id)
	world.units.erase(u.id)
	var reward := GameData.AffixData.ELITE_REWARD if u.elite > 0 else 1.0
	var xp := int(float(m.def["xp"]) * (1.0 + 0.1 * float(u.level - 1)) * reward)
	world.award_kill(u.pos, xp, int(float(m.def["gold"]) * reward))
	world.economy.roll_loot(u.pos, u.level, "boss" if m.def.get("boss", false) else ("champion" if u.elite == 2 else ("elite" if u.elite == 1 else "mob")))
	if u.affixes.has("explosive"):
		_delayed.append({"at": world.now() + 1.5, "pos": m.pos2, "r": 5.0, "min": 30.0, "max": 40.0, "power": u.power})
		ev_telegraph.rpc("circle", u.pos, 0.0, 5.0, 0.0, 1.5)
	world.mode.on_mob_killed(u, killer, m.def.get("boss", false))
	corpses.append({"pos": m.pos2, "until": world.now() + CORPSE_TIME})
	if corpses.size() > 80:
		corpses.pop_front()
	if m.stolen > 0:
		var victim = world.heroes.get(m.stolen_from, null)
		if victim:
			victim.gold += m.stolen
			world.announce_all("Золото возвращено: %d." % m.stolen, Color(1, 0.85, 0.3))
	casts.erase(u.id)
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
	if (m.state == S.MOVE or m.state == S.OBJECTIVE) and world.now() >= m.reaggro_at:
		m.state = S.CHASE
		m.target = src.id
		m.in_reach = false

# ---------------------------------------------------------------- серверная симуляция

func server_tick(delta: float, t: float) -> void:
	if not corpses.is_empty() and float(corpses[0]["until"]) < t:
		corpses = corpses.filter(func(c): return float(c["until"]) >= t)
	if world.mode.is_over():
		for m: Mob in mobs.values():
			m.anim_state = AN.IDLE
		return
	_tick_hazards(delta, t)
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
		_cancel_cast(m, false)
		m.anim_state = AN.FROZEN if u.is_frozen(t) else AN.STUN
		return
	if t >= m.next_think:
		m.next_think = t + 0.35 + randf() * 0.15
		_think(m)
		_try_abilities(m, t)
	if not m.cast.is_empty():
		# произносит: стоит лицом к цели
		var cu: Unit = world.get_unit(int(m.cast["pick"].get("unit", 0)))
		if cu and cu != u and cu.alive:
			_face(m, Vector2(cu.pos.x, cu.pos.z))
		m.anim_state = AN.CAST
		if t >= float(m.cast["until"]):
			_finish_cast(m, t)
		u.pos = Vector3(m.pos2.x, 0, m.pos2.y)
		return
	if m.fleeing:
		# вор бежит к логову; добежал — пропал вместе с золотом
		var home: Vector2 = world.mode.mob_start(m.route)[0]
		if m.pos2.distance_to(home) < 3.0:
			world.announce_all("%s сбежал с %d золота." % [u.display_name, m.stolen], Color(1, 0.6, 0.4))
			_despawn(m)
			return
		if not u.is_rooted(t):
			_move(m, home, dt, t)
		m.anim_state = AN.MOVE
		u.pos = Vector3(m.pos2.x, 0, m.pos2.y)
		return

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
		S.OBJECTIVE:
			var obj: Unit = world.mode.mob_objective(m)
			if obj == null or not obj.alive:
				m.state = S.MOVE
			else:
				_attack(m, obj, t)
	if m.state == S.MOVE:
		# куда идти, решает режим: у осады — по полосе к замку
		var target_obj: Unit = world.mode.mob_objective(m)
		if target_obj and target_obj.alive and m.pos2.distance_to(Vector2(target_obj.pos.x, target_obj.pos.z)) <= target_obj.radius + reach + u.radius:
			m.state = S.OBJECTIVE
		else:
			goal = world.mode.mob_goal(m)
			moving = true

	if moving and not u.is_rooted(t):
		_move(m, goal, dt, t)
		_elite_trail(m, t)
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
		elif Vector2(tu.pos.x, tu.pos.z).distance_to(m.pos2) > CHASE_DROP_RANGE or world.mode.mob_leash_dist(m) > LEASH_RANGE:
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

## Моб бросает погоню и продолжает путь (у осады — к точке полосы впереди себя).
## leash — погоня брошена по поводку: какое-то время моб не отвлекается на героев.
func _drop_chase(m: Mob, leash: bool) -> void:
	m.state = S.MOVE
	m.target = 0
	m.in_reach = false
	if leash:
		m.reaggro_at = world.now() + REAGGRO_DELAY
	world.mode.mob_resume(m)

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
	m.attack_ready = t + float(m.def["atk_speed"]) * maxf(0.4, 1.0 - m.unit.mod("haste"))
	m.swing = (m.swing + 1) % 32
	m.anim_state = AN.ATTACK
	var fx: Array = [{"type": "damage", "min": m.def["min"], "max": m.def["max"]}]
	fx.append_array(m.def.get("on_hit", []))     # выжигание маны, кража золота…
	if m.def.get("ranged", false):
		var school: String = m.def.get("school", "shadow")
		world.spells._launch_projectile(m.unit, tu, fx, "mob", school, 20.0, m.def.get("proj", "bolt_shadow"), t)
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
		u.def_ranged = def.get("ranged", false)
		if e.size() > 8:
			u.affixes = e[7]
			u.elite = e[8]
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
	if m.def.get("src", "enemy") != "enemy":
		_play(m, "Cheer", 0.0)          # у моделей героев и монстров нет подъёма из земли — боевой клич
	else:
		_play(m, "Spawn_Ground_Skeletons", 0.0)
	m.anim_lock = 1.2
	if m.def.get("boss", false):
		Sfx.play_at("boss_roar", m.node.position + Vector3(0, 2, 0), 6.0)
	m.unit.node = m.node
	_elite_visual(m)
	m.geoms = m.node.find_children("*", "GeometryInstance3D", true, false)    # аура элитного могла смениться

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
	var fs: Dictionary = GameData.FACTIONS.get(m.def.get("faction", "undead"), GameData.FACTIONS["undead"])["sounds"]
	Sfx.play_at(fs["death"], m.node.position + Vector3(0, 0.5, 0), 0.0, float(fs["pitch"]))
	m.death_time = 2.6
	m.unit.alive = false
	_play(m, "Death_C_Skeletons" if m.def.get("src", "enemy") == "enemy" else "Death_A", 0.1)
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
		var atk: String = m.def.get("attack_anim", "Spellcast_Shoot" if m.def.get("ranged", false) else "1H_Melee_Attack_Chop")
		_play(m, atk, 0.08, true)
		m.anim_lock = 0.7
		var sw_p: float = GameData.FACTIONS.get(m.def.get("faction", "undead"), GameData.FACTIONS["undead"])["sounds"]["pitch"]
		Sfx.play_at("mob_swing", m.node.position + Vector3(0, 1.2, 0), 0.0, sw_p)
		return
	if m.anim_state == AN.CAST:
		var cdata: Dictionary = casts.get(m.unit.id, {})
		var can: String = GameData.MOB_ABILITIES.get(cdata.get("ab", ""), {}).get("anim", "Spellcasting")
		_play(m, "Spellcasting" if can == "" else can, 0.15)
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

## Если у модели нет анимации (модели героев и скелетов немного различаются) — похожая.
const ANIM_FALLBACK := {"Idle_Combat": "Idle", "Unarmed_Melee_Attack_Punch_A": "1H_Melee_Attack_Chop",
	"Unarmed_Melee_Attack_Punch_B": "1H_Melee_Attack_Chop", "Spellcast_Summon": "Spellcast_Raise", "Interact": "Spellcasting",
	"2H_Melee_Attack_Spinning": "2H_Melee_Attack_Chop", "Dualwield_Melee_Attack_Stab": "1H_Melee_Attack_Stab"}

func _play(m: Mob, n: String, blend: float, force: bool = false) -> void:
	if m.anim and m.def.get("src", "") == "monster" and not m.anim.has_animation(n):
		n = ModelFactory.monster_anim(m.unit.type_id, n)     # своя схема анимаций (модели Quaternius)
	if m.anim and not m.anim.has_animation(n) and ANIM_FALLBACK.has(n):
		n = ANIM_FALLBACK[n]
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

## Провокация на мобе: [до какого времени, id героя] или [].
func taunt_info(u: Unit) -> Array:
	var m: Mob = mobs.get(u.id, null)
	if m == null or m.taunt_until <= 0.0:
		return []
	return [m.taunt_until, m.target]

# ---------------------------------------------------------------- способности врагов
## Решение — в _think (2–3 раза в секунду). Каст — поле моба, а не состояние: во время каста моб стоит
## лицом к цели; оглушение, заморозка или отбрасывание его сбивают, прерывание героя — ещё и блокирует школу.
## Клиенты узнают о касте надёжным событием (ev_mob_cast), а не из снимка.

const CORPSE_TIME := 25.0
var corpses: Array = []            # сервер: [{pos: Vector2, until}]
var casts: Dictionary = {}         # у всех: id моба -> {ab, start, dur, interrupt}

func _ability_ready(m: Mob, aid: String, t: float) -> bool:
	return t >= float(m.ab_ready.get(aid, 0.0))

func _try_abilities(m: Mob, t: float) -> void:
	if not m.cast.is_empty() or m.fleeing:
		return
	for aid in m.def.get("abilities", []) + m.extra_abilities:
		if not _ability_ready(m, aid, t):
			continue
		var ab: Dictionary = GameData.MOB_ABILITIES[aid]
		if t < float(m.locked.get(ab.get("school", ""), 0.0)) or t < m.unit.silence_until:
			continue
		var cond: Dictionary = ab.get("cond", {})
		if cond.get("once", false) and m.used.has(aid):
			continue
		if cond.has("hp_below") and m.unit.hp_frac() >= float(cond["hp_below"]):
			continue
		var pick := _pick_target(m, ab)
		if pick.is_empty():
			continue
		m.used[aid] = true
		m.ab_ready[aid] = t + float(ab["cd"])
		_begin_cast(m, aid, ab, pick, t)
		return

## Цель способности: {"unit": id, "point": Vector2, "corpse": индекс} или {} — не нашлось.
func _pick_target(m: Mob, ab: Dictionary) -> Dictionary:
	var rng := float(ab["range"])
	match ab["target"]:
		"self":
			if ab.get("delivery", "") == "allies" and m.state != S.CHASE and m.state != S.OBJECTIVE and m.state != S.WALL:
				return {}      # баффы — только в бою
			return {"unit": m.unit.id, "point": m.pos2}
		"enemy", "enemy_point":
			var best: Unit = world.get_unit(m.target) if m.state == S.CHASE else null
			if best == null or not best.alive or best.kind != "hero" or _d(m, best) > rng:
				best = null
				var bd := rng
				for h in world.heroes.values():
					var hu: Unit = h.unit
					if hu.alive and _d(m, hu) <= bd:
						bd = _d(m, hu)
						best = hu
			if best == null:
				return {}
			if ab.get("cond", {}).has("min_dist") and _d(m, best) < float(ab["cond"]["min_dist"]):
				return {}
			return {"unit": best.id, "point": Vector2(best.pos.x, best.pos.z)}
		"ally_hurt", "ally":
			var best_m: Unit = null
			var bf := 0.7 if ab["target"] == "ally_hurt" else 2.0
			for o: Unit in query_radius(m.pos2, rng):
				var om: Mob = mobs.get(o.id, null)
				if om == null or (ab["target"] == "ally" and om.state != S.CHASE and om.state != S.OBJECTIVE):
					continue
				if o.hp_frac() < bf:
					bf = o.hp_frac()
					best_m = o
			if best_m == null:
				return {}
			return {"unit": best_m.id, "point": Vector2(best_m.pos.x, best_m.pos.z)}
		"corpse":
			for i in corpses.size():
				if (corpses[i]["pos"] as Vector2).distance_to(m.pos2) <= rng:
					return {"unit": 0, "point": corpses[i]["pos"], "corpse": i}
			return {}
		"wall_or_enemy":
			if m.state == S.WALL and walls.has(m.wall):
				return {"unit": 0, "point": m.pos2, "wall": m.wall}
			for h in world.heroes.values():
				if h.unit.alive and _d(m, h.unit) <= rng:
					return {"unit": h.unit.id, "point": m.pos2}
			return {}
	return {}

func _d(m: Mob, u: Unit) -> float:
	return m.pos2.distance_to(Vector2(u.pos.x, u.pos.z)) - u.radius

func _begin_cast(m: Mob, aid: String, ab: Dictionary, pick: Dictionary, t: float) -> void:
	if Net.cli.has("castlog"):
		print("MOBCAST ", m.unit.type_id, " ", aid)
	var dur := float(ab.get("cast", 0.0))
	m.cast = {"ab": aid, "until": t + dur, "pick": pick}
	_face(m, pick["point"])
	if ab.has("telegraph"):
		var tg: Dictionary = ab["telegraph"]
		var center: Vector2 = pick["point"] if tg["shape"] == "circle" else m.pos2
		if ab["delivery"] == "self_explode":
			center = m.pos2
		m.cast["center"] = center
		ev_telegraph.rpc(tg["shape"], Vector3(center.x, 0, center.y), m.yaw, float(tg["radius"]), float(tg.get("angle", 0.0)), maxf(dur, 0.3))
	if dur > 0.0:
		ev_mob_cast.rpc(m.unit.id, aid, dur, bool(ab.get("interrupt", false)))
	else:
		_finish_cast(m, t)

func _cancel_cast(m: Mob, interrupted: bool) -> void:
	if m.cast.is_empty():
		return
	m.cast = {}
	ev_mob_cast_end.rpc(m.unit.id, interrupted)

## Прерывание героем: сбивает сбиваемый каст и блокирует школу на lock секунд.
func interrupt(u: Unit, lock: float) -> bool:
	var m: Mob = mobs.get(u.id, null)
	if m == null or m.cast.is_empty():
		return false
	var ab: Dictionary = GameData.MOB_ABILITIES[m.cast["ab"]]
	if not ab.get("interrupt", false):
		return false
	m.locked[ab.get("school", "")] = world.now() + lock
	_cancel_cast(m, true)
	return true

## Сбить каст без блокировки школы (оглушение, заморозка, отбрасывание).
func stop_cast(u: Unit) -> void:
	var m: Mob = mobs.get(u.id, null)
	if m:
		_cancel_cast(m, false)

func _finish_cast(m: Mob, t: float) -> void:
	var aid: String = m.cast["ab"]
	var ab: Dictionary = GameData.MOB_ABILITIES[aid]
	var pick: Dictionary = m.cast["pick"]
	var center: Vector2 = m.cast.get("center", pick["point"])
	m.cast = {}
	if float(ab.get("cast", 0.0)) > 0.0:
		ev_mob_cast_end.rpc(m.unit.id, false)
	m.swing = (m.swing + 1) % 32
	m.anim_state = AN.ATTACK
	var sid := "mab:" + aid
	var school: String = ab.get("school", "physical")
	var fx: Array = ab.get("effects", [])
	var tu: Unit = world.get_unit(int(pick.get("unit", 0)))
	match ab["delivery"]:
		"target":
			if tu and tu.alive:
				world.spells.apply_effects(m.unit, tu, fx, sid, school)
				world.spells.fx_at("hit_" + school, tu.pos, m.unit.pos, 0.0, tu.id)
		"projectile":
			if tu and tu.alive:
				world.spells._launch_projectile(m.unit, tu, fx, sid, school, 22.0, "bolt_" + school, t)
		"chain":
			var hit: Array = []
			var cur: Unit = tu
			var from := m.unit.pos
			for i in int(ab.get("jumps", 3)):
				if cur == null or not cur.alive:
					break
				hit.append(cur)
				world.spells.apply_effects(m.unit, cur, fx, sid, school)
				world.spells.fx_at("hit_" + school, cur.pos, from, 0.0, cur.id)
				from = cur.pos
				var nxt: Unit = null
				var nd := float(ab.get("jump_range", 9.0))
				for h in world.heroes.values():
					var hu: Unit = h.unit
					if hu.alive and not hit.has(hu) and hu.pos.distance_to(cur.pos) <= nd:
						nd = hu.pos.distance_to(cur.pos)
						nxt = hu
				cur = nxt
		"area", "self_explode", "leap", "cone":
			if ab["delivery"] == "leap":
				var dest: Vector2 = pick["point"]
				if tu and ab["target"] == "enemy":
					dest = Vector2(tu.pos.x, tu.pos.z)
					dest += (m.pos2 - dest).normalized() * (tu.radius + m.unit.radius)
				m.pos2 = dest
				m.unit.pos = Vector3(dest.x, 0, dest.y)
				center = dest
			var r: float = float(ab.get("telegraph", {}).get("radius", 3.0))
			for h in world.heroes.values():
				var hu: Unit = h.unit
				if not hu.alive:
					continue
				var hp2 := Vector2(hu.pos.x, hu.pos.z)
				if hp2.distance_to(center) > r + hu.radius:
					continue
				if ab["delivery"] == "cone":
					var to := hp2 - m.pos2
					var fwd := Vector2(-sin(m.yaw), -cos(m.yaw))
					if to.length() > 0.5 and rad_to_deg(absf(fwd.angle_to(to.normalized()))) > float(ab["telegraph"].get("angle", 90.0)) * 0.5:
						continue
				world.spells.apply_effects(m.unit, hu, fx, sid, school)
			world.spells.fx_at("explosion_fire" if school == "fire" else "nova_phys", Vector3(center.x, 0, center.y), m.unit.pos, r, 0)
			if ab["delivery"] == "self_explode":
				var wd := float(ab.get("wall_damage", 0.0))
				for wid in walls.keys():
					var w: Dictionary = walls[wid]
					if Geometry2D.get_closest_point_to_segment(center, w["a"], w["b"]).distance_to(center) <= r:
						w["hp"] -= wd
						if w["hp"] <= 0.0:
							_remove_wall(wid)
				m.unit.hp = 0.0
				world.spells._on_death(m.unit, null)
		"allies":
			for o: Unit in query_radius(m.pos2, float(ab.get("radius", 10.0))):
				world.spells.apply_effects(m.unit, o, fx, sid, school)
			if not ab.get("silent", false):
				world.spells.fx_at("aura_war", m.unit.pos, m.unit.pos, 0.0, m.unit.id)
		"summon":
			var kind: String = ab.get("summon", "")
			if kind == "":
				kind = _swarm_of(m.def.get("faction", "undead"))
			for i in int(ab.get("count", 2)):
				var p: Vector2 = pick["point"] + Vector2(randf_range(-1.5, 1.5), randf_range(-1.5, 1.5))
				var sid2: int = spawn(kind, m.route, m.unit.level, world.heroes.size(), 0.7, {"pos": p})
				var sm: Mob = mobs.get(sid2, null)
				if sm:
					sm.wp = m.wp
			_take_corpse(pick)
		"devour":
			world.spells.heal(m.unit, m.unit, m.unit.max_hp * float(ab.get("heal_pct", 0.3)), false, sid)
			world.spells.fx_at("hit_blood", m.unit.pos, m.unit.pos, 0.0, m.unit.id)
			_take_corpse(pick)

func _take_corpse(pick: Dictionary) -> void:
	if pick.has("corpse"):
		var i: int = pick["corpse"]
		if i < corpses.size():
			corpses.remove_at(i)

## Самый дешёвый «массовый» враг фракции — для призыва подмоги.
func _swarm_of(faction: String) -> String:
	for id in GameData.MOBS:
		var d: Dictionary = GameData.MOBS[id]
		if d.get("faction", "") == faction and d["role"] == "swarm":
			return id
	return "minion"

## Отбрасывание моба (эффект knockback): толчок от источника, сбивает каст.
func push(u: Unit, vec: Vector2) -> void:
	var m: Mob = mobs.get(u.id, null)
	if m == null:
		return
	m.pos2 += vec
	u.pos = Vector3(m.pos2.x, 0, m.pos2.y)
	_cancel_cast(m, false)

## Кража золота (гоблин-вор): моб убегает к своему логову; убьёте — золото вернётся.
func on_steal(thief: Unit, victim, amount: int) -> void:
	var m: Mob = mobs.get(thief.id, null)
	if m == null or amount <= 0:
		return
	m.stolen += amount
	m.stolen_from = victim.hero_id
	m.fleeing = true
	m.state = S.MOVE
	world.announce_all("%s украл %d золота у %s — догоните его!" % [thief.display_name, amount, victim.player_name], Color(1, 0.8, 0.3))

@rpc("authority", "call_local", "reliable")
func ev_mob_cast(id: int, aid: String, dur: float, can_interrupt: bool) -> void:
	casts[id] = {"ab": aid, "start": world.now(), "dur": dur, "interrupt": can_interrupt}

@rpc("authority", "call_local", "reliable")
func ev_mob_cast_end(id: int, interrupted: bool) -> void:
	casts.erase(id)
	if interrupted:
		var u: Unit = world.get_unit(id)
		if u:
			world.hud.float_text(u, "Прервано!", Color(1.0, 0.85, 0.3))
			Sfx.play_at("hit_metal", u.pos + Vector3(0, 1.5, 0))

@rpc("authority", "call_local", "reliable")
func ev_telegraph(shape: String, pos: Vector3, yaw: float, radius: float, angle: float, dur: float) -> void:
	Vfx.telegraph(world, shape, pos, yaw, radius, angle, dur)

## Убрать моба без награды (вор добежал до логова).
func _despawn(m: Mob) -> void:
	mobs.erase(m.unit.id)
	world.units.erase(m.unit.id)
	m.unit.alive = false
	_pending_deaths.append(m.unit.id)
	_begin_dying(m)

# ---------------------------------------------------------------- элитные мобы
## Аффиксы — scripts/data/affixes.gd. Тип элиты и аффиксы уходят клиентам в ev_spawn (надёжно, один раз),
## в снимок ничего не добавляется.

var hazards: Array = []            # сервер: горящая земля {pos: Vector2, r, until, dps, src}
var _hazard_acc := 0.0
var _delayed: Array = []           # сервер: отложенные взрывы {at, pos: Vector2, r, min, max, src_power}

## Сделать моба элитным (count аффиксов) или чемпионом. Возвращает список аффиксов.
func _make_elite(m: Mob, champion: bool, wave: int) -> void:
	var A = GameData.AffixData
	var pool: Array = A.AFFIXES.keys()
	var count := 3 if champion else clampi(1 + (1 if wave >= 10 else 0) + (1 if wave >= 18 else 0), 1, 3)
	if not champion:
		count = 1 + randi() % count
	var list: Array = []
	if Net.cli.has("affix") and A.AFFIXES.has(Net.cli["affix"]):
		list.append(Net.cli["affix"])
	pool.shuffle()
	for a in pool:
		if list.size() >= count:
			break
		if not list.has(a):
			list.append(a)
	_apply_affixes(m, list, champion)

func _apply_affixes(m: Mob, list: Array, champion: bool) -> void:
	var A = GameData.AffixData
	var u := m.unit
	u.elite = 2 if champion else 1
	u.affixes = list
	u.max_hp *= (A.CHAMPION_HP if champion else A.ELITE_HP)
	u.hp = u.max_hp
	u.power *= A.ELITE_DMG
	u.phys_power = u.power
	for a in list:
		match a:
			"armored":
				u.armor = minf(0.8, u.armor + 0.35)
			"fast":
				u.add_buff("affix_fast", 1e9, {"speed": 0.4, "haste": 0.25})
		var ab: String = A.AFFIXES[a].get("ability", "")
		if ab != "":
			m.extra_abilities.append(ab)
			m.ab_ready[ab] = world.now() + 2.0 + randf() * 2.0

## Огненный след: горящая земля под быстрым элитным, пока он идёт.
func _elite_trail(m: Mob, t: float) -> void:
	if not m.unit.affixes.has("fire_trail") or t < m.trail_at:
		return
	m.trail_at = t + 1.4
	hazards.append({"pos": m.pos2, "r": 2.2, "until": t + 5.0, "dps": 10.0 * m.unit.power, "src": m.unit.id})
	ev_hazard.rpc(Vector3(m.pos2.x, 0, m.pos2.y), 2.2, 5.0)

## Сервер: горящая земля жжёт героев, отложенные взрывы взрываются.
func _tick_hazards(delta: float, t: float) -> void:
	var i := 0
	while i < _delayed.size():
		var d: Dictionary = _delayed[i]
		if t < float(d["at"]):
			i += 1
			continue
		_delayed.remove_at(i)
		var c: Vector2 = d["pos"]
		for h in world.heroes.values():
			var hu: Unit = h.unit
			if hu.alive and Vector2(hu.pos.x, hu.pos.z).distance_to(c) <= float(d["r"]) + hu.radius:
				world.spells.deal_damage(null, hu, randf_range(d["min"], d["max"]) * float(d["power"]), "fire", false, "affix:explosive")
		world.spells.fx_at("explosion_fire", Vector3(c.x, 0, c.y), Vector3(c.x, 0, c.y), float(d["r"]), 0)
	_hazard_acc += delta
	if _hazard_acc < 0.5:
		return
	_hazard_acc = 0.0
	hazards = hazards.filter(func(z): return float(z["until"]) > t)
	for z in hazards:
		var src: Unit = world.get_unit(int(z["src"]))
		for h in world.heroes.values():
			var hu: Unit = h.unit
			if hu.alive and Vector2(hu.pos.x, hu.pos.z).distance_to(z["pos"]) <= float(z["r"]) + hu.radius:
				world.spells.deal_damage(src, hu, float(z["dps"]) * 0.5, "fire", false, "affix:fire_trail")

@rpc("authority", "call_local", "reliable")
func ev_hazard(pos: Vector3, r: float, dur: float) -> void:
	Vfx.hazard_fire(world, pos, r, dur)

## Внешний вид элитного: крупнее, цветная аура под ногами.
func _elite_visual(m: Mob) -> void:
	var old := m.node.get_node_or_null("EliteAura")
	if old:
		old.free()
	var base := float(m.def.get("scale", 1.0))
	if m.unit.elite == 0:
		m.node.scale = Vector3.ONE * base
		return
	m.node.scale = Vector3.ONE * base * (GameData.AffixData.ELITE_SCALE * (1.15 if m.unit.elite == 2 else 1.0))
	var ring := MeshInstance3D.new()
	ring.name = "EliteAura"
	var pm := PlaneMesh.new()
	pm.size = Vector2(2, 2)
	ring.mesh = pm
	var col: Color = GameData.AFFIXES[m.unit.affixes[0]]["color"] if not m.unit.affixes.is_empty() else Color(1, 0.8, 0.3)
	ring.material_override = Vfx.ring_material(col, 0.0, false, 1.0)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var rr := m.unit.radius * 2.2 / maxf(m.node.scale.x, 0.01)
	ring.scale = Vector3(rr, 1, rr)
	ring.position.y = 0.06
	m.node.add_child(ring)

## Враги в радиусе бросают этого героя (Зеркальные копии, сброс угрозы).
func drop_aggro_on(u: Unit, radius: float) -> void:
	for m: Mob in mobs.values():
		if m.target == u.id and m.state == S.CHASE and m.pos2.distance_to(Vector2(u.pos.x, u.pos.z)) <= radius:
			_drop_chase(m, true)
