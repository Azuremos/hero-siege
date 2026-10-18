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
	# боссы (boss_data.gd): состояние фаз только на сервере
	var boss: Dictionary = {}
	var owner := 0                    # кто призвал (босс) — его объекты пропадают вместе с ним
	var bind := 0                     # ледяная гробница: id вмороженного героя
	var until := 0.0                  # объект пропадает сам в это время (0 — нет)
	var gi := -1                      # номер в сетке этого шага (путь C++: индекс в массивах MobSimNative)

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
	_init_native()

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
	if _native != null:
		var oa := PackedVector2Array()
		var ob := PackedVector2Array()
		var orr := PackedFloat32Array()
		for s: Array in _static_obs:
			oa.append(s[0])
			ob.append(s[1])
			orr.append(s[2])
		_native.set_obstacles(oa, ob, orr)

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
	u.side = int(opts.get("side", Unit.SIDE_MOBS))      # мобы враждебны всем; режим может дать сторону (свои войска)
	u.type_id = type
	u.display_name = def["name"]
	var cw: int = world.campaign_wave(wave)      # «Поход»: сила — от сильнейшего героя и уровня угрозы
	u.max_hp = float(def["hp"]) * GameData.mob_hp_mult(cw, players) * hp_scale * world.threat_k(true)
	if Net.cli.has("mobhp"):
		u.max_hp *= float(Net.cli["mobhp"])    # тест: враги живут дольше, бой без пауз
	u.hp = u.max_hp
	u.power = GameData.mob_dmg_mult(cw) * world.threat_k(false)
	u.phys_power = u.power
	u.armor = def["armor"]
	u.radius = def["radius"]
	u.level = wave
	u.def_ranged = def.get("ranged", false)
	m.unit = u
	m.def = def
	m.route = source
	u.route = source
	if opts.has("pet_owner"):
		return _spawn_pet(m, u, type, opts)
	u.sent_by = int(opts.get("sent_by", 0))      # «Линии»: кто отправил (рамка цели, награда, итоги)
	u.bounty = int(opts.get("bounty", 0))
	var want_elite: bool = opts.get("champion", false) or (not def.get("boss", false) and (not opts.has("pos") or Net.cli.has("elite")) and not def["role"] in ["test", "summon"]
		and (Net.cli.has("elite") or randf() < GameData.AffixData.elite_chance(wave)))
	if opts.has("affixes") and not (opts["affixes"] as Array).is_empty():
		_apply_affixes(m, opts["affixes"], opts.get("champion", false))      # аффиксы заданы режимом (одинаковые на всех линиях)
	elif want_elite and not opts.get("no_elite", false):
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
	m.owner = int(opts.get("owner", 0))
	var nxt: Vector2 = ends[1]
	world.mode.mob_spawned(m)
	m.yaw = atan2(-(nxt.x - start.x), -(nxt.y - start.y))
	u.pos = Vector3(m.pos2.x, 0, m.pos2.y)
	mobs[u.id] = m
	world.units[u.id] = u
	_make_visual(m)
	_pending_spawns.append([u.id, type, m.pos2.x, m.pos2.y, m.yaw, u.max_hp, wave, u.affixes, u.elite, 0, u.sent_by, u.side])
	if GameData.BOSSES.has(type):
		_boss_init(m, wave, players, hp_scale, t)
	return u.id

## Питомец: та же запись Mob, но сторона игроков и свой словарь (не враг, не в волне).
func _spawn_pet(m: Mob, u: Unit, type: String, opts: Dictionary) -> int:
	u.kind = "pet"
	u.owner_id = int(opts["pet_owner"])
	var oh = world.heroes.get(u.owner_id, null)
	u.side = oh.unit.side if oh else 0         # сторона хозяина
	u.level = 1
	m.pos2 = opts["pos"]
	m.yaw = 0.0
	m.state = S.CHASE
	var t: float = world.now()
	m.spawn_until = t
	m.next_think = t
	u.pos = Vector3(m.pos2.x, 0, m.pos2.y)
	pets[u.id] = m
	world.units[u.id] = u
	_make_visual(m)
	var owner_hero = world.heroes.get(u.owner_id, null)
	if owner_hero:
		u.hp = 1.0
		u.max_hp = 1.0
		_pet_refresh(m, owner_hero)     # здоровье и сила от хозяина — до рассылки
	_pending_spawns.append([u.id, type, m.pos2.x, m.pos2.y, m.yaw, u.max_hp, 1, [], 0, u.owner_id, 0, u.side])
	return u.id

func kill(u: Unit, killer: Unit) -> void:
	var m: Mob = mobs.get(u.id, null)
	if m == null:
		return
	mobs.erase(u.id)
	world.units.erase(u.id)
	var reward := GameData.AffixData.ELITE_REWARD if u.elite > 0 else 1.0
	var xp := int(float(m.def["xp"]) * (1.0 + 0.1 * float(u.level - 1)) * reward)
	var kr: Array = world.mode.kill_reward(u, xp, int(float(m.def["gold"]) * reward))
	world.award_kill(u.pos, kr[0], kr[1], u)
	if killer:
		var kh: int = killer.owner_id if killer.kind == "pet" else (killer.id if killer.kind == "hero" else 0)
		if kh != 0:
			world.kills[kh] = int(world.kills.get(kh, 0)) + 1      # итоги партии
	if not m.boss.is_empty():
		_boss_died(m)
	elif m.def.get("object", false):
		pass        # объекты (филактерии, порталы, гробницы) добычи не дают
	else:
		world.economy.roll_loot(u.pos, u.level, "champion" if u.elite == 2 else ("elite" if u.elite == 1 else "mob"), world.mode.loot_gear_k(u))
	if m.bind != 0:
		_release_tomb(m)
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
	if m == null or src == null or not (src.kind == "hero" or src.kind == "pet"):
		return
	if world.now() < src.unseen_until:
		return          # «незаметного» (Зеркальные копии) враги не замечают, даже если он бьёт
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
		var tp0 := Time.get_ticks_usec()
		_rebuild_grid()
		var tp1 := Time.get_ticks_usec()
		for m: Mob in mobs.values():
			_sim(m, SIM_STEP, t)
		_apply_moves(SIM_STEP, t)
		prof["grid"] = int(prof.get("grid", 0)) + tp1 - tp0
		prof["sim"] = int(prof.get("sim", 0)) + Time.get_ticks_usec() - tp1
		prof["steps"] = int(prof.get("steps", 0)) + 1
		for p: Mob in pets.values():
			_pet_sim(p, SIM_STEP, t)
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
	if _native != null:
		# путь C++: позиции и радиусы всех мобов — в MobSimNative, сетки строит он
		_grid_list = mobs.values()
		var pos := PackedVector2Array()
		var rad := PackedFloat32Array()
		var alive := PackedByteArray()
		pos.resize(_grid_list.size())
		rad.resize(_grid_list.size())
		alive.resize(_grid_list.size())
		for i in _grid_list.size():
			var gm: Mob = _grid_list[i]
			gm.gi = i
			pos[i] = gm.pos2
			rad[i] = gm.unit.radius
			alive[i] = 1 if gm.unit.alive else 0
		_native.set_mobs(pos, rad, alive)
		return
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
	if _native != null:
		for i in _native.query_radius(p, r):
			out.append(_grid_list[i].unit)
		return out
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
	if not m.boss.is_empty():
		_boss_tick(m, t)
	if m.def.get("object", false):
		_object_tick(m, t)
		return
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
		# движение — пачкой после решений всех мобов (_apply_moves): одинаково на путях GDScript и C++
		_queue_move(m, goal, float(m.def["speed"]) * u.speed_mult(t))
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
		if not hu.alive or world.now() < hu.unseen_until or not m.unit.is_enemy_of(hu):
			continue
		# таланты «агро» (Вызов Света): такого героя враги выбирают охотнее
		var d := Vector2(hu.pos.x, hu.pos.z).distance_to(m.pos2) / (1.0 + hu.flag("threat"))
		if d < best_d:
			best_d = d
			best = hu
	# питомцы охотников — такие же цели (медведь с угрозой threat — охотнее)
	for p: Mob in pets.values():
		var pu: Unit = p.unit
		var pd := p.pos2.distance_to(m.pos2) / (1.0 + float(p.def.get("threat", 0.0)))
		if pu.alive and pd < best_d and m.unit.is_enemy_of(pu):
			best_d = pd
			best = pu
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

## Пачка движений шага: все мобы решили, куда идти, — теперь движутся одновременно (позиции соседей —
## на начало шага). Путь C++ — MobSimNative.move_batch, путь GDScript — _move_calc; результат одинаковый.
var _mv_mobs: Array = []
var _mv_goals := PackedVector2Array()
var _mv_speeds := PackedFloat32Array()
var _mv_wall := PackedByteArray()
var _grid_list: Array = []

func _queue_move(m: Mob, goal: Vector2, speed: float) -> void:
	_mv_mobs.append(m)
	_mv_goals.append(goal)
	_mv_speeds.append(speed)
	_mv_wall.append(1 if (m.state == S.MOVE or (m.state == S.CHASE and not m.def.get("ranged", false))) else 0)

