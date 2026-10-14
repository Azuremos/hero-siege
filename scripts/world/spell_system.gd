extends Node
## Боевая система. Сервер проверяет и применяет заклинания,
## клиентам рассылаются только события для анимаций и эффектов.

var world: Node3D

# Состояние героев на сервере: hero_id -> {cds, gcd, cast, auto_target, auto_ready}
var hs: Dictionary = {}
var projectiles: Array = []     # {impact, target, caster, effects, spell, school, chain_from}
var zones: Dictionary = {}      # id -> {...}
var _next_zone_id := 1
var _regen_accum := 0.0

func _ready() -> void:
	world = get_parent()

func _hstate(hid: int) -> Dictionary:
	if not hs.has(hid):
		hs[hid] = {"cds": {}, "gcd": 0.0, "cast": {}, "auto_target": 0, "auto_ready": 0.0}
	return hs[hid]

## Отправка запроса хосту (у самого хоста — прямой вызов).
func send_to_server(method: String, args: Array) -> void:
	if Net.is_server():
		callv(method, args)
	else:
		_rpc_server(method, args)

func _rpc_server(method: String, args: Array) -> void:
	match args.size():
		0: rpc_id(1, method)
		1: rpc_id(1, method, args[0])
		2: rpc_id(1, method, args[0], args[1])
		3: rpc_id(1, method, args[0], args[1], args[2])
		4: rpc_id(1, method, args[0], args[1], args[2], args[3])
		5: rpc_id(1, method, args[0], args[1], args[2], args[3], args[4])

func _sender_hero() -> Node:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	return world.heroes.get(Net.hero_id_of_peer(sender), null)

# ---------------------------------------------------------------- запросы игроков

@rpc("any_peer", "reliable")
func request_cast(sid: String, target_id: int, ground: Vector3, yaw: float, length: float = 0.0) -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero == null or not GameData.SPELLS.has(sid):
		return
	var u: Unit = hero.unit
	var st := _hstate(hero.hero_id)
	var sp: Dictionary = GameData.SPELLS[sid]
	var t: float = world.now()
	var peer: int = hero.peer_id
	if not hero.spell_list().has(sid):
		return
	if u.level < GameData.spell_level(sid):
		return _feedback(peer, sid, "Откроется на %d уровне" % GameData.spell_level(sid))
	if not u.alive or u.is_stunned(t):
		return _feedback(peer, sid, "Сейчас нельзя")
	if not st["cast"].is_empty():
		return _feedback(peer, sid, "Вы уже произносите заклинание")
	var proc := GameData.active_proc(u, sid)
	if t < float(st["cds"].get(sid, 0.0)) and not (not proc.is_empty() and proc["data"].get("reset_cd", false)):
		return _feedback(peer, sid, "Заклинание ещё не готово")
	if t < st["gcd"] - 0.15:
		return
	if u.mana < GameData.eff_mana(u, sid):
		return _feedback(peer, sid, "Недостаточно ярости" if u.resource == "rage" else "Недостаточно маны")
	var max_range := GameData.eff_range(u, sid)
	# проверка цели
	match sp["target"]:
		"enemy":
			var tu: Unit = world.get_unit(target_id)
			if tu == null or not tu.alive or tu.team == u.team:
				return _feedback(peer, sid, "Неверная цель")
			if _dist(u, tu) > max_range + tu.radius + 1.5:
				return _feedback(peer, sid, "Цель слишком далеко")
			if sp.has("min_range") and _dist(u, tu) < float(sp["min_range"]):
				return _feedback(peer, sid, "Цель слишком близко")
			if sp.has("execute") and tu.hp_frac() > float(sp["execute"]) and not (not proc.is_empty() and proc["data"].get("allow_execute", false)):
				return _feedback(peer, sid, "Казнь — только по врагам с запасом здоровья ниже 25%")
		"ally":
			var tu: Unit = world.get_unit(target_id)
			if tu == null or not tu.alive or tu.team != u.team or tu.kind != "hero":
				target_id = u.id
			elif _dist(u, tu) > max_range + 2.0:
				return _feedback(peer, sid, "Цель слишком далеко")
		"self":
			target_id = u.id
		"ground", "wall":
			var extra := _wall_length(u, sid, length) * 0.5 if sp["target"] == "wall" else 0.0
			if Vector2(ground.x - u.pos.x, ground.z - u.pos.z).length() > max_range + 2.0 + extra:
				return _feedback(peer, sid, "Слишком далеко")
	# «Ослабленная душа» и т.п.: заклинание нельзя повторить на ту же цель, пока на ней метка
	if sp.has("target_lockout"):
		var lu: Unit = world.get_unit(target_id)
		var lk: Dictionary = sp["target_lockout"]
		if lu and lu.has_buff(lk["key"]):
			return _feedback(peer, sid, "На цели ещё действует «%s»" % GameData.BUFF_INFO[lk["key"]]["name"])
	st["gcd"] = t + GameData.GCD
	var cast_time := GameData.eff_cast(u, sid)
	if sp["delivery"] == "channel":
		# поток: мана и восстановление сразу, снаряды — по ходу произнесения
		_spend_mana(u, GameData.eff_mana(u, sid), t)
		if u.has_buff("clearcasting"):
			u.remove_buff("clearcasting")
		var cdc := GameData.eff_cd(u, sid)
		if cdc > 0.0:
			st["cds"][sid] = t + cdc
		var ticks := int(sp["ticks"])
		st["cast"] = {"sid": sid, "target": target_id, "ground": ground, "yaw": yaw, "end": t + cast_time + 0.1,
			"start_pos": u.pos, "channel": true, "ticks_left": ticks, "interval": cast_time / ticks, "next_tick": t + 0.15}
		st["auto_target"] = target_id
		ev_cast_start.rpc(u.id, sid, cast_time, true)
		_feedback(peer, sid, "", cdc, GameData.GCD)
	elif cast_time > 0.0:
		st["cast"] = {"sid": sid, "target": target_id, "ground": ground, "yaw": yaw, "length": length, "end": t + cast_time, "start_pos": u.pos}
		ev_cast_start.rpc(u.id, sid, cast_time, false)
		_feedback(peer, sid, "", 0.0, GameData.GCD)
	else:
		_complete_cast(hero, sid, target_id, ground, yaw, length)