func _apply_moves(dt: float, t: float) -> void:
	var n := _mv_mobs.size()
	if n == 0:
		return
	var tm := Time.get_ticks_usec()
	var res_pos := PackedVector2Array()
	var res_yaw := PackedFloat32Array()
	var res_wall := PackedInt32Array()
	if _native != null:
		var idx := PackedInt32Array()
		idx.resize(n)
		for k in n:
			idx[k] = _mv_mobs[k].gi
		var wa := PackedVector2Array()
		var wb := PackedVector2Array()
		var wid := PackedInt32Array()
		for id in walls:
			wa.append(walls[id]["a"])
			wb.append(walls[id]["b"])
			wid.append(id)
		var r: Array = _native.move_batch(idx, _mv_goals, _mv_speeds, _mv_wall, dt, wa, wb, wid)
		res_pos = r[0]
		res_yaw = r[1]
		res_wall = r[2]
	else:
		res_pos.resize(n)
		res_yaw.resize(n)
		res_wall.resize(n)
		for k in n:
			var out: Array = _move_calc(_mv_mobs[k], _mv_goals[k], _mv_speeds[k], _mv_wall[k] == 1, dt)
			res_pos[k] = out[0]
			res_yaw[k] = out[1]
			res_wall[k] = out[2]
	for k in n:
		var m: Mob = _mv_mobs[k]
		m.pos2 = res_pos[k]
		if not is_nan(res_yaw[k]):
			m.yaw = res_yaw[k]
		if res_wall[k] != 0 and walls.has(res_wall[k]):
			m.state = S.WALL
			m.wall = res_wall[k]
		m.unit.pos = Vector3(m.pos2.x, 0, m.pos2.y)
		_elite_trail(m, t)
	_mv_mobs.clear()
	_mv_goals.clear()
	_mv_speeds.clear()
	_mv_wall.clear()
	prof["move"] = int(prof.get("move", 0)) + Time.get_ticks_usec() - tm

## Путь GDScript: куда сдвинется моб (позиции соседей не меняются до конца пачки).
## Возвращает [новая позиция, yaw (NAN — не менялся), id стены, в которую упёрся (0 — нет)]. То же, что MobSimNative.move_batch.
func _move_calc(m: Mob, goal: Vector2, speed: float, can_wall: bool, dt: float) -> Array:
	var u := m.unit
	var to := goal - m.pos2
	if to.length() < 0.05:
		return [m.pos2, NAN, 0]
	var dir := to.normalized()
	var v := dir * speed
	var kx := floori(m.pos2.x / SEP_CELL)
	var ky := floori(m.pos2.y / SEP_CELL)
	var pushes := 0
	for cx in range(kx - 1, kx + 2):
		for cy in range(ky - 1, ky + 2):
			for nb: Mob in _sep_grid.get(_sep_key(cx, cy), []):
				if nb == m:
					continue
				var diff := m.pos2 - nb.pos2
				var min_d := u.radius + nb.unit.radius
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
	var hit := 0
	for id in walls:
		var w: Dictionary = walls[id]
		var cp := Geometry2D.get_closest_point_to_segment(np, w["a"], w["b"])
		if cp.distance_to(np) < u.radius + 0.9:
			var was := Geometry2D.get_closest_point_to_segment(m.pos2, w["a"], w["b"])
			if cp.distance_to(np) < was.distance_to(m.pos2) + 0.01:
				np = m.pos2
				if can_wall:
					hit = id
				break
	var okey := Vector2i(floori(np.x / CELL), floori(np.y / CELL))
	for oi in _obs_grid.get(okey, []):
		var ob: Array = _static_obs[oi]
		var ocp := Geometry2D.get_closest_point_to_segment(np, ob[0], ob[1])
		var odiff := np - ocp
		var omin: float = ob[2] + u.radius
		var od := odiff.length()
		if od < omin:
			if od < 0.001:
				odiff = -dir
				od = 1.0
			np = ocp + odiff / od * omin
	return [np, atan2(-v.x, -v.y) if v.length_squared() > 0.01 else NAN, hit]

## Немедленное движение (питомцы, убегающий вор) — их мало, считаются по одному в GDScript.
## На пути C++ мелкой сетки в GDScript нет — расталкивание для них не считается.
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
				if hu != tu and hu.alive and m.unit.is_enemy_of(hu) and Vector2(hu.pos.x, hu.pos.z).distance_to(Vector2(tu.pos.x, tu.pos.z)) < float(m.def["cleave"]):
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
	var all: Array = mobs.values() + pets.values()      # питомцы — в том же снимке
	if _native != null:
		var n := all.size()
		var ids := PackedInt32Array()
		var pos := PackedVector2Array()
		var yaws := PackedFloat32Array()
		var st := PackedByteArray()
		var hp := PackedFloat32Array()
		ids.resize(n)
		pos.resize(n)
		yaws.resize(n)
		st.resize(n)
		hp.resize(n)
		for i in n:
			var sm: Mob = all[i]
			ids[i] = sm.unit.id
			pos[i] = sm.pos2
			yaws[i] = sm.yaw
			st[i] = (sm.anim_state & 7) | ((sm.swing & 31) << 3)
			hp[i] = sm.unit.hp_frac()
		return _native.encode_snapshot(ids, pos, yaws, st, hp)
	buf.resize(2 + all.size() * 11)
	buf.encode_u16(0, all.size())
	var o := 2
	for m: Mob in all:
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
		var m: Mob = mobs.get(id, pets.get(id, null))
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
		if mobs.has(int(e[0])) or pets.has(int(e[0])):
			continue      # уже есть (полный снимок мира после обычной рассылки)
		var def: Dictionary = GameData.MOBS[e[1]]
		var m := Mob.new()
		var u := Unit.new()
		u.id = e[0]
		u.kind = "mob"
		u.side = int(e[11]) if e.size() > 11 else Unit.SIDE_MOBS
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
		if e.size() > 10:
			u.sent_by = int(e[10])
		m.unit = u
		m.def = def
		m.pos2 = Vector2(e[2], e[3])
		m.yaw = e[4]
		m.anim_state = AN.SPAWN
		u.pos = Vector3(m.pos2.x, 0, m.pos2.y)
		if e.size() > 9 and int(e[9]) != 0:
			# питомец охотника: союзник, в своём словаре
			u.kind = "pet"
			u.owner_id = int(e[9])
			pets[u.id] = m
		else:
			mobs[u.id] = m
		world.units[u.id] = u
		_make_visual(m)

@rpc("authority", "reliable")
func ev_death(ids: PackedInt32Array) -> void:
	for id in ids:
		var m: Mob = mobs.get(id, pets.get(id, null))
		if m == null:
			continue
		mobs.erase(id)
		pets.erase(id)
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
	_boss_visual(m)
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

var prof: Dictionary = {}   # --stress: время частей шага симуляции (мкс)
var vis_usec := 0          # --stress: время визуала мобов за кадр (анимации, сглаживание)

func _process(delta: float) -> void:
	var t_vis := Time.get_ticks_usec()
	_process_visual(delta)
	vis_usec += Time.get_ticks_usec() - t_vis

## Камеры, кадр которых тоже считается «видно» (окно «Обзор линий», когда развёрнуто).
var extra_cams: Array = []

func _seen(cam: Camera3D, p: Vector3) -> bool:
	if cam.is_position_in_frustum(p):
		return true
	for c: Camera3D in extra_cams:
		if is_instance_valid(c) and c.is_position_in_frustum(p):
			return true
	return false

func _process_visual(delta: float) -> void:
	_frame += 1
	var cam := get_viewport().get_camera_3d()
	var cam_pos := cam.global_position if cam else Vector3.ZERO
	var k := 1.0 - exp(-12.0 * delta)
	for m: Mob in mobs.values() + pets.values():
		m.vis_target = Vector3(m.pos2.x, 0, m.pos2.y)
		m.node.position = m.node.position.lerp(m.vis_target, k)
		m.node.rotation.y = lerp_angle(m.node.rotation.y, m.yaw, k)
		if not Net.is_server():
			m.unit.pos = m.node.position
		# вне кадра камеры анимацию не считаем (сессия 08: при 200+ мобах это заметная доля кадра);
		# время копится, но не больше полсекунды — вернувшись в кадр, моб продолжит без рывка
		if cam and not _seen(cam, m.vis_target + Vector3(0, 1.0, 0)):
			m.anim_acc = minf(m.anim_acc + delta, 0.5)
			continue
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
	var is_boss := not m.boss.is_empty()
	if is_boss and (m.state != S.CHASE or t < float(m.boss["busy_until"])):
		return      # босс колдует только в бою и не во время перехода фазы
	for aid in _abilities_of(m) + m.extra_abilities:
		if not _ability_ready(m, aid, t):
			continue
		var ab: Dictionary = GameData.MOB_ABILITIES[aid]
		if t < float(m.locked.get(ab.get("school", ""), 0.0)) or t < m.unit.silence_until:
			continue
		if world.mode.mob_players() < int(ab.get("min_players", 1)):
			continue    # механики «на группу» — только при 2+ героях
		if ab.get("hard", false) and is_boss and t < float(m.boss["hard_ready"]):
			continue
		var cond: Dictionary = ab.get("cond", {})
		if cond.get("once", false) and m.used.has(aid):
			continue
		if cond.has("hp_below") and m.unit.hp_frac() >= float(cond["hp_below"]):
			continue
		if cond.has("enemy_near") and not _hero_within(m, float(cond["enemy_near"])):
			continue
		var pick := _pick_target(m, ab)
		if pick.is_empty():
			continue
		m.used[aid] = true
		m.ab_ready[aid] = t + float(ab["cd"])
		if ab.get("hard", false) and is_boss:
			m.boss["hard_ready"] = t + GameData.BossData.HARD_GAP
		_begin_cast(m, aid, ab, pick, t)
		return

## Способности моба: у босса — способности текущей фазы (или текущего набора чередования).
func _abilities_of(m: Mob) -> Array:
	if m.boss.is_empty():
		return m.def.get("abilities", [])
	var ph: Dictionary = _phase(m)
	if ph.has("rotate"):
		var sets: Array = ph["rotate"]["sets"]
		return sets[int(m.boss["rot"]) % sets.size()]
	return ph.get("abilities", [])

func _hero_within(m: Mob, r: float) -> bool:
	for h in world.heroes.values():
		if h.unit.alive and m.unit.is_enemy_of(h.unit) and Vector2(h.unit.pos.x, h.unit.pos.z).distance_to(m.pos2) <= r + h.unit.radius:
			return true
	return false

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
					if hu.alive and world.now() >= hu.unseen_until and _d(m, hu) <= bd and m.unit.is_enemy_of(hu):
						bd = _d(m, hu)
						best = hu
			if best == null:
				return {}
			if ab.get("cond", {}).has("min_dist") and _d(m, best) < float(ab["cond"]["min_dist"]):
				return {}
			return {"unit": best.id, "point": Vector2(best.pos.x, best.pos.z)}
		"enemy_random":
			var pool: Array = []
			for h in world.heroes.values():
				if h.unit.alive and world.now() >= h.unit.unseen_until and _d(m, h.unit) <= rng and m.unit.is_enemy_of(h.unit):
					pool.append(h.unit)
			if pool.is_empty():
				return {}
			var ru: Unit = pool[randi() % pool.size()]
			return {"unit": ru.id, "point": Vector2(ru.pos.x, ru.pos.z)}
		"ally_hurt", "ally":
			var best_m: Unit = null
			var bf := 0.7 if ab["target"] == "ally_hurt" else 2.0
			for o: Unit in query_radius(m.pos2, rng):
				var om: Mob = mobs.get(o.id, null)
				if om == null or not m.unit.is_ally_of(o) or (ab["target"] == "ally" and om.state != S.CHASE and om.state != S.OBJECTIVE):
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
				if h.unit.alive and _d(m, h.unit) <= rng and m.unit.is_enemy_of(h.unit):
					return {"unit": h.unit.id, "point": m.pos2}
			return {}
	return {}

func _d(m: Mob, u: Unit) -> float:
	return m.pos2.distance_to(Vector2(u.pos.x, u.pos.z)) - u.radius

func _begin_cast(m: Mob, aid: String, ab: Dictionary, pick: Dictionary, t: float) -> void:
	if Net.cli.has("castlog"):
		print("MOBCAST ", m.unit.type_id, " ", aid)
	var dur := float(ab.get("cast", 0.0))
	# в поздних фазах телеграфы короче (сбиваемые касты не трогаем — их должно успеть сбить)
	if not m.boss.is_empty() and not ab.get("interrupt", false):
		dur *= float(_phase(m).get("tele", 1.0))
	m.cast = {"ab": aid, "until": t + dur, "pick": pick}
	_face(m, pick["point"])
	if ab.has("telegraph"):
		var tg: Dictionary = ab["telegraph"]
		var shape: String = tg["shape"]
		var center: Vector2 = pick["point"] if shape == "circle" else m.pos2
		if ab["delivery"] == "self_explode" or ab["delivery"] == "shockwave":
			center = m.pos2
		m.cast["center"] = center
		# у кольца angle — внутренний радиус, у линии — ширина (тот же ev_telegraph)
		var extra := float(tg.get("angle", tg.get("inner", tg.get("width", 0.0))))
		match ab["delivery"]:
			"lines":
				var yaws: Array = []
				var n := int(ab.get("count", 1))
				for i in n:
					yaws.append(m.yaw + deg_to_rad(float(ab.get("spread", 0.0)) * (float(i) - float(n - 1) * 0.5)))
				m.cast["yaws"] = yaws
				for y in yaws:
					ev_telegraph.rpc(shape, Vector3(center.x, 0, center.y), y, float(tg["radius"]), extra, maxf(dur, 0.3))
			"barrage":
				var pts := _barrage_points(m, ab)
				m.cast["points"] = pts
				for p: Vector2 in pts:
					ev_telegraph.rpc(shape, Vector3(p.x, 0, p.y), 0.0, float(tg["radius"]), extra, maxf(dur, 0.3))
			"charge":
				m.cast["yaw"] = m.yaw
				ev_telegraph.rpc(shape, Vector3(center.x, 0, center.y), m.yaw, float(tg["radius"]), extra, maxf(dur, 0.3))
			_:
				ev_telegraph.rpc(shape, Vector3(center.x, 0, center.y), m.yaw, float(tg["radius"]), extra, maxf(dur, 0.3))
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
	var cast_data: Dictionary = m.cast
	m.cast = {}
	if float(ab.get("cast", 0.0)) > 0.0:
		ev_mob_cast_end.rpc(m.unit.id, false)
	m.swing = (m.swing + 1) % 32
	m.anim_state = AN.ATTACK
	var sid := "mab:" + aid
	var school: String = ab.get("school", "physical")
	var fx: Array = _solo_fx(ab, ab.get("effects", []))
	var tu: Unit = world.get_unit(int(pick.get("unit", 0)))
	var nova := _nova_kind(school)
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
					if hu.alive and not hit.has(hu) and hu.pos.distance_to(cur.pos) <= nd and m.unit.is_enemy_of(hu):
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
			var tg: Dictionary = ab.get("telegraph", {})
			var r: float = float(tg.get("radius", ab.get("radius", 3.0)))
			var inner := float(tg.get("inner", 0.0))
			for h in world.heroes.values():
				var hu: Unit = h.unit
				if not hu.alive or not m.unit.is_enemy_of(hu):
					continue
				var hp2 := Vector2(hu.pos.x, hu.pos.z)
				var dc := hp2.distance_to(center)
				if dc > r + hu.radius or (inner > 0.0 and dc < inner - hu.radius):
					continue
				if ab["delivery"] == "cone":
					var to := hp2 - m.pos2
					var fwd := Vector2(-sin(m.yaw), -cos(m.yaw))
					if to.length() > 0.5 and rad_to_deg(absf(fwd.angle_to(to.normalized()))) > float(tg.get("angle", 90.0)) * 0.5:
						continue
				world.spells.apply_effects(m.unit, hu, fx, sid, school)
			world.spells.fx_at(nova, Vector3(center.x, 0, center.y), m.unit.pos, r, 0)
			if ab.has("hazard"):
				_add_hazard(center, ab["hazard"], m.unit, t)
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
				if m.unit.is_ally_of(o):
					world.spells.apply_effects(m.unit, o, fx, sid, school)
			if not ab.get("silent", false):
				world.spells.fx_at("aura_war", m.unit.pos, m.unit.pos, 0.0, m.unit.id)
		"summon":
			var kind: String = ab.get("summon", "")
			if kind == "":
				kind = _swarm_of(m.def.get("faction", "undead"))
			var cnt := int(ab.get("count", 2))
			if _solo() and ab.has("solo"):
				cnt = int(ab["solo"].get("count", cnt))
			if ab.has("max_alive"):
				cnt = mini(cnt, int(ab["max_alive"]) - _owned_count(m, kind))
			var ring := float(ab.get("ring", 0.0))
			var base_a := randf() * TAU
			for i in cnt:
				var p: Vector2 = pick["point"] + Vector2(randf_range(-1.5, 1.5), randf_range(-1.5, 1.5))
				if ring > 0.0:
					var a := base_a + TAU * float(i) / float(cnt)
					p = m.pos2 + Vector2(cos(a), sin(a)) * ring
				var hp_k := 1.0 if GameData.MOBS[kind].get("object", false) else 0.7
				var sid2: int = spawn(kind, m.route, m.unit.level, world.mode.mob_players(), hp_k, {"pos": p, "owner": m.unit.id, "sent_by": m.unit.sent_by})
				var sm: Mob = mobs.get(sid2, null)
				if sm:
					sm.wp = m.wp
			_take_corpse(pick)
		"devour":
			world.spells.heal(m.unit, m.unit, m.unit.max_hp * float(ab.get("heal_pct", 0.3)), false, sid)
			world.spells.fx_at("hit_blood", m.unit.pos, m.unit.pos, 0.0, m.unit.id)
			_take_corpse(pick)
		_:
			_finish_boss_cast(m, ab, sid, school, fx, pick, center, cast_data, t)

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
	if m == null or m.def.get("object", false):
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
	teles.append([shape, Vector2(pos.x, pos.z), yaw, radius, angle, world.now() + dur])

## Убрать моба без награды (вор добежал до логова).
func _despawn(m: Mob) -> void:
	if m.bind != 0:
		_release_tomb(m)
	casts.erase(m.unit.id)
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
		if d.has("fx") or d.has("transform"):
			_explode_boss(d, t)
			continue
		var c: Vector2 = d["pos"]
		for h in world.heroes.values():
			var hu: Unit = h.unit
			if hu.alive and Vector2(hu.pos.x, hu.pos.z).distance_to(c) <= float(d["r"]) + hu.radius:
				world.spells.deal_damage(null, hu, randf_range(d["min"], d["max"]) * float(d["power"]), "fire", false, "affix:explosive")
		world.spells.fx_at("explosion_fire", Vector3(c.x, 0, c.y), Vector3(c.x, 0, c.y), float(d["r"]), 0)
	_tick_waves(t)
	_tick_mines(t)
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
		if m.target == u.id and m.state == S.CHASE and m.pos2.distance_to(Vector2(u.pos.x, u.pos.z)) <= radius and world.now() >= m.taunt_until:
			_drop_chase(m, true)