@rpc("any_peer", "reliable")
func request_cancel() -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero:
		_interrupt(hero)

@rpc("any_peer", "reliable")
func request_auto(target_id: int) -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	var tu: Unit = world.get_unit(target_id)
	if hero and tu and tu.team == Unit.Team.ENEMIES:
		_hstate(hero.hero_id)["auto_target"] = target_id

func _feedback(peer: int, sid: String, err: String, cd: float = 0.0, gcd: float = 0.0) -> void:
	if err != "" and Net.cli.has("castlog"):
		print("CAST FAIL ", sid, ": ", err)
	if peer == multiplayer.get_unique_id():
		ev_feedback(sid, err, cd, gcd)
	else:
		ev_feedback.rpc_id(peer, sid, err, cd, gcd)

@rpc("authority", "reliable")
func ev_feedback(sid: String, err: String, cd: float, gcd: float) -> void:
	var lh = world.local_hero
	if lh and lh.controller:
		lh.controller.on_feedback(sid, err, cd, gcd)

@rpc("authority", "call_local", "reliable")
func ev_cast_start(caster_id: int, sid: String, duration: float, channel: bool) -> void:
	var h = world.heroes.get(caster_id, null)
	if h == null:
		return
	h.casting = true
	Sfx.play_at("cast_start", h.global_position + Vector3(0, 1.5, 0))
	if h == world.local_hero:
		h.controller.on_cast_started(sid, duration, channel)

@rpc("authority", "call_local", "reliable")
func ev_cast_end(caster_id: int, sid: String, ok: bool) -> void:
	var h = world.heroes.get(caster_id, null)
	if h == null:
		return
	h.casting = false
	if ok and sid != "":
		h.play_action(GameData.SPELLS[sid].get("anim", "cast"))
	if h == world.local_hero:
		h.controller.on_cast_ended(ok)

func _interrupt(hero) -> void:
	var st := _hstate(hero.hero_id)
	if st["cast"].is_empty():
		return
	st["cast"] = {}
	st["gcd"] = 0.0
	ev_cast_end.rpc(hero.unit.id, "", false)

# ---------------------------------------------------------------- серверный тик

func server_tick(delta: float, t: float) -> void:
	for hid in world.heroes:
		var hero = world.heroes[hid]
		var u: Unit = hero.unit
		var st := _hstate(hid)
		if not u.alive:
			st["cast"] = {}
			st["auto_target"] = 0
			continue
		if not st["cast"].is_empty():
			var c: Dictionary = st["cast"]
			if u.is_stunned(t) or u.pos.distance_to(c["start_pos"]) > 0.8:
				_interrupt(hero)
			elif c.get("channel", false):
				_channel_tick(hero, st, c, t)
			elif t >= c["end"]:
				st["cast"] = {}
				_complete_cast(hero, c["sid"], c["target"], c["ground"], c["yaw"], float(c.get("length", 0.0)))
		_auto_attack(hero, st, t)

	_update_projectiles(t)
	_update_zones(t)
	_update_auras(t)

	_regen_accum += delta
	if _regen_accum >= 0.5:
		_regen_accum = 0.0
		var rest := 8.0 if world.mode.is_resting() else 1.0   # передышка — быстрый отдых
		for hero in world.heroes.values():
			var u: Unit = hero.unit
			if not u.alive:
				continue
			if u.resource == "rage":
				# ярость не восполняется сама и угасает вне боя
				if t > u.combat_until:
					u.mana = maxf(0.0, u.mana - 1.5)
			else:
				# в секунду: запас × 3% + Дух × 0,6; после траты маны 5 с — четверть (правило 5 секунд)
				var per_s := u.max_mana * GameData.MANA_REGEN_POOL + u.spirit * GameData.MANA_REGEN_SPIRIT
				if t - u.mana_spent_at < GameData.FIVE_SECOND_RULE:
					per_s *= GameData.CASTING_REGEN
				u.mana = minf(u.max_mana, u.mana + per_s * 0.5 * (1.0 + u.mod("regen")) * rest)
			u.hp = minf(u.max_hp, u.hp + (u.max_hp * 0.0025 + u.spirit * 0.05) * rest)
	_update_bursts(t)

## Списать ману (или ярость). Трата маны запускает правило 5 секунд: восполнение в бою ниже.
func _spend_mana(u: Unit, cost: float, t: float) -> void:
	u.mana -= cost
	if cost > 0.0 and u.resource != "rage":
		u.mana_spent_at = t
		u.stat_spent += cost