# ---------------------------------------------------------------- боссы
## Фазы, способности фаз и действия при входе в фазу — scripts/data/boss_data.gd. Здесь — общий движок:
## порог здоровья → новая фаза (реплика, неуязвимость на переход, призыв, бафф, смена арены);
## «неуязвим, пока стоят его объекты»; чередование наборов способностей; пульс и аура; ярость;
## превращение вместо смерти (механоогр → король огров). Всё считает сервер; клиентам — ev_boss_state.

const BOSS_COLOR := Color(1.0, 0.45, 0.25)
var boss_state: Dictionary = {}    # у всех: id босса -> {phase, shield, aura, rot}
var teles: Array = []              # у всех: телеграфы на земле [shape, центр, yaw, radius, extra, до] — для бота
var shockwaves: Array = []         # у всех: волны землетрясения [центр, начало, скорость, ширина, предел]
var mine_spots: Dictionary = {}    # у всех: id мины -> [Vector2, узел]
var mines: Dictionary = {}         # сервер: id -> {pos, trig, blast, until, armed, fuse, fx, school, src}
var _waves: Array = []             # сервер: расходящиеся волны
var _next_mine := 1
var _transform_pending := 0

func _phase(m: Mob) -> Dictionary:
	var phases: Array = GameData.BOSSES[m.unit.type_id]["phases"]
	return phases[clampi(int(m.boss.get("phase", 0)), 0, phases.size() - 1)]

## Идёт превращение босса (взрыв машины, вот-вот выйдет король огров).
func boss_pending() -> bool:
	return _transform_pending > 0

func _solo() -> bool:
	return world.mode.mob_players() <= 1

## В одиночке наказание за несбитый каст мягче: урон и лечение способности × solo.mult.
func _solo_fx(ab: Dictionary, fx: Array) -> Array:
	if not _solo() or not ab.get("solo", {}).has("mult"):
		return fx
	var k := float(ab["solo"]["mult"])
	var out: Array = []
	for e in fx:
		var c: Dictionary = e.duplicate()
		if c.has("min"):
			c["min"] = float(c["min"]) * k
			c["max"] = float(c["max"]) * k
		if c.has("pct"):
			c["pct"] = float(c["pct"]) * k
		out.append(c)
	return out

static func _nova_kind(school: String) -> String:
	match school:
		"fire": return "explosion_fire"
		"frost": return "nova_frost"
		"shadow", "arcane": return "nova_arcane"
		"holy": return "nova_holy"
	return "nova_phys"

func _owned_count(m: Mob, kind: String) -> int:
	var n := 0
	for o: Mob in mobs.values():
		if o.owner == m.unit.id and o.unit.type_id == kind:
			n += 1
	return n

## Сообщение одному игроку (метка, гробница).
func _tell(hero_unit: Unit, text: String) -> void:
	var h = world.heroes.get(hero_unit.id, null)
	if h == null or Net.is_bot_peer(h.peer_id):
		return
	if h.peer_id == multiplayer.get_unique_id():
		world.ev_announce(text, Color(1.0, 0.4, 0.3))
	else:
		world.ev_announce.rpc_id(h.peer_id, text, Color(1.0, 0.4, 0.3))

func _boss_init(m: Mob, wave: int, players: int, hp_scale: float, t: float) -> void:
	var bd: Dictionary = GameData.BOSSES[m.unit.type_id]
	m.boss = {"phase": -1, "busy_until": 0.0, "hard_ready": 0.0, "rot": 0, "rot_at": 0.0, "pulse_at": 0.0, "aura_at": 0.0,
		"start": t, "enraged": false, "shield": false, "wave": wave, "players": players, "hp_scale": hp_scale}
	if str(bd.get("intro", "")) != "":
		world.announce_all(bd["intro"], BOSS_COLOR)
	_boss_enter(m, 0, t)

func _boss_enter(m: Mob, idx: int, t: float) -> void:
	var st: Dictionary = m.boss
	st["phase"] = idx
	var ph: Dictionary = _phase(m)
	var u := m.unit
	if ph.has("say"):
		world.announce_all(ph["say"], BOSS_COLOR)
	if idx > 0:
		world.ev_sound_at.rpc("boss_roar", u.pos + Vector3(0, 2, 0), 6.0, 0.8)
	if Net.cli.has("castlog") or Net.cli.has("bossarena"):
		print("BOSS PHASE ", u.type_id, " ", idx, " hp=", snappedf(u.hp_frac(), 0.01))
	var inv := float(ph.get("invuln", 0.0))
	if inv > 0.0:
		u.immune_until = maxf(u.immune_until, t + inv)
		st["busy_until"] = t + inv
		_cancel_cast(m, false)
		world.spells.fx_at("bubble", u.pos, u.pos, inv, u.id)
	for s in ph.get("summon", []):
		var cnt := int(s["count"])
		var a0 := randf() * TAU
		for i in cnt:
			var a := a0 + TAU * float(i) / float(cnt)
			var p: Vector2 = m.pos2 + Vector2(cos(a), sin(a)) * float(s.get("ring", 4.0))
			var hp_k := 1.0 if GameData.MOBS[s["type"]].get("object", false) else 0.8
			spawn(s["type"], m.route, u.level, world.mode.mob_players(), hp_k, {"pos": p, "owner": u.id, "sent_by": u.sent_by})
	if ph.has("buff"):
		u.add_buff(ph["buff"]["key"], t + 1e6, ph["buff"].get("mods", {}))
	if ph.has("hazard_ring"):
		# смена арены: кольцо горящей земли вокруг места боя
		var hr: Dictionary = ph["hazard_ring"]
		for i in int(hr["count"]):
			var a := TAU * float(i) / float(hr["count"])
			_add_hazard(m.pos2 + Vector2(cos(a), sin(a)) * float(hr["r"]), {"r": float(hr["size"]), "dur": 900.0, "dps": 16.0}, u, t)
	# новые способности фазы — не все разом: небольшая пауза
	var all: Array = ph.get("abilities", []).duplicate()
	if ph.has("rotate"):
		for set_list in ph["rotate"]["sets"]:
			all.append_array(set_list)
		st["rot"] = 0
		st["rot_at"] = t + float(ph["rotate"]["period"])
	for aid in all:
		m.ab_ready[aid] = maxf(float(m.ab_ready.get(aid, 0.0)), t + inv + 1.5 + randf() * 2.5)
	if ph.has("pulse"):
		st["pulse_at"] = t + float(ph["pulse"]["every"])
	_send_boss_state(m)

func _send_boss_state(m: Mob) -> void:
	var ph: Dictionary = _phase(m)
	ev_boss_state.rpc(m.unit.id, int(m.boss["phase"]), bool(m.boss["shield"]), float(ph.get("aura", {}).get("r", 0.0)), int(m.boss["rot"]))

func _boss_tick(m: Mob, t: float) -> void:
	var st: Dictionary = m.boss
	var u := m.unit
	var phases: Array = GameData.BOSSES[u.type_id]["phases"]
	var nxt := int(st["phase"]) + 1
	if nxt < phases.size() and u.hp_frac() <= float(phases[nxt]["hp"]):
		_boss_enter(m, nxt, t)
	var ph: Dictionary = _phase(m)
	if ph.has("invuln_while"):
		var sh := _owned_count(m, ph["invuln_while"]) > 0
		if sh:
			u.immune_until = maxf(u.immune_until, t + 0.3)
		if sh != bool(st["shield"]):
			st["shield"] = sh
			_send_boss_state(m)
			if not sh:
				world.announce_all("%s снова уязвим!" % u.display_name, Color(0.6, 1.0, 0.6))
	if ph.has("rotate") and t >= float(st["rot_at"]):
		var rt: Dictionary = ph["rotate"]
		st["rot"] = int(st["rot"]) + 1
		st["rot_at"] = t + float(rt["period"])
		var says: Array = rt.get("say", [])
		if not says.is_empty():
			world.announce_all(says[int(st["rot"]) % says.size()], BOSS_COLOR)
		_send_boss_state(m)
	if ph.has("pulse") and t >= float(st["pulse_at"]):
		var pl: Dictionary = ph["pulse"]
		st["pulse_at"] = t + float(pl["every"])
		for h in world.heroes.values():
			if h.unit.alive and Vector2(h.unit.pos.x, h.unit.pos.z).distance_to(m.pos2) <= float(pl["radius"]):
				world.spells.apply_effects(u, h.unit, pl["effects"], "mab:pulse", pl.get("school", "shadow"))
		world.spells.fx_at("nova_arcane", u.pos, u.pos, 12.0, 0)
	if ph.has("aura") and t >= float(st["aura_at"]):
		st["aura_at"] = t + 0.5
		var ar := float(ph["aura"]["r"])
		for h in world.heroes.values():
			var hu: Unit = h.unit
			if hu.alive and Vector2(hu.pos.x, hu.pos.z).distance_to(m.pos2) <= ar + hu.radius:
				world.spells.deal_damage(u, hu, float(ph["aura"]["dps"]) * 0.5 * u.power, "fire", false, "mab:aura")
	var bd: Dictionary = GameData.BOSSES[u.type_id]
	if not bool(st["enraged"]) and bd.has("enrage") and world.mode.mob_players() >= 2 and t - float(st["start"]) > float(bd["enrage"]):
		st["enraged"] = true
		u.add_buff("boss_enrage", t + 1e6, {"dmg": 1.5, "haste": 0.5})
		world.announce_all("%s впадает в ярость!" % u.display_name, Color(1, 0.2, 0.1))