func _auto_attack(hero, st: Dictionary, t: float) -> void:
	var tid: int = st["auto_target"]
	if tid == 0 or not st["cast"].is_empty() or t < st["auto_ready"]:
		return
	var tu: Unit = world.get_unit(tid)
	if tu == null or not tu.alive:
		st["auto_target"] = 0
		return
	var auto: Dictionary = GameData.CLASSES[hero.class_id]["auto"]
	var u: Unit = hero.unit
	if _dist(u, tu) > float(auto["range"]) + tu.radius or u.is_stunned(t):
		return
	st["auto_ready"] = t + float(auto["speed"]) * maxf(0.5, 1.0 - u.mod("haste"))
	var fx := [{"type": "damage", "min": auto["min"], "max": auto["max"]}]
	if auto["ranged"]:
		_launch_projectile(u, tu, fx, "auto", auto["school"], 32.0, "bolt_" + auto["school"], t)
		ev_action.rpc(u.id, "wand")
	else:
		apply_effects(u, tu, fx, "auto", auto["school"])
		ev_action.rpc(u.id, "melee2")
		if u.resource == "rage":
			gain_rage(u, 10.0 * (1.0 + u.flag("rage_gen")), t)
	_trigger_procs(u, tu, "auto", "", auto["school"], false, t)

@rpc("authority", "call_local", "unreliable")
func ev_action(unit_id: int, key: String) -> void:
	var h = world.heroes.get(unit_id, null)
	if h:
		h.play_action(key)

# ---------------------------------------------------------------- применение заклинаний

func _channel_tick(hero, st: Dictionary, c: Dictionary, t: float) -> void:
	if t < c["next_tick"]:
		return
	var sp: Dictionary = GameData.SPELLS[c["sid"]]
	var tu: Unit = world.get_unit(c["target"])
	if tu == null or not tu.alive or c["ticks_left"] <= 0:
		st["cast"] = {}
		ev_cast_end.rpc(hero.unit.id, c["sid"] if c["ticks_left"] <= 0 else "", c["ticks_left"] <= 0)
		return
	c["ticks_left"] -= 1
	c["next_tick"] = t + c["interval"]
	_launch_projectile(hero.unit, tu, sp["effects"], c["sid"], sp["school"], float(sp["speed"]), sp["vfx"], t)
	if c["ticks_left"] <= 0:
		c["next_tick"] = t + 0.05

## Длина нарисованной стены: от 3 м до максимума заклинания (с талантами).
func _wall_length(u: Unit, sid: String, requested: float) -> float:
	var sp: Dictionary = GameData.SPELLS[sid]
	var max_len := float(sp["length"]) + u.mod("length_add", sid, sp["school"])
	if requested <= 0.0:
		return max_len
	return clampf(requested, 3.0, max_len)