## Объект (филактерия, портал, гробница): стоит на месте, только способности; гробница держит героя.
func _object_tick(m: Mob, t: float) -> void:
	m.anim_state = AN.IDLE
	if m.until > 0.0 and t >= m.until:
		_despawn(m)
		return
	if m.bind != 0:
		var hu: Unit = world.get_unit(m.bind)
		if hu == null or not hu.alive:
			_despawn(m)
			return
		if t >= m.trail_at:
			m.trail_at = t + 1.0
			world.spells.deal_damage(world.get_unit(m.owner), hu, hu.max_hp * 0.02, "frost", false, "mab:lich_tomb")
	if t >= m.next_think:
		m.next_think = t + 0.5
		_try_abilities(m, t)
	if not m.cast.is_empty() and t >= float(m.cast["until"]):
		_finish_cast(m, t)

func _release_tomb(m: Mob) -> void:
	var h = world.heroes.get(m.bind, null)
	m.bind = 0
	if h:
		h.unit.remove_buff("ice_tomb")
		h.ev_control.rpc("root", 0.0, Vector3.ZERO)

func _boss_died(m: Mob) -> void:
	var u := m.unit
	var t: float = world.now()
	var bd: Dictionary = GameData.BOSSES[u.type_id]
	var gone: Array = []
	for o: Mob in mobs.values():
		if o.owner == u.id and o.def.get("object", false):
			gone.append(o)
	for o in gone:
		_despawn(o)
	var od: Dictionary = bd.get("on_death", {})
	if od.has("transform"):
		var delay := float(od.get("delay", 2.5))
		var r := float(od.get("radius", 6.0))
		ev_telegraph.rpc("circle", u.pos, 0.0, r, 0.0, delay)
		world.announce_all("%s взрывается! Отойдите!" % u.display_name, BOSS_COLOR)
		_transform_pending += 1
		_delayed.append({"at": t + delay, "pos": m.pos2, "r": r, "fx": [{"type": "damage", "min": 40.0, "max": 50.0}], "school": "fire",
			"power": u.power, "transform": od["transform"], "say": od.get("say", ""), "route": m.route,
			"wave": m.boss["wave"], "players": m.boss["players"], "hp_scale": m.boss["hp_scale"], "sent_by": u.sent_by, "bounty": u.bounty})
		return
	if world.mode.loot_gear_k(u) > 0.0:
		world.economy.roll_boss_loot(u.pos, u.level, bd.get("loot", []), bd.get("rank", "lieutenant"))
	else:
		world.economy.roll_loot(u.pos, u.level, "boss", 0.0)      # отправленный босс — без вещей, только зелья
	world.announce_all("%s повержен!" % u.display_name, Color(1, 0.85, 0.3))

## Отложенный удар босса: метка (следует за героем), мина, взрыв машины (и превращение).
func _explode_boss(d: Dictionary, _t: float) -> void:
	var c: Vector2 = d["pos"]
	var carrier: Unit = null
	if d.has("follow"):
		carrier = world.get_unit(int(d["follow"]))
		if carrier == null or not carrier.alive:
			return
		carrier.remove_buff("fel_mark")
		c = Vector2(carrier.pos.x, carrier.pos.z)
	var src: Unit = world.get_unit(int(d.get("src", 0)))
	var school: String = d.get("school", "fire")
	var sid: String = d.get("sid", "mab:delayed")
	for h in world.heroes.values():
		var hu: Unit = h.unit
		if not hu.alive or Vector2(hu.pos.x, hu.pos.z).distance_to(c) > float(d["r"]) + hu.radius:
			continue
		var k := 0.3 if hu == carrier else 1.0      # сам носитель метки получает меньше
		for e in d["fx"]:
			if e["type"] == "damage":
				world.spells.deal_damage(src, hu, randf_range(e["min"], e["max"]) * float(d.get("power", 1.0)) * k, school, false, sid)
			elif src and k >= 1.0:
				world.spells.apply_effects(src, hu, [e], sid, school)
	world.spells.fx_at(_nova_kind(school), Vector3(c.x, 0, c.y), Vector3(c.x, 0, c.y), float(d["r"]), 0)
	if d.has("transform"):
		_transform_pending -= 1
		spawn(d["transform"], int(d["route"]), int(d["wave"]), int(d["players"]), float(d["hp_scale"]), {"pos": c, "sent_by": int(d.get("sent_by", 0)), "bounty": int(d.get("bounty", 0))})
		if str(d.get("say", "")) != "":
			world.announce_all(d["say"], BOSS_COLOR)

func _add_hazard(center: Vector2, hz: Dictionary, src: Unit, t: float) -> void:
	hazards.append({"pos": center, "r": float(hz["r"]), "until": t + float(hz["dur"]), "dps": float(hz["dps"]) * src.power, "src": src.id})
	ev_hazard.rpc(Vector3(center.x, 0, center.y), float(hz["r"]), float(hz["dur"]))

## Точки огненного дождя и ракетного залпа: по кругу под каждым героем, остальные — рядом с героями.
func _barrage_points(m: Mob, ab: Dictionary) -> Array:
	var pts: Array = []
	var near: Array = []
	for h in world.heroes.values():
		if h.unit.alive and _d(m, h.unit) <= float(ab["range"]):
			near.append(h.unit)
			pts.append(Vector2(h.unit.pos.x, h.unit.pos.z))
	if near.is_empty():
		return pts
	var spread := float(ab.get("spread", 6.0))
	var guard := 0
	while pts.size() < int(ab.get("count", 4)) and guard < 40:
		guard += 1
		var hu: Unit = near[randi() % near.size()]
		var a := randf() * TAU
		pts.append(Vector2(hu.pos.x, hu.pos.z) + Vector2(cos(a), sin(a)) * randf_range(spread * 0.4, spread))
	return pts

## Точка p в полосе: от start вдоль yaw длиной length, полуширина half.
static func _in_line(p: Vector2, start: Vector2, yaw: float, length: float, half: float) -> bool:
	var fwd := Vector2(-sin(yaw), -cos(yaw))
	var d := p - start
	var along := d.dot(fwd)
	return along >= -half and along <= length + half and absf(d.cross(fwd)) <= half

func _finish_boss_cast(m: Mob, ab: Dictionary, sid: String, school: String, fx: Array, pick: Dictionary, center: Vector2, cd: Dictionary, t: float) -> void:
	var u := m.unit
	var tu: Unit = world.get_unit(int(pick.get("unit", 0)))
	var tg: Dictionary = ab.get("telegraph", {})
	match ab["delivery"]:
		"lines", "charge":
			var length := float(tg.get("radius", 18.0))
			var half := float(tg.get("width", 2.0)) * 0.5
			var yaws: Array = cd.get("yaws", [cd.get("yaw", m.yaw)])
			for h in world.heroes.values():
				var hu: Unit = h.unit
				if not hu.alive:
					continue
				for y in yaws:
					if _in_line(Vector2(hu.pos.x, hu.pos.z), center, y, length, half + hu.radius):
						world.spells.apply_effects(u, hu, fx, sid, school)
						break
			for y in yaws:
				var f := Vector2(-sin(y), -cos(y))
				for k in [0.35, 0.75]:
					var p: Vector2 = center + f * length * k
					world.spells.fx_at(_nova_kind(school), Vector3(p.x, 0, p.y), u.pos, half * 1.6, 0)
			if ab["delivery"] == "charge":
				var y0: float = yaws[0]
				var dest: Vector2 = center + Vector2(-sin(y0), -cos(y0)) * length
				world.spells.fx_at("charge_trail", Vector3(dest.x, 0, dest.y), u.pos, 0.0, u.id)
				m.pos2 = dest
				u.pos = Vector3(dest.x, 0, dest.y)
		"barrage":
			var r := float(tg.get("radius", 3.0))
			var pts: Array = cd.get("points", [])
			for h in world.heroes.values():
				var hu: Unit = h.unit
				if not hu.alive:
					continue
				for p: Vector2 in pts:
					if Vector2(hu.pos.x, hu.pos.z).distance_to(p) <= r + hu.radius:
						world.spells.apply_effects(u, hu, fx, sid, school)
						break
			for p: Vector2 in pts:
				world.spells.fx_at(_nova_kind(school), Vector3(p.x, 0, p.y), u.pos, r, 0)
		"shockwave":
			var wv: Dictionary = ab["waves"]
			for i in int(wv["count"]):
				var delay := float(wv["interval"]) * float(i)
				_waves.append({"c": m.pos2, "start": t + delay, "speed": float(wv["speed"]), "width": float(wv["width"]),
					"max": float(wv["max"]), "fx": fx, "school": school, "src": u.id, "sid": sid, "hit": {}})
				ev_shockwave.rpc(Vector3(m.pos2.x, 0, m.pos2.y), delay, float(wv["speed"]), float(wv["width"]), float(wv["max"]))
		"tomb":
			if tu and tu.alive and tu.kind == "hero":
				var tid: int = spawn(ab["tomb"], m.route, u.level, world.mode.mob_players(), 1.0, {"pos": Vector2(tu.pos.x, tu.pos.z), "owner": u.id})
				var tm: Mob = mobs.get(tid, null)
				var dur := float(ab.get("dur", 12.0))
				if tm:
					tm.bind = tu.id
					tm.until = t + dur
					tm.spawn_until = t
					tu.add_buff("ice_tomb", t + dur, {})
					var h = world.heroes.get(tu.id, null)
					if h:
						h.ev_control.rpc("root", dur, Vector3.ZERO)
					world.announce_all("%s вморожен в лёд — разбейте гробницу!" % tu.display_name, Color(0.6, 0.85, 1.0))
		"mark":
			if tu and tu.alive:
				var delay := float(ab.get("delay", 5.0))
				tu.add_buff("fel_mark", t + delay, {})
				world.spells.fx_at("bomb_mark", tu.pos, tu.pos, delay, tu.id)
				_tell(tu, "На вас Метка Скверны — отойдите от союзников!")
				_delayed.append({"at": t + delay, "pos": center, "follow": tu.id, "r": float(ab.get("radius", 6.0)), "fx": fx,
					"src": u.id, "school": school, "sid": sid, "power": u.power})
		"share":
			var r := float(tg.get("radius", 4.0))
			var inside: Array = []
			for h in world.heroes.values():
				if h.unit.alive and Vector2(h.unit.pos.x, h.unit.pos.z).distance_to(center) <= r + h.unit.radius:
					inside.append(h.unit)
			if not inside.is_empty():
				var e: Dictionary = fx[0]
				var total := randf_range(e["min"], e["max"]) * u.phys_power
				for hu: Unit in inside:
					world.spells.deal_damage(u, hu, total / float(inside.size()), school, false, sid)
			world.spells.fx_at(_nova_kind(school), Vector3(center.x, 0, center.y), u.pos, r, 0)
		"pack":
			var victim: Unit = null
			for h in world.heroes.values():
				if h.unit.alive and (victim == null or h.unit.hp_frac() < victim.hp_frac()):
					victim = h.unit
			if victim == null:
				return
			var dur := float(ab.get("dur", 6.0))
			var n := 0
			for o: Mob in mobs.values():
				if o.owner == u.id and o.unit.type_id == ab.get("pack", "") and o.pos2.distance_to(m.pos2) <= float(ab.get("radius", 30.0)):
					taunt(o.unit, victim, t + dur)
					o.unit.add_buff("pack_rush", t + dur, {"speed": 0.3, "dmg": 0.2})
					n += 1
			if n > 0:
				victim.add_buff("pack_hunt", t + dur, {})
				world.announce_all("Стая бросается на %s!" % victim.display_name, Color(1.0, 0.5, 0.3))
		"everyone":
			var r := float(ab.get("radius", 40.0))
			for h in world.heroes.values():
				if h.unit.alive and Vector2(h.unit.pos.x, h.unit.pos.z).distance_to(m.pos2) <= r:
					world.spells.apply_effects(u, h.unit, fx, sid, school)
			world.spells.fx_at(_nova_kind(school), u.pos, u.pos, 14.0, 0)
		"mines":
			var mn: Dictionary = ab["mine"]
			var r := float(ab.get("radius", 12.0))
			for i in int(ab.get("count", 4)):
				if mines.size() >= 16:
					break
				var a := randf() * TAU
				var p: Vector2 = m.pos2 + Vector2(cos(a), sin(a)) * randf_range(4.0, r)
				var id := _next_mine
				_next_mine += 1
				mines[id] = {"pos": p, "trig": float(mn["trigger"]), "blast": float(mn["blast"]), "until": t + float(mn["dur"]),
					"armed": t + 1.0, "fuse": float(mn["fuse"]), "fx": fx, "school": school, "src": u.id, "sid": sid, "power": u.power}
				ev_mine.rpc(id, Vector3(p.x, 0, p.y), true)

## Сервер: волны землетрясения расходятся кольцом; кто стоит на земле в гребне — получает удар.
func _tick_waves(t: float) -> void:
	var i := 0
	while i < _waves.size():
		var w: Dictionary = _waves[i]
		if t < float(w["start"]):
			i += 1
			continue
		var r: float = 2.0 + (t - float(w["start"])) * float(w["speed"])
		if r > float(w["max"]) + float(w["width"]):
			_waves.remove_at(i)
			continue
		var src: Unit = world.get_unit(int(w["src"]))
		for h in world.heroes.values():
			var hu: Unit = h.unit
			if not hu.alive or w["hit"].has(hu.id) or hu.pos.y > 0.45:
				continue      # в прыжке волна проходит под героем
			var d := Vector2(hu.pos.x, hu.pos.z).distance_to(w["c"])
			if absf(d - r) <= float(w["width"]) * 0.5 + hu.radius:
				w["hit"][hu.id] = true
				if src:
					world.spells.apply_effects(src, hu, w["fx"], w["sid"], w["school"])
		i += 1

## Сервер: мина взрывается, когда рядом герой (короткая задержка и телеграф), или пропадает со временем.
func _tick_mines(t: float) -> void:
	var gone: Array = []
	for id in mines:
		var mn: Dictionary = mines[id]
		if t >= float(mn["until"]):
			gone.append(id)
			continue
		if t < float(mn["armed"]):
			continue
		for h in world.heroes.values():
			if h.unit.alive and Vector2(h.unit.pos.x, h.unit.pos.z).distance_to(mn["pos"]) <= float(mn["trig"]) + h.unit.radius:
				gone.append(id)
				var p: Vector2 = mn["pos"]
				ev_telegraph.rpc("circle", Vector3(p.x, 0, p.y), 0.0, float(mn["blast"]), 0.0, float(mn["fuse"]))
				_delayed.append({"at": t + float(mn["fuse"]), "pos": p, "r": float(mn["blast"]), "fx": mn["fx"], "src": mn["src"],
					"school": mn["school"], "sid": mn["sid"], "power": mn["power"]})
				break
	for id in gone:
		mines.erase(id)
		ev_mine.rpc(id, Vector3.ZERO, false)

@rpc("authority", "call_local", "reliable")
func ev_boss_state(id: int, phase: int, shield: bool, aura: float, rot: int) -> void:
	boss_state[id] = {"phase": phase, "shield": shield, "aura": aura, "rot": rot}
	var m: Mob = mobs.get(id, null)
	if m:
		_boss_visual(m)

@rpc("authority", "call_local", "reliable")
func ev_shockwave(pos: Vector3, delay: float, speed: float, width: float, max_r: float) -> void:
	shockwaves.append([Vector2(pos.x, pos.z), world.now() + delay, speed, width, max_r])
	Vfx.shockwave(world, pos, delay, speed, width, max_r)

@rpc("authority", "call_local", "reliable")
func ev_mine(id: int, pos: Vector3, on: bool) -> void:
	if on:
		mine_spots[id] = [Vector2(pos.x, pos.z), Vfx.mine(world, pos)]
	elif mine_spots.has(id):
		var n: Node3D = mine_spots[id][1]
		if is_instance_valid(n):
			n.queue_free()
		mine_spots.erase(id)

## Облик босса по состоянию: щит (неуязвим, пока стоят филактерии), раскалённая земля вокруг.
func _boss_visual(m: Mob) -> void:
	var st: Dictionary = boss_state.get(m.unit.id, {})
	var sc := maxf(m.node.scale.x, 0.01)
	var shield := m.node.get_node_or_null("BossShield") as MeshInstance3D
	var want_shield: bool = st.get("shield", false)
	if want_shield and shield == null:
		shield = MeshInstance3D.new()
		shield.name = "BossShield"
		var sm := SphereMesh.new()
		sm.radius = m.unit.radius * 1.6 / sc
		sm.height = sm.radius * 2.0
		shield.mesh = sm
		shield.position.y = sm.radius * 0.8
		shield.material_override = Vfx.dome_material(Color(0.3, 1.0, 0.6), 1.2, 0.3)
		shield.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		m.node.add_child(shield)
	elif not want_shield and shield:
		shield.free()
	var aura := m.node.get_node_or_null("BossAura") as MeshInstance3D
	var ar: float = st.get("aura", 0.0)
	if ar > 0.0:
		if aura == null:
			aura = MeshInstance3D.new()
			aura.name = "BossAura"
			var pm := PlaneMesh.new()
			pm.size = Vector2(2, 2)
			aura.mesh = pm
			aura.material_override = Vfx.ring_material(Color(1.0, 0.35, 0.05), 0.25, false, 1.5)
			aura.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			aura.position.y = 0.05
			m.node.add_child(aura)
		aura.scale = Vector3(ar / sc, 1, ar / sc)
	elif aura:
		aura.free()

# ---------------------------------------------------------------- бот: уйти из телеграфа
## Куда уйти из опасной зоны (телеграфы, мины); ZERO — опасности нет. margin — запас, м.
func escape_dir(p: Vector2, margin: float) -> Vector2:
	var t: float = world.now()
	if not teles.is_empty():
		teles = teles.filter(func(e): return float(e[5]) >= t)
	var out := Vector2.ZERO
	for e in teles:
		var c: Vector2 = e[1]
		var d := p - c
		var away := d.normalized() if d.length() > 0.05 else Vector2(1, 0)
		match e[0]:
			"circle":
				if d.length() < float(e[3]) + margin:
					out += away
			"ring":
				var dl := d.length()
				if dl <= float(e[3]) + margin and dl >= float(e[4]) - margin:
					out += -away if dl - float(e[4]) < float(e[3]) - dl else away
			"cone":
				var fwd := Vector2(-sin(e[2]), -cos(e[2]))
				if d.length() < float(e[3]) + margin and (d.length() < 1.0 or rad_to_deg(absf(fwd.angle_to(away))) <= float(e[4]) * 0.5 + 15.0):
					var side := Vector2(-fwd.y, fwd.x)
					out += side * (1.0 if d.dot(side) >= 0.0 else -1.0) + away * 0.3
			"line":
				if _in_line(p, c, e[2], float(e[3]), float(e[4]) * 0.5 + margin):
					var fwd2 := Vector2(-sin(e[2]), -cos(e[2]))
					var side2 := Vector2(-fwd2.y, fwd2.x)
					out += side2 * (1.0 if d.dot(side2) >= 0.0 else -1.0)
	for id in mine_spots:
		var d2: Vector2 = p - mine_spots[id][0]
		if d2.length() < 2.6:
			out += d2.normalized() if d2.length() > 0.05 else Vector2(0, 1)
	return out.normalized() if out.length() > 0.01 else Vector2.ZERO