func _complete_cast(hero, sid: String, target_id: int, ground: Vector3, yaw: float, req_length: float = 0.0) -> void:
	var sp: Dictionary = GameData.SPELLS[sid]
	var u: Unit = hero.unit
	var t: float = world.now()
	var st := _hstate(hero.hero_id)
	var tu: Unit = world.get_unit(target_id)
	if sp["target"] == "enemy" and (tu == null or not tu.alive):
		ev_cast_end.rpc(u.id, "", false)
		return
	var mana_cost := GameData.eff_mana(u, sid)
	if u.has_buff("clearcasting") and float(sp["mana"]) > 0.0 and u.resource != "rage":
		u.remove_buff("clearcasting")
	_spend_mana(u, mana_cost, world.now())
	if sp.has("target_lockout") and tu:
		tu.add_buff(sp["target_lockout"]["key"], t + float(sp["target_lockout"]["dur"]), {})
	var cd := GameData.eff_cd(u, sid)
	if cd > 0.0:
		st["cds"][sid] = t + cd
	_feedback(hero.peer_id, sid, "", cd, maxf(0.0, st["gcd"] - t))
	ev_cast_end.rpc(u.id, sid, true)
	var school: String = sp["school"]
	if Net.cli.has("proclog"):
		print("CAST ", sid)
	# прок, действующий на это заклинание: расходуем, усиливаем эффекты
	var proc := GameData.active_proc(u, sid)
	if not proc.is_empty():
		u.remove_buff(proc["key"])
		var amp := float(proc["data"].get("amp", 0.0))
		if amp > 0.0:
			sp = _amplified(sp, 1.0 + amp)
	if sp.has("rage_gain"):
		gain_rage(u, float(sp["rage_gain"]), t)
	_trigger_procs(u, tu, "cast", sid, school, false, t)
	# Ясность мысли: следующее заклинание бесплатно
	if float(sp["mana"]) > 0.0 and u.flag("clearcasting") > 0.0 and randf() < u.flag("clearcasting"):
		u.add_buff("clearcasting", t + 15.0, {})
	var radius := float(sp.get("radius", 0.0)) + u.mod("radius_add", sid, school)
	var duration := float(sp.get("duration", 0.0)) + u.mod("dur_add", sid, school)

	match sp["delivery"]:
		"projectile":
			_launch_projectile(u, tu, sp["effects"], sid, school, float(sp["speed"]), sp["vfx"], t)
			st["auto_target"] = tu.id
		"instant":
			if sp["target"] == "enemy":
				st["auto_target"] = tu.id
			apply_effects(u, tu, sp["effects"], sid, school)
			fx_at(sp["vfx"], tu.pos, u.pos, _buff_duration(sp), tu.id)
		"ally_aoe":
			var cands: Array = []
			for h in world.heroes.values():
				if h.unit.alive and _dist(h.unit, tu) <= radius:
					cands.append(h.unit)
			cands.sort_custom(func(a, b): return a.hp_frac() < b.hp_frac())
			var max_targets := int(sp["max_targets"]) + int(u.mod("targets_add", sid, school))
			for i in mini(cands.size(), max_targets):
				apply_effects(u, cands[i], sp["effects"], sid, school)
				fx_at("heal_small", cands[i].pos, u.pos, 0.0, cands[i].id)
			fx_at(sp["vfx"], tu.pos, u.pos, radius, tu.id)
		"self_aoe":
			for m in world.mobs.query_radius(Vector2(u.pos.x, u.pos.z), radius):
				apply_effects(u, m, sp.get("enemy_fx", []), sid, school)
			if sp.has("ally_fx"):
				for h in world.heroes.values():
					if h.unit.alive and _dist(h.unit, u) <= radius:
						apply_effects(u, h.unit, sp["ally_fx"], sid, school)
			fx_at(sp["vfx"], u.pos, u.pos, radius, u.id)
		"charge":
			# рывок: сервер оглушает цель, а свой герой сам перемещается к ней
			apply_effects(u, tu, sp["effects"], sid, school)
			st["auto_target"] = tu.id
			fx_at(sp["vfx"], tu.pos, u.pos, 0.0, tu.id)
			var dest: Vector3 = tu.pos + (u.pos - tu.pos).normalized() * (tu.radius + 1.2)
			if hero.peer_id == multiplayer.get_unique_id():
				hero.ev_dash(dest)
			else:
				hero.ev_dash.rpc_id(hero.peer_id, dest)
		"party":
			# все союзники рядом с заклинателем
			for h in world.heroes.values():
				if h.unit.alive and _dist(h.unit, u) <= radius:
					apply_effects(u, h.unit, sp["effects"], sid, school)
					fx_at("heal_small" if sp["vfx"] == "heal_circle" else sp["vfx"], h.unit.pos, u.pos, _buff_duration(sp), h.unit.id)
			if sp["vfx"] == "heal_circle":
				fx_at("heal_circle", u.pos, u.pos, radius * 0.5, u.id)
		"ground_burst":
			var c := Vector3(ground.x, 0, ground.z)
			for m in world.mobs.query_radius(Vector2(c.x, c.z), radius):
				apply_effects(u, m, sp.get("enemy_fx", []), sid, school)
			for h in world.heroes.values():
				if h.unit.alive and Vector2(h.unit.pos.x - c.x, h.unit.pos.z - c.z).length() <= radius:
					apply_effects(u, h.unit, sp.get("ally_fx", []), sid, school)
			fx_at(sp["vfx"], c, c, radius, 0)
			fx_at("beam_holy", c, c, 0.0, 0)
		"zone":
			var center := u.pos if sp["target"] == "self" else ground
			center.y = 0.0
			if sp.has("impact_fx"):
				for m in world.mobs.query_radius(Vector2(center.x, center.z), radius):
					apply_effects(u, m, sp["impact_fx"], sid, school)
			_add_zone({"sid": sid, "kind": "circle", "pos": center, "radius": radius, "reach": radius, "caster": u.id,
				"until": t + duration, "tick": float(sp["tick"]), "next": t + 0.05,
				"ally_dr": float(sp.get("ally_dr", 0.0))}, sp["vfx"], yaw, radius, duration)
		"blink":
			var dist := float(sp["distance"])
			fx_at("blink", u.pos, u.pos, 0.0, u.id)
			if hero.peer_id == multiplayer.get_unique_id():
				hero.ev_blink(dist)
			else:
				hero.ev_blink.rpc_id(hero.peer_id, dist)
		"zone_line":
			var length := _wall_length(u, sid, req_length)
			var half := length * 0.5
			var right := Basis(Vector3.UP, yaw) * Vector3.RIGHT
			_add_zone({"sid": sid, "kind": "line", "pos": ground, "a": ground - right * half, "b": ground + right * half,
				"width": float(sp["width"]), "reach": half + float(sp["width"]), "caster": u.id, "until": t + duration,
				"tick": float(sp["tick"]), "next": t + 0.05, "ally_dr": 0.0}, sp["vfx"], yaw, length, duration)
		"wall":
			var length := _wall_length(u, sid, req_length)
			var half := length * 0.5
			var right := Basis(Vector3.UP, yaw) * Vector3.RIGHT
			var a := ground - right * half
			var b := ground + right * half
			var hp := float(sp["wall_hp"]) * u.power * (1.0 + u.mod("wall_hp", sid, school))
			var wid: int = world.mobs.add_wall(Vector2(a.x, a.z), Vector2(b.x, b.z), hp, t + duration)
			ev_zone.rpc(wid, sp["vfx"], ground, yaw, length, duration)

func _buff_duration(sp: Dictionary) -> float:
	for e in sp.get("effects", []):
		if e["type"] == "buff":
			return float(e["dur"])
	return 0.0

func _add_zone(z: Dictionary, vfx: String, yaw: float, size: float, duration: float) -> void:
	var id := _next_zone_id
	_next_zone_id += 1
	zones[id] = z
	ev_zone.rpc(10000 + id, vfx, z["pos"], yaw, size, duration)

func _launch_projectile(u: Unit, tu: Unit, effects: Array, sid: String, school: String, speed: float, vfx: String, t: float) -> void:
	var travel := _dist(u, tu) / speed
	projectiles.append({"impact": t + travel, "target": tu.id, "caster": u.id, "effects": effects, "sid": sid, "school": school})
	ev_projectile.rpc(vfx, u.id, tu.id, speed)

func _update_projectiles(t: float) -> void:
	var i := 0
	while i < projectiles.size():
		var p: Dictionary = projectiles[i]
		if t >= p["impact"]:
			projectiles.remove_at(i)
			var tu: Unit = world.get_unit(p["target"])
			var cu: Unit = world.get_unit(p["caster"])
			if tu and tu.alive and cu:
				apply_effects(cu, tu, p["effects"], p["sid"], p["school"])
		else:
			i += 1

func _update_zones(t: float) -> void:
	# сброс бонусов барьера
	for h in world.heroes.values():
		h.unit.damage_taken_mult = 1.0
	var dead: Array = []
	for id in zones:
		var z: Dictionary = zones[id]
		if t >= z["until"]:
			dead.append(id)
			continue
		var caster: Unit = world.get_unit(z["caster"])
		if z["ally_dr"] > 0.0:
			for h in world.heroes.values():
				if h.unit.alive and _in_zone(z, h.unit):
					h.unit.damage_taken_mult = minf(h.unit.damage_taken_mult, 1.0 - z["ally_dr"])
		if t < z["next"] or caster == null:
			continue
		z["next"] = t + z["tick"]
		var sp: Dictionary = GameData.SPELLS[z["sid"]]
		var center: Vector3 = z["pos"]
		for m in world.mobs.query_radius(Vector2(center.x, center.z), float(z["reach"]) + 1.5):
			if _in_zone(z, m):
				apply_effects(caster, m, sp.get("enemy_fx", []), z["sid"], sp["school"])
	for id in dead:
		zones.erase(id)

func _in_zone(z: Dictionary, u: Unit) -> bool:
	var p := Vector2(u.pos.x, u.pos.z)
	if z["kind"] == "circle":
		var c: Vector3 = z["pos"]
		return p.distance_to(Vector2(c.x, c.z)) <= z["radius"] + u.radius * 0.5
	var a: Vector3 = z["a"]
	var b: Vector3 = z["b"]
	var cp := Geometry2D.get_closest_point_to_segment(p, Vector2(a.x, a.z), Vector2(b.x, b.z))
	return cp.distance_to(p) <= z["width"] * 0.5 + u.radius

func _update_auras(t: float) -> void:
	_tick_auras_for(world.heroes.values().map(func(h): return h.unit), t)
	_tick_auras_for(world.mobs.alive_units(), t)

func _tick_auras_for(list: Array, t: float) -> void:
	for u: Unit in list:
		if not u.alive:
			continue
		if not u.buffs.is_empty():
			var before := u.buffs.size()
			u.buffs = u.buffs.filter(func(b): return t < b["until"])
			if u.buffs.size() != before:
				_refresh_stats(u)
		var i := 0
		while i < u.auras.size() and u.alive:
			var a: Dictionary = u.auras[i]
			if t >= a["next"]:
				a["next"] += a["tick"]
				var src: Unit = world.get_unit(a["source"])
				if a["kind"] == "dot":
					deal_damage(src, u, a["per_tick"], a["school"], false)
				else:
					heal(src, u, a["per_tick"], false)
				if not u.alive:
					break
			if t >= a["until"] - 0.01:
				u.auras.remove_at(i)
				if a.has("explode"):
					_explode(a, u)
			else:
				i += 1

## Взрыв Живой бомбы.
func _explode(a: Dictionary, u: Unit) -> void:
	var src: Unit = world.get_unit(a["source"])
	var ex: Dictionary = a["explode"]
	for m: Unit in world.mobs.query_radius(Vector2(u.pos.x, u.pos.z), float(ex["radius"])):
		deal_damage(src, m, randf_range(ex["min"], ex["max"]), "fire", false)
	fx_at("explosion_fire", u.pos, u.pos, float(ex["radius"]), 0)

# ---------------------------------------------------------------- эффекты

func _m(u: Unit, key: String, sid: String = "", school: String = "") -> float:
	return u.mod(key, sid, school) if u else 0.0