## Пора прыгать: гребень волны землетрясения вот-вот дойдёт до точки p.
func wave_near(p: Vector2) -> bool:
	var t: float = world.now()
	if not shockwaves.is_empty():
		shockwaves = shockwaves.filter(func(w): return t < float(w[1]) + (float(w[4]) + 3.0) / float(w[2]))
	for w in shockwaves:
		if t < float(w[1]):
			continue
		var r: float = 2.0 + (t - float(w[1])) * float(w[2])
		var gap: float = p.distance_to(w[0]) - r
		if gap > 0.2 and gap < 1.6:
			return true
	return false

# ---------------------------------------------------------------- питомцы (сессия 06)
## Союзные существа — в той же системе, что враги: Mob со стороной хозяина (unit.side, kind = "pet").
## Живут в своём словаре pets: волны, счётчик врагов и заклинания по площади (query_radius) их не видят.
## Враги выбирают питомца целью наравне с героями (с учётом угрозы — у медведя она выше).
## Сервер ведёт состояние питомца каждого охотника: вид, режим, команду; владельцу шлёт ev_pet_state.

const PET_KINDS := ["pet_wolf", "pet_bear", "pet_cat"]
const PET_MODES := ["aggressive", "defensive", "passive"]
const PET_LEASH := 30.0          # м: дальше от хозяина питомец бросает бой и возвращается
const PET_AGGRO := 16.0          # м от хозяина: агрессивный питомец сам нападает

var pets: Dictionary = {}        # id -> Mob (живые питомцы)
## Сервер: hero_id -> {kind, id (0 — нет), dead, mode, cmd: follow|stay|attack, target, stay_pos}
var pet_state: Dictionary = {}

func pet_units() -> Array:
	var out: Array = []
	for m: Mob in pets.values():
		out.append(m.unit)
	return out

func _pst(hid: int) -> Dictionary:
	if not pet_state.has(hid):
		pet_state[hid] = {"kind": "pet_wolf", "id": 0, "dead": false, "mode": "defensive", "cmd": "follow", "target": 0, "stay_pos": Vector2.ZERO}
	return pet_state[hid]

## Живой питомец героя (у всех: на клиенте — по owner_id из ev_spawn).
func pet_of(hero_id: int) -> Unit:
	for m: Mob in pets.values():
		if m.unit.owner_id == hero_id and m.unit.alive:
			return m.unit
	return null

## Сервер: можно ли сейчас произнести заклинание, связанное с питомцем. "" — можно.
func pet_spell_error(hero, sp: Dictionary) -> String:
	var d: String = sp.get("delivery", "")
	var p := pet_of(hero.hero_id)
	var st := _pst(hero.hero_id)
	match d:
		"pet_call":
			if st["dead"]:
				return "Питомец погиб — воскресите его"
		"pet_revive":
			if p:
				return "Питомец жив"
			if not st["dead"]:
				return "Некого воскрешать — призовите питомца"
		"pet_strike":
			if p == null:
				return "Нет питомца"
			if p.pos.distance_to(hero.unit.pos) > 40.0:
				return "Питомец слишком далеко"
	if sp.has("pet_fx") and sp.get("effects", []).is_empty() and p == null:
		return "Нет питомца"
	return ""

## Сервер: призвать (или воскресить) питомца выбранного вида рядом с охотником.
func pet_summon(hero, revive: bool) -> void:
	var st := _pst(hero.hero_id)
	var old: Mob = pets.get(int(st["id"]), null)
	if old:
		_pet_remove(old)
	var hu: Unit = hero.unit
	var back := Vector2(sin(hero.rotation.y), cos(hero.rotation.y)) * 2.5
	var pos := Vector2(hu.pos.x, hu.pos.z) + back
	var id := spawn(st["kind"], 0, 1, 1, 1.0, {"pos": pos, "pet_owner": hero.hero_id})
	st["id"] = id
	st["dead"] = false
	st["cmd"] = "follow"
	st["target"] = 0
	var m: Mob = pets[id]
	_pet_refresh(m, hero)
	m.unit.hp = m.unit.max_hp * (0.5 if revive else 1.0)
	m.spawn_until = world.now() + 0.4
	_send_pet_state(hero)

func _pet_remove(m: Mob) -> void:
	pets.erase(m.unit.id)
	world.units.erase(m.unit.id)
	m.unit.alive = false
	_pending_deaths.append(m.unit.id)
	_begin_dying(m)

## Сервер: питомец погиб (spell_system._on_death) — ждёт Воскрешения питомца.
func pet_died(u: Unit) -> void:
	var m: Mob = pets.get(u.id, null)
	if m == null:
		return
	var st := _pst(u.owner_id)
	st["dead"] = true
	st["id"] = 0
	_pet_remove(m)
	var h = world.heroes.get(u.owner_id, null)
	if h:
		_send_pet_state(h)

## Сервер: характеристики питомца от хозяина — уровень, сила атаки, таланты (pet_hp, pet_dmg, pet_armor).
func _pet_refresh(m: Mob, hero) -> void:
	var u := m.unit
	var hu: Unit = hero.unit
	var frac := u.hp_frac() if u.max_hp > 0.0 else 1.0
	u.level = hu.level
	u.max_hp = float(m.def["hp"]) * (1.0 + 0.16 * float(hu.level - 1)) * (1.0 + hu.flag("pet_hp"))
	u.hp = u.max_hp * frac
	u.power = hu.phys_power * (1.0 + hu.flag("pet_dmg")) * 0.85
	u.phys_power = u.power
	u.crit_base = hu.crit_base
	u.gear_mods = {"dmg_taken": -hu.flag("pet_armor")}

## Сервер: команда питомцу (с панели питомца или от заклинания).
func pet_command(hero, cmd: String, target_id: int) -> void:
	var st := _pst(hero.hero_id)
	match cmd:
		"attack":
			var tu: Unit = world.get_unit(target_id)
			if tu and tu.alive and hero.unit.is_enemy_of(tu):
				st["cmd"] = "attack"
				st["target"] = target_id
		"follow":
			st["cmd"] = "follow"
			st["target"] = 0
		"stay":
			var p := pet_of(hero.hero_id)
			st["cmd"] = "stay"
			st["target"] = 0
			if p:
				st["stay_pos"] = Vector2(p.pos.x, p.pos.z)
	_send_pet_state(hero)

## Просьба игрока: команда (attack/follow/stay), режим (aggressive/defensive/passive) или вид (kind:<id>).
@rpc("any_peer", "reliable")
func request_pet(cmd: String, arg: int) -> void:
	if not Net.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	var hero = world.heroes.get(Net.hero_id_of_peer(sender), null)
	if hero == null or hero.class_id != "hunter":
		return
	var st := _pst(hero.hero_id)
	if PET_MODES.has(cmd):
		st["mode"] = cmd
		_send_pet_state(hero)
	elif cmd.begins_with("kind:") and PET_KINDS.has(cmd.trim_prefix("kind:")):
		st["kind"] = cmd.trim_prefix("kind:")       # новый вид появится при следующем призыве
		_send_pet_state(hero)
	elif cmd in ["attack", "follow", "stay"]:
		pet_command(hero, cmd, arg)

func send_pet(cmd: String, arg: int = 0) -> void:
	if Net.is_server():
		request_pet(cmd, arg)
	else:
		request_pet.rpc_id(1, cmd, arg)

func _send_pet_state(hero) -> void:
	var st := _pst(hero.hero_id)
	var data := {"kind": st["kind"], "mode": st["mode"], "cmd": st["cmd"], "dead": st["dead"]}
	if hero.peer_id == multiplayer.get_unique_id():
		ev_pet_state(data)
	elif Net.is_bot_peer(hero.peer_id):
		pass
	else:
		ev_pet_state.rpc_id(hero.peer_id, data)

## У владельца: состояние своего питомца для панели питомца.
var my_pet: Dictionary = {"kind": "pet_wolf", "mode": "defensive", "cmd": "follow", "dead": false}

@rpc("authority", "reliable")
func ev_pet_state(data: Dictionary) -> void:
	my_pet = data