func apply_effects(caster: Unit, target: Unit, effects: Array, sid: String, school: String) -> void:
	var t: float = world.now()
	var pw := 1.0
	if caster:
		pw = caster.phys_power if school == "physical" else caster.power
	var amp := _m(caster, "amount", sid, school)
	var crit_chance := (caster.crit_base if caster else 0.05) + _m(caster, "crit", sid, school)
	if caster and target.is_rooted(t):
		crit_chance += caster.flag("shatter")
	for e: Dictionary in effects:
		if not target.alive:
			return
		match e["type"]:
			"damage":
				var mult := 1.0 + amp + _m(caster, "dmg")
				if sid == "auto":
					mult += _m(caster, "auto")
				var amount := randf_range(e["min"], e["max"]) * pw * maxf(0.1, mult)
				if e.has("frozen_bonus") and target.is_rooted(t):
					amount *= 1.0 + float(e["frozen_bonus"])
				var crit := randf() < crit_chance
				if crit:
					amount *= 1.5
				deal_damage(caster, target, amount, school, crit)
				if caster and caster.kind == "hero":
					_on_damage_dealt(caster, target, amount, school, crit, t)
					if sid != "auto":
						_trigger_procs(caster, target, "spell_hit", sid, school, crit, t)
			"heal":
				var amount := randf_range(e["min"], e["max"]) * pw * (caster.heal_mult if caster else 1.0) * (1.0 + amp + _m(caster, "heal"))
				var crit := randf() < crit_chance
				if crit:
					amount *= 1.5
				heal(caster, target, amount, crit)
				if crit and caster:
					_on_heal_crit(caster, target, sid, t)
				if caster:
					_trigger_procs(caster, target, "heal", sid, school, crit, t)
			"heal_self_pct":
				if caster:
					heal(caster, caster, caster.max_hp * float(e["pct"]), false)
			"heal_pct":
				heal(caster, target, target.max_hp * float(e["pct"]), false)
			"slow":
				if target.kind != "castle":
					var pct := minf(0.9, float(e["pct"]) + _m(caster, "slow_add", sid, school))
					target.slow_pct = maxf(pct, target.slow_pct if t < target.slow_until else 0.0)
					target.slow_until = maxf(target.slow_until, t + float(e["dur"]))
			"root":
				target.root_until = maxf(target.root_until, t + float(e["dur"]))
				fx_at("rooted", target.pos, target.pos, float(e["dur"]), target.id)
			"freeze":
				_freeze(target, float(e["dur"]), t)
			"taunt":
				if caster and target.kind == "mob":
					world.mobs.taunt(target, caster, t + float(e["dur"]))
			"chill":
				if target.kind == "mob" and not target.is_frozen(t):
					if t > target.chill_until:
						target.chill = 0
					target.chill += 1
					target.chill_until = t + 6.0
					if target.chill >= int(e["stacks"]):
						target.chill = 0
						_freeze(target, float(e["dur"]), t)
			"stun":
				var dur := (float(e["dur"]) + _m(caster, "stun_add", sid, school)) * (0.5 if target.kind == "mob" and _is_boss(target) else 1.0)
				target.stun_until = maxf(target.stun_until, t + dur)
				fx_at("stunned", target.pos, target.pos, dur, target.id)
			"dot", "hot":
				var ticks := float(e["dur"]) / float(e["tick"])
				var boost := 1.0 + amp + (_m(caster, "dmg") if e["type"] == "dot" else _m(caster, "heal"))
				var per := float(e["total"]) * pw * boost / ticks
				if e["type"] == "hot" and caster:
					per *= caster.heal_mult
				var key: String = e["key"]
				for a in target.auras:
					if a["key"] == key:
						target.auras.erase(a)
						break
				var aura := {"key": key, "kind": e["type"], "per_tick": per, "tick": float(e["tick"]),
					"next": t + float(e["tick"]), "until": t + float(e["dur"]), "school": school,
					"source": caster.id if caster else 0}
				if e.has("explode"):
					var ex: Dictionary = e["explode"]
					aura["explode"] = {"radius": ex["radius"], "min": float(ex["min"]) * pw * boost, "max": float(ex["max"]) * pw * boost}
					fx_at("bomb_mark", target.pos, target.pos, float(e["dur"]), target.id)
				target.auras.append(aura)
			"absorb":
				var amount := float(e["amount"]) * pw * (1.0 + amp + _m(caster, "heal"))
				target.absorb = maxf(target.absorb if t < target.absorb_until else 0.0, amount)
				target.absorb_until = t + float(e["dur"])
			"immune":
				target.immune_until = t + float(e["dur"])
				target.auras = target.auras.filter(func(a): return a["kind"] != "dot")
			"buff":
				target.add_buff(e["key"], t + float(e["dur"]), e.get("mods", {}))
				_refresh_stats(target)
			"beacon":
				if caster:
					var st := _hstate(caster.id)
					var old: Unit = world.get_unit(int(st.get("beacon", 0)))
					if old:
						old.remove_buff("beacon")
					st["beacon"] = target.id
					target.add_buff("beacon", t + float(e["dur"]), {})
			"chain":
				var from := Vector2(target.pos.x, target.pos.z)
				var hits := 0
				var count := int(e["count"]) + int(_m(caster, "chain_add", sid, school))
				for m: Unit in world.mobs.query_radius(from, float(e["radius"])):
					if m == target or hits >= count:
						continue
					hits += 1
					var dmg_fx: Dictionary = effects[0]
					var amount := randf_range(dmg_fx["min"], dmg_fx["max"]) * pw * float(e["mult"]) * maxf(0.1, 1.0 + amp + _m(caster, "dmg"))
					deal_damage(caster, m, amount, school, false)
					fx_at("chain_" + school, m.pos, target.pos, 0.0, m.id)

## Особые эффекты талантов при нанесении урона.
func _on_damage_dealt(caster: Unit, target: Unit, amount: float, school: String, crit: bool, t: float) -> void:
	if crit and school == "fire" and caster.flag("ignite") > 0.0 and target.alive:
		var total := amount * caster.flag("ignite")
		for a in target.auras:
			if a["key"] == "ignite_talent":
				target.auras.erase(a)
				break
		target.auras.append({"key": "ignite_talent", "kind": "dot", "per_tick": total / 2.0, "tick": 2.0,
			"next": t + 2.0, "until": t + 4.0, "school": "fire", "source": caster.id})
	if school == "frost" and target.alive and caster.flag("frostbite") > 0.0 and randf() < caster.flag("frostbite"):
		_freeze(target, 2.0, t)
	if crit and school == "physical" and caster.flag("deep_wounds") > 0.0 and target.alive:
		var bleed := amount * caster.flag("deep_wounds")
		for a in target.auras:
			if a["key"] == "deep_wounds":
				target.auras.erase(a)
				break
		target.auras.append({"key": "deep_wounds", "kind": "dot", "per_tick": bleed / 4.0, "tick": 1.0,
			"next": t + 1.0, "until": t + 4.0, "school": "physical", "source": caster.id})
	if caster.flag("mana_leech") > 0.0:
		caster.mana = minf(caster.max_mana, caster.mana + amount * caster.flag("mana_leech"))

func _on_heal_crit(caster: Unit, target: Unit, sid: String, t: float) -> void:
	if caster.flag("illumination") > 0.0 and GameData.SPELLS.has(sid):
		caster.mana = minf(caster.max_mana, caster.mana + GameData.spell_cost(caster, sid) * caster.flag("illumination"))
	if caster.flag("inspiration") > 0.0:
		target.add_buff("inspiration", t + 10.0, {"dmg_taken": -caster.flag("inspiration")})

## Заморозка: цель покрывается льдом, не двигается и не атакует. Боссы — вдвое короче.
func _freeze(target: Unit, dur: float, t: float) -> void:
	if target.kind != "mob" or not target.alive:
		return
	if _is_boss(target):
		dur *= 0.5
	var was_frozen := target.is_frozen(t)
	target.freeze_until = maxf(target.freeze_until, t + dur)
	if not was_frozen:
		fx_at("frozen", target.pos, target.pos, dur, target.id)

## Баффы могут менять запас здоровья и маны — пересчитываем характеристики героя.
func _refresh_stats(u: Unit) -> void:
	if u.kind == "hero" and u.node and u.node.has_method("apply_level_stats"):
		u.node.apply_level_stats(false)

# ---------------------------------------------------------------- ярость, проки, автозаклинания

func gain_rage(u: Unit, amount: float, t: float) -> void:
	if u.resource != "rage":
		return
	u.mana = minf(u.max_mana, u.mana + amount)
	u.combat_until = t + 6.0

var _proc_cd: Dictionary = {}

## Проверка проков талантов: on = spell_hit | heal | auto | cast | hit_taken.
func _trigger_procs(u: Unit, target: Unit, on: String, sid: String, school: String, crit: bool, t: float) -> void:
	if u == null or u.kind != "hero" or u.mods.is_empty() or GameData.AUTO_SPELLS.has(sid):
		return
	for p in u.mods.get("procs", []):
		if p["on"] != on:
			continue
		if p.has("school") and p["school"] != school:
			continue
		if p.has("spells") and not p["spells"].has(sid):
			continue
		if p.get("crit", false) and not crit:
			continue
		var key := "%d:%s" % [u.id, p["id"]]
		if t < float(_proc_cd.get(key, 0.0)) or (randf() >= float(p["chance"]) and not Net.cli.has("procall")):
			continue
		_proc_cd[key] = t + 1.0
		if Net.cli.has("proclog"):
			print("PROC ", p["id"], " t=%.1f" % t)
		if p.has("buff"):
			u.add_buff(p["buff"], t + 15.0, {})
			fx_at("proc", u.pos, u.pos, 0.0, u.id)
		elif p.has("spell") and target:
			cast_auto_spell(u, p["spell"], target.pos, t)

var _bursts: Array = []

## Автозаклинание (Огненная глыба, Звезда Света…): эффект в точке с задержкой.
func cast_auto_spell(u: Unit, aid: String, pos: Vector3, t: float) -> void:
	var a: Dictionary = GameData.AUTO_SPELLS[aid]
	var center: Vector3 = u.pos if a.get("around_caster", false) else pos
	center.y = 0.0
	ev_fx.rpc(a["vfx"], center, u.pos, float(a["radius"]), u.id)
	_bursts.append({"at": t + float(a["delay"]), "caster": u.id, "pos": center, "aid": aid})

func _update_bursts(t: float) -> void:
	var i := 0
	while i < _bursts.size():
		var b: Dictionary = _bursts[i]
		if t < b["at"]:
			i += 1
			continue
		_bursts.remove_at(i)
		var caster: Unit = world.get_unit(b["caster"])
		if caster == null:
			continue
		var a: Dictionary = GameData.AUTO_SPELLS[b["aid"]]
		var c: Vector3 = b["pos"]
		for m in world.mobs.query_radius(Vector2(c.x, c.z), float(a["radius"])):
			apply_effects(caster, m, a.get("enemy_fx", []), b["aid"], a["school"])
		if a.has("ally_fx"):
			for h in world.heroes.values():
				if h.unit.alive and Vector2(h.unit.pos.x - c.x, h.unit.pos.z - c.z).length() <= float(a["radius"]):
					apply_effects(caster, h.unit, a["ally_fx"], b["aid"], a["school"])

## Копия заклинания с усиленными эффектами (для проков с усилением).
func _amplified(sp: Dictionary, mult: float) -> Dictionary:
	var c := sp.duplicate(true)
	for key in ["effects", "enemy_fx", "ally_fx", "impact_fx"]:
		for e in c.get(key, []):
			for f in ["min", "max", "total", "amount"]:
				if e.has(f):
					e[f] = float(e[f]) * mult
	return c

func _is_boss(u: Unit) -> bool:
	return GameData.MOBS.get(u.type_id, {}).get("boss", false)