## Сервер: шаг питомца — выбрать цель по режиму и команде, догнать, бить, применить свой приём.
func _pet_sim(m: Mob, dt: float, t: float) -> void:
	var u := m.unit
	var hero = world.heroes.get(u.owner_id, null)
	if hero == null:
		_pet_remove(m)
		return
	if t < m.spawn_until:
		return
	if t >= m.next_think:
		m.next_think = t + 1.0
		_pet_refresh(m, hero)
		if hero.unit.flag("spirit_bond") > 0.0:
			u.hp = minf(u.max_hp, u.hp + u.max_hp * hero.unit.flag("spirit_bond") * 0.5)
	if u.is_stunned(t):
		m.anim_state = AN.FROZEN if u.is_frozen(t) else AN.STUN
		return
	var st := _pst(hero.hero_id)
	var owner_p := Vector2(hero.unit.pos.x, hero.unit.pos.z)
	var tu := _pet_target(m, hero, st, owner_p)
	m.target = tu.id if tu else 0
	if tu:
		_pet_ability(m, tu, t)
	var goal := m.pos2
	var moving := false
	if tu:
		var tp := Vector2(tu.pos.x, tu.pos.z)
		var need := float(m.def["range"]) + tu.radius + u.radius * 0.5 + (REACH_SLACK_MELEE if m.in_reach else 0.0)
		if m.pos2.distance_to(tp) <= need:
			m.in_reach = true
			_pet_attack(m, tu, t)
		else:
			m.in_reach = false
			goal = tp
			moving = true
	else:
		# к ноге: за спиной хозяина; «стоять» — на своём месте
		var home: Vector2 = st["stay_pos"] if st["cmd"] == "stay" else owner_p + Vector2(sin(hero.rotation.y), cos(hero.rotation.y)) * 2.2
		if m.pos2.distance_to(home) > 1.2:
			goal = home
			moving = true
		# совсем отстал (хозяин воскрес у замка) — появляется рядом
		if m.pos2.distance_to(owner_p) > 45.0 and st["cmd"] != "stay":
			m.pos2 = owner_p
	if moving and not u.is_rooted(t):
		_move(m, goal, dt, t)
		m.anim_state = AN.MOVE
	elif m.anim_state == AN.MOVE or m.anim_state == AN.STUN or m.anim_state == AN.SPAWN:
		m.anim_state = AN.IDLE
	u.pos = Vector3(m.pos2.x, 0, m.pos2.y)

## Цель питомца: приказ «атаковать» → иначе по режиму. Дальше PET_LEASH от хозяина — бой брошен.
func _pet_target(m: Mob, hero, st: Dictionary, owner_p: Vector2) -> Unit:
	if m.pos2.distance_to(owner_p) > PET_LEASH and st["cmd"] != "stay":
		st["target"] = 0
		if st["cmd"] == "attack":
			st["cmd"] = "follow"
		return null
	if st["cmd"] == "attack":
		var ct: Unit = world.get_unit(int(st["target"]))
		if ct and ct.alive:
			return ct
		st["cmd"] = "follow"
		st["target"] = 0
	if st["mode"] == "passive":
		return null
	var cur: Unit = world.get_unit(m.target)
	if cur and cur.alive and m.unit.is_enemy_of(cur) and Vector2(cur.pos.x, cur.pos.z).distance_to(owner_p) < PET_LEASH:
		return cur
	if st["mode"] == "aggressive":
		var best: Unit = null
		var bd := INF
		for e: Unit in world.enemies_near(m.unit, owner_p, PET_AGGRO):
			var d := Vector2(e.pos.x, e.pos.z).distance_to(m.pos2)
			if d < bd:
				best = e
				bd = d
		return best
	# защитный: то, что бьёт охотник, или то, что бьёт охотника и питомца
	var at: Unit = world.get_unit(int(world.spells._hstate(hero.hero_id).get("auto_target", 0)))
	if at and at.alive and m.unit.is_enemy_of(at) and Vector2(at.pos.x, at.pos.z).distance_to(owner_p) < PET_AGGRO + 10.0:
		return at
	# в PvP: вражеский герой, который бьёт охотника или питомца
	for la: int in [hero.unit.last_attacker, m.unit.last_attacker]:
		var lu: Unit = world.get_unit(la)
		if lu and lu.alive and lu.kind == "hero" and m.unit.is_enemy_of(lu) and Vector2(lu.pos.x, lu.pos.z).distance_to(owner_p) < PET_AGGRO:
			return lu
	for e: Unit in query_radius(owner_p, PET_AGGRO):
		var em: Mob = mobs.get(e.id, null)
		if em and em.state == S.CHASE and (em.target == hero.hero_id or em.target == m.unit.id):
			return e
	return null

func _pet_attack(m: Mob, tu: Unit, t: float) -> void:
	_face(m, Vector2(tu.pos.x, tu.pos.z))
	if t < m.attack_ready:
		if m.anim_state != AN.ATTACK:
			m.anim_state = AN.IDLE
		return
	m.attack_ready = t + float(m.def["atk_speed"]) * maxf(0.4, 1.0 - m.unit.mod("haste"))
	m.swing = (m.swing + 1) % 32
	m.anim_state = AN.ATTACK
	world.spells.apply_effects(m.unit, tu, [{"type": "damage", "min": m.def["min"], "max": m.def["max"]}], "pet", "physical")

## Приёмы питомцев (pet_abilities в данных): вой (бафф группе), рык (провокация), бросок (прыжок и кровотечение).
func _pet_ability(m: Mob, tu: Unit, t: float) -> void:
	for ab: Dictionary in m.def.get("pet_abilities", []):
		var key: String = ab["type"]
		if t < float(m.ab_ready.get(key, 0.0)):
			continue
		var dist := m.pos2.distance_to(Vector2(tu.pos.x, tu.pos.z))
		match key:
			"howl":
				if dist > 12.0:
					continue
				for h in world.ally_heroes(m.unit):
					if h.unit.alive and h.unit.pos.distance_to(m.unit.pos) <= float(ab["radius"]):
						world.spells.apply_effects(m.unit, h.unit, [{"type": "buff", "key": ab["buff"], "dur": ab["dur"], "mods": ab["mods"]}], "wolf_howl", "nature")
				world.spells.fx_at("taunt_aoe", m.unit.pos, m.unit.pos, float(ab["radius"]) * 0.3, m.unit.id)
				world.spells.ev_sound.rpc("pet_howl", m.unit.pos)
			"growl":
				var near: Array = query_radius(m.pos2, float(ab["radius"])).filter(func(e): return m.unit.is_enemy_of(e))
				if near.is_empty():
					continue
				for e: Unit in near:
					taunt(e, m.unit, t + float(ab["dur"]))
				world.spells.fx_at("taunt_aoe", m.unit.pos, m.unit.pos, float(ab["radius"]), m.unit.id)
				world.spells.ev_sound.rpc("pet_growl", m.unit.pos)
			"pounce":
				if dist < float(ab["min_dist"]) or dist > float(ab["max_dist"]):
					continue
				var dir := (Vector2(tu.pos.x, tu.pos.z) - m.pos2).normalized()
				world.spells.fx_at("charge_trail", tu.pos, m.unit.pos, 0.0, m.unit.id)
				m.pos2 = Vector2(tu.pos.x, tu.pos.z) - dir * (tu.radius + m.unit.radius)
				m.unit.pos = Vector3(m.pos2.x, 0, m.pos2.y)
				world.spells.apply_effects(m.unit, tu, [{"type": "dot", "total": ab["bleed"], "dur": ab["dur"], "tick": 1.0, "key": "cat_bleed"}], "cat_pounce", "physical")
				world.spells.ev_sound.rpc("pet_growl", m.unit.pos)
		m.ab_ready[key] = t + float(ab["cd"])
		return

## Сервер: все живые враги и питомцы — одному игроку, вошедшему посреди партии (частями по 60, чтобы
## при 200+ мобах один пакет не был огромным). Формат записи — как у ev_spawn.
func send_full(peer: int) -> void:
	var t0 := Time.get_ticks_usec()
	var bytes := 0
	var parts := 0
	var batch: Array = []
	for m: Mob in mobs.values() + pets.values():
		var u := m.unit
		batch.append([u.id, u.type_id, m.pos2.x, m.pos2.y, m.yaw, u.max_hp, u.level, u.affixes, u.elite, u.owner_id, u.sent_by, u.side])
		if batch.size() >= 60:
			bytes += var_to_bytes(batch).size()
			parts += 1
			ev_spawn.rpc_id(peer, batch)
			batch = []
	if not batch.is_empty():
		bytes += var_to_bytes(batch).size()
		parts += 1
		ev_spawn.rpc_id(peer, batch)
	if Net.cli.has("netlog"):
		print("FULL SNAPSHOT mobs=%d parts=%d bytes=%d build=%.1f ms" % [mobs.size() + pets.size(), parts, bytes, (Time.get_ticks_usec() - t0) / 1000.0])
	for id in walls:
		var w: Dictionary = walls[id]
		var a: Vector2 = w["a"]
		var b: Vector2 = w["b"]
		var c := (a + b) * 0.5
		world.spells.ev_zone.rpc_id(peer, id, "wall_ice", Vector3(c.x, 0, c.y), -(b - a).angle(), a.distance_to(b), maxf(0.5, float(w["until"]) - world.now()))
		if Unit.pvp:
			world.spells.ev_wall_block.rpc_id(peer, id, Vector3(a.x, 0, a.y), Vector3(b.x, 0, b.y), int(w.get("side", 0)), maxf(0.5, float(w["until"]) - world.now()))

# ---------------------------------------------------------------- C++ (GDExtension, сессия 08)
## Горячие циклы серверной симуляции — в C++ (native/, класс MobSimNative из bin/herosiege_native.dll):
## сетка соседей, запросы по радиусу, расталкивание и движение с препятствиями и стенами, кодирование снимка.
## Решения (погоня, поводок, способности, боссы) — здесь, в GDScript. Если библиотека не загрузилась —
## всё работает на GDScript (запасной путь). --mobsim=gd|cpp — выбрать путь для сравнения.
var _native: Object = null

func _init_native() -> void:
	var want := str(Net.cli.get("mobsim", "cpp"))
	if want == "gd" or not ClassDB.class_exists("MobSimNative"):
		return
	_native = ClassDB.instantiate("MobSimNative")

func sim_path() -> String:
	return "cpp" if _native != null else "gd"