## Урон с учётом неуязвимости, барьеров, талантов, брони и щитов.
func deal_damage(src: Unit, dst: Unit, amount: float, school: String, crit: bool) -> void:
	if dst == null or not dst.alive:
		return
	var t: float = world.now()
	var src_id := src.id if src else 0
	if t < dst.immune_until:
		world.fx_number(dst.id, 0.0, "immune", school, src_id, false)
		return
	amount *= dst.damage_taken_mult
	amount *= maxf(0.1, 1.0 + dst.mod("dmg_taken"))
	if dst.flag("ardent") > 0.0 and dst.hp < dst.max_hp * 0.35:
		amount *= 1.0 - dst.flag("ardent")
	if school == "physical":
		amount *= 1.0 - dst.armor
	if dst.absorb > 0.0 and t < dst.absorb_until:
		var soaked := minf(dst.absorb, amount)
		dst.absorb -= soaked
		amount -= soaked
		if amount <= 0.0:
			world.fx_number(dst.id, soaked, "absorb", school, src_id, false)
			return
	if dst.hp - amount <= 0.0 and dst.has_buff("guardian_spirit"):
		# Оберегающий дух спасает от смерти
		dst.remove_buff("guardian_spirit")
		dst.hp = dst.max_hp * 0.5
		world.fx_number(dst.id, 0.0, "saved", "holy", src_id, false)
		fx_at("heal_burst", dst.pos, dst.pos, 0.0, dst.id)
		return
	if src:
		src.stat_dmg += minf(amount, maxf(dst.hp, 0.0))
	dst.hp -= amount
	if src:
		dst.last_attacker = src.id
		src.combat_until = t + 6.0
	dst.combat_until = t + 6.0
	if dst.kind == "hero":
		if dst.resource == "rage":
			gain_rage(dst, amount / maxf(dst.max_hp, 1.0) * 60.0, t)
		_trigger_procs(dst, src, "hit_taken", "", school, false, t)
	world.fx_number(dst.id, amount, "dmg", school, src_id, crit)
	if dst.kind == "mob":
		world.mobs.on_damaged(dst, src)
	if dst.hp <= 0.0:
		dst.hp = 0.0
		_on_death(dst, src)

func heal(src: Unit, dst: Unit, amount: float, crit: bool) -> void:
	if dst == null or not dst.alive:
		return
	amount *= maxf(0.0, 1.0 + dst.mod("heal_taken"))
	var before := dst.hp
	dst.hp = minf(dst.max_hp, dst.hp + amount)
	world.fx_number(dst.id, dst.hp - before, "heal", "holy", src.id if src else 0, crit)
	if src:
		src.stat_heal += dst.hp - before
	# Частица Света: отмеченный союзник получает 40% чужого лечения
	if src and src.kind == "hero":
		var bid := int(hs.get(src.id, {}).get("beacon", 0))
		if bid != 0 and bid != dst.id:
			var b: Unit = world.get_unit(bid)
			if b and b.alive and b.has_buff("beacon"):
				var bb := b.hp
				b.hp = minf(b.max_hp, b.hp + amount * 0.4)
				world.fx_number(b.id, b.hp - bb, "heal", "holy", src.id, false)

func _on_death(dst: Unit, src: Unit) -> void:
	dst.alive = false
	var bombs: Array = dst.auras.filter(func(a): return a.has("explode"))
	dst.auras.clear()
	dst.buffs.clear()
	_refresh_stats(dst)
	for a in bombs:
		_explode(a, dst)
	match dst.kind:
		"mob":
			world.mobs.kill(dst, src)
		"hero":
			var h = world.heroes.get(dst.id, null)
			if h:
				h.respawn_at = world.now() + GameData.RESPAWN_BASE + dst.level * 0.6
				_interrupt(h)
				world.announce_all("%s погибает!" % h.player_name, Color(1, 0.5, 0.4))
				world.mode.on_hero_died(h)
		_:
			world.mode.on_unit_destroyed(dst)

# ---------------------------------------------------------------- таланты

@rpc("any_peer", "reliable")
func request_learn(tid: String) -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero == null:
		return
	var err := GameData.can_learn(hero.class_id, hero.talents, hero.unit.level, tid)
	if err != "":
		_feedback(hero.peer_id, "", err)
		return
	var ranks: Dictionary = hero.talents.duplicate()
	ranks[tid] = int(ranks.get(tid, 0)) + 1
	world.ev_talents.rpc(hero.hero_id, ranks)

@rpc("any_peer", "reliable")
func request_reset_talents() -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero:
		world.ev_talents.rpc(hero.hero_id, {})

func _dist(a: Unit, b: Unit) -> float:
	return Vector2(a.pos.x - b.pos.x, a.pos.z - b.pos.z).length()

# ---------------------------------------------------------------- визуальные события

func fx_at(kind: String, pos: Vector3, from: Vector3, param: float, unit_id: int) -> void:
	ev_fx.rpc(kind, pos, from, param, unit_id)

@rpc("authority", "call_local", "unreliable")
func ev_fx(kind: String, pos: Vector3, from: Vector3, param: float, unit_id: int) -> void:
	Vfx.spawn(world, kind, pos, from, param, unit_id)

@rpc("authority", "call_local", "unreliable")
func ev_projectile(kind: String, from_id: int, to_id: int, speed: float) -> void:
	Vfx.projectile(world, kind, from_id, to_id, speed)

@rpc("authority", "call_local", "reliable")
func ev_zone(id: int, kind: String, pos: Vector3, yaw: float, size: float, duration: float) -> void:
	Vfx.zone(world, id, kind, pos, yaw, size, duration)

@rpc("authority", "call_local", "reliable")
func ev_zone_end(id: int) -> void:
	Vfx.end_zone(world, id)
