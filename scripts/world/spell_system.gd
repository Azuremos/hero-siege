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

const RES_SHORTAGE := {"rage": "Недостаточно ярости", "focus": "Недостаточно концентрации", "mana": "Недостаточно маны"}
## Концентрация охотника восполняется сама: столько единиц в секунду (скорость — от haste).
const FOCUS_REGEN := 6.0

# ---------------------------------------------------------------- заряды (Перекат)
## st["charges"][sid] — когда восстановится каждый заряд. Заряд готов, если его время прошло.
func _charge_ready(st: Dictionary, sid: String, n: int, t: float) -> bool:
	var arr: Array = st.get("charges", {}).get(sid, [])
	if arr.size() < n:
		return true
	return arr.any(func(x): return float(x) <= t)

## Потратить заряд; вернуть, сколько ждать до следующего (0 — ещё есть готовый). Заряды копятся по очереди.
func _use_charge(st: Dictionary, sid: String, n: int, cd: float, t: float) -> float:
	if not st.has("charges"):
		st["charges"] = {}
	var arr: Array = st["charges"].get(sid, [])
	while arr.size() < n:
		arr.append(0.0)
	var latest := t
	for x in arr:
		latest = maxf(latest, float(x))
	for i in arr.size():
		if float(arr[i]) <= t:
			arr[i] = latest + cd
			break
	st["charges"][sid] = arr
	var soonest := INF
	for x in arr:
		if float(x) <= t:
			return 0.0
		soonest = minf(soonest, float(x))
	return soonest - t

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
	if t < u.silence_until or t < u.fear_until:
		return _feedback(peer, sid, "Сейчас нельзя: вы под контролем")
	# во льду Ледяной гробницы можно бить только саму гробницу (иначе одиночке не выбраться)
	if u.has_buff("ice_tomb"):
		var tomb: Unit = world.get_unit(target_id)
		if sp["target"] != "enemy" or tomb == null or tomb.type_id != "ice_tomb":
			return _feedback(peer, sid, "Вы во льду — разбейте гробницу")
	if not st["cast"].is_empty():
		return _feedback(peer, sid, "Вы уже произносите заклинание")
	var proc := GameData.active_proc(u, sid)
	var not_ready := t < float(st["cds"].get(sid, 0.0))
	if sp.has("charges"):
		not_ready = not _charge_ready(st, sid, int(sp["charges"]), t)
	if not_ready and not (not proc.is_empty() and proc["data"].get("reset_cd", false)):
		return _feedback(peer, sid, "Заклинание ещё не готово")
	if t < st["gcd"] - 0.15 and not sp.get("no_gcd", false):
		return
	if u.mana < GameData.eff_mana(u, sid):
		return _feedback(peer, sid, RES_SHORTAGE.get(u.resource, "Недостаточно маны"))
	var perr: String = world.mobs.pet_spell_error(hero, sp)
	if perr != "":
		return _feedback(peer, sid, perr)
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
			if tu == null or not tu.alive or tu.team != u.team or not (tu.kind == "hero" or tu.kind == "pet"):
				target_id = u.id
			elif _dist(u, tu) > max_range + 2.0:
				return _feedback(peer, sid, "Цель слишком далеко")
		"any":
			var tu: Unit = world.get_unit(target_id)
			if tu == null or not tu.alive or (tu.team == u.team and tu.kind != "hero"):
				target_id = u.id
			elif _dist(u, tu) > max_range + tu.radius + 1.5:
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
	if not sp.get("no_gcd", false):     # прерывания, как в WoW, не тратят общую перезарядку
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
			if u.is_stunned(t) or (u.pos.distance_to(c["start_pos"]) > 0.8 and not can_cast_moving(u)):
				_interrupt(hero)
			elif c.get("channel", false):
				_channel_tick(hero, st, c, t)
			elif t >= c["end"]:
				st["cast"] = {}
				_complete_cast(hero, c["sid"], c["target"], c["ground"], c["yaw"], float(c.get("length", 0.0)))
		_auto_attack(hero, st, t)

	_update_projectiles(t)
	_update_traps(t)
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
			if u.resource == "focus":
				u.mana = minf(u.max_mana, u.mana + FOCUS_REGEN * 0.5 * (1.0 + u.mod("haste")))
			elif u.resource == "rage":
				# ярость не восполняется сама и угасает вне боя
				if t > u.combat_until:
					u.mana = maxf(0.0, u.mana - 1.5)
			else:
				# в секунду: запас × 3% + Дух × 0,6 вне боя; в бою — 50%, в бою после траты маны 5 с — 20%
				var per_s := u.max_mana * GameData.MANA_REGEN_POOL + u.spirit * GameData.MANA_REGEN_SPIRIT
				if t < u.combat_until:
					per_s *= GameData.CASTING_REGEN if t - u.mana_spent_at < GameData.FIVE_SECOND_RULE else GameData.COMBAT_REGEN
				u.mana = minf(u.max_mana, u.mana + per_s * 0.5 * (1.0 + u.mod("regen")) * rest)
			u.hp = minf(u.max_hp, u.hp + (u.max_hp * 0.0025 + u.spirit * 0.05) * rest)
			if u.flag("spirit_bond") > 0.0:       # Духовная связь: доля здоровья каждые 2 сек.
				u.hp = minf(u.max_hp, u.hp + u.max_hp * u.flag("spirit_bond") * 0.25)
	_update_bursts(t)
	_send_watched_effects(delta, t)

## Бафф с cast_move в BUFF_INFO (Благосклонность предков): произнесение не сбивается движением.
static func can_cast_moving(u: Unit) -> bool:
	for b in u.buffs:
		if GameData.BUFF_INFO.get(b["key"], {}).get("cast_move", false):
			return true
	return false

## Списать ману (или ярость). Трата маны запускает правило 5 секунд: восполнение в бою ниже.
func _spend_mana(u: Unit, cost: float, t: float) -> void:
	u.mana -= cost
	if cost > 0.0 and u.resource == "mana":
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
	if _dist(u, tu) > float(auto["range"]) + tu.radius or u.is_stunned(t) or (u.has_buff("ice_tomb") and tu.type_id != "ice_tomb"):
		return
	st["auto_ready"] = t + float(auto["speed"]) * maxf(0.5, 1.0 - u.mod("haste"))
	var fx := [{"type": "damage", "min": auto["min"], "max": auto["max"]}]
	if auto["ranged"]:
		_launch_projectile(u, tu, fx, "auto", auto["school"], 40.0, auto.get("vfx", "bolt_" + auto["school"]), t)
		ev_action.rpc(u.id, auto.get("anim", "wand"))
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
	if world.mobs.pet_spell_error(hero, sp) != "":
		ev_cast_end.rpc(u.id, "", false)
		return
	var mana_cost := GameData.eff_mana(u, sid)
	if u.has_buff("clearcasting") and float(sp["mana"]) > 0.0 and u.resource == "mana":
		u.remove_buff("clearcasting")
	_spend_mana(u, mana_cost, world.now())
	if sp.has("target_lockout") and tu:
		tu.add_buff(sp["target_lockout"]["key"], t + float(sp["target_lockout"]["dur"]), {})
	var cd := GameData.eff_cd(u, sid)
	if sp.has("charges"):
		cd = _use_charge(st, sid, int(sp["charges"]), cd, t)     # Перекат: на кнопке — ожидание следующего заряда
		st["cds"][sid] = t + cd
	elif cd > 0.0:
		st["cds"][sid] = t + cd
	if sp.has("focus_gain") and u.resource == "focus":
		u.mana = minf(u.max_mana, u.mana + float(sp["focus_gain"]))
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

	# self_fx — эффекты на самого заклинателя вдобавок к основным (Щит праведности: удар + блок)
	if sp.has("self_fx"):
		apply_effects(u, u, sp["self_fx"], sid, school)
	match sp["delivery"]:
		"projectile":
			_launch_projectile(u, tu, sp["effects"], sid, school, float(sp["speed"]), sp["vfx"], t)
			st["auto_target"] = tu.id
			# прок с extra_targets (Ледяные пальцы): снаряд летит ещё в ближайших врагов рядом с целью
			var extra := int(proc["data"].get("extra_targets", 0)) if not proc.is_empty() else 0
			extra += int(u.flag("extra:" + sid))      # легендарки: Посох Пепельного Шторма, Лук Северного Ветра
			if extra > 0 and tu.kind == "mob":
				for m: Unit in world.mobs.query_radius(Vector2(tu.pos.x, tu.pos.z), 10.0):
					if extra <= 0:
						break
					if m != tu:
						_launch_projectile(u, m, sp["effects"], sid, school, float(sp["speed"]), sp["vfx"], t)
						extra -= 1
		"instant":
			if sp["target"] == "enemy":
				st["auto_target"] = tu.id
			var ifx: Array = sp.get("effects", [])
			if sp["target"] == "any":
				# Шок небес, Покаяние: по врагу — урон, по союзнику — лечение
				ifx = sp["enemy_fx"] if tu.team != u.team else sp["ally_fx"]
			apply_effects(u, tu, ifx, sid, school)
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
			if sp.get("from_totems", false):
				# Кольцо огня: то же вокруг каждого своего тотема
				for zid in zones:
					var tz: Dictionary = zones[zid]
					if tz.has("totem") and tz["caster"] == u.id:
						var tc: Vector3 = tz["pos"]
						for m in world.mobs.query_radius(Vector2(tc.x, tc.z), radius):
							apply_effects(u, m, sp.get("enemy_fx", []), sid, school)
						fx_at(sp["vfx"], tc, tc, radius, 0)
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
			if sp.has("start_fx"):
				# Смещение: малое Кольцо льда на месте старта
				for m in world.mobs.query_radius(Vector2(u.pos.x, u.pos.z), float(sp.get("start_radius", 5.0))):
					apply_effects(u, m, sp["start_fx"], sid, school)
			if sp.has("trail"):
				# Огненный рывок: полоса огня по всему пути, как Стена огня
				var f: float = hero.rotation.y
				var a3 := Vector3(u.pos.x, 0, u.pos.z)
				var b3 := a3 + Vector3(-sin(f), 0, -cos(f)) * dist
				var tw := float(sp["trail"]["radius"])
				_add_zone({"sid": sid, "kind": "line", "pos": (a3 + b3) * 0.5, "a": a3, "b": b3, "width": tw,
					"reach": dist * 0.5 + tw, "caster": u.id, "until": t + float(sp["trail"]["dur"]), "tick": float(sp["tick"]),
					"next": t + 0.05, "ally_dr": 0.0}, sp["trail"]["vfx"], f + PI * 0.5, dist, float(sp["trail"]["dur"]))
			if sp.get("back", false):
				dist = -dist
			if sp.has("effects"):
				apply_effects(u, u, sp["effects"], sid, school)
			fx_at("blink", u.pos, u.pos, 0.0, u.id)
			if hero.peer_id == multiplayer.get_unique_id():
				hero.ev_blink(dist)
			else:
				hero.ev_blink.rpc_id(hero.peer_id, dist)
		"cone":
			# конус перед героем: враги — enemy_fx, союзники — ally_fx
			var facing: float = hero.rotation.y
			var fwd2 := Vector2(-sin(facing), -cos(facing))
			var half := deg_to_rad(float(sp.get("angle", 90.0))) * 0.5
			for m in world.mobs.query_radius(Vector2(u.pos.x, u.pos.z), radius):
				var to := Vector2(m.pos.x - u.pos.x, m.pos.z - u.pos.z)
				if to.length() < 1.0 or absf(fwd2.angle_to(to.normalized())) <= half:
					apply_effects(u, m, sp.get("enemy_fx", []), sid, school)
			if sp.has("ally_fx"):
				for h in world.heroes.values():
					var to2 := Vector2(h.unit.pos.x - u.pos.x, h.unit.pos.z - u.pos.z)
					if h.unit.alive and to2.length() <= radius and (to2.length() < 1.0 or absf(fwd2.angle_to(to2.normalized())) <= half):
						apply_effects(u, h.unit, sp["ally_fx"], sid, school)
			fx_at(sp["vfx"], u.pos + Vector3(fwd2.x, 0, fwd2.y) * radius * 0.5, u.pos, radius * 0.6, u.id)
		"line":
			# полоса вперёд от героя (Чародейская сфера, Божественная звезда)
			var facing: float = hero.rotation.y
			var dir3 := Vector3(-sin(facing), 0, -cos(facing))
			var a2 := Vector2(u.pos.x, u.pos.z)
			var b2 := a2 + Vector2(dir3.x, dir3.z) * float(sp.get("length", 30.0))
			var w := float(sp.get("width", 3.0)) * 0.5
			for m in world.mobs.query_radius((a2 + b2) * 0.5, a2.distance_to(b2) * 0.5 + w + 1.0):
				if Geometry2D.get_closest_point_to_segment(Vector2(m.pos.x, m.pos.z), a2, b2).distance_to(Vector2(m.pos.x, m.pos.z)) <= w + m.radius:
					apply_effects(u, m, sp.get("enemy_fx", []), sid, school)
			if sp.has("ally_fx"):
				for h in world.heroes.values():
					var hp2 := Vector2(h.unit.pos.x, h.unit.pos.z)
					if h.unit.alive and Geometry2D.get_closest_point_to_segment(hp2, a2, b2).distance_to(hp2) <= w + 1.0:
						apply_effects(u, h.unit, sp["ally_fx"], sid, school)
			fx_at("charge_trail", Vector3(b2.x, 0, b2.y), u.pos, 0.0, u.id)
			fx_at(sp["vfx"], Vector3(b2.x, 0, b2.y), u.pos, 2.0, 0)
		"target_aoe":
			# цель и враги рядом с ней (Молот праведника, Замедление)
			var n := 0
			var max_n := int(sp.get("max_targets", 99))
			apply_effects(u, tu, sp["effects"], sid, school)
			for m in world.mobs.query_radius(Vector2(tu.pos.x, tu.pos.z), radius):
				if m != tu and n < max_n - 1:
					n += 1
					apply_effects(u, m, sp["effects"], sid, school)
			st["auto_target"] = tu.id
			fx_at(sp["vfx"], tu.pos, u.pos, radius, tu.id)
		"leap":
			# прыжок в точку: герой переносится, удар при приземлении
			var dest := Vector3(ground.x, 0, ground.z)
			if hero.peer_id == multiplayer.get_unique_id():
				hero.ev_dash(dest)
			else:
				hero.ev_dash.rpc_id(hero.peer_id, dest)
			for m in world.mobs.query_radius(Vector2(dest.x, dest.z), radius):
				apply_effects(u, m, sp.get("enemy_fx", []), sid, school)
			fx_at(sp["vfx"], dest, u.pos, radius, 0)
		"auto_spell":
			# заклинание-глыба: падает в точку с задержкой (Огненная глыба)
			cast_auto_spell(u, sp["auto"], Vector3(ground.x, 0, ground.z), t)
		"pull_ally":
			# Прыжок веры: союзник прилетает к жрецу
			if tu and tu != u and tu.kind == "hero":
				var ph = world.heroes.get(tu.id, null)
				if ph:
					tu.knock_until = t + 0.45
					ph.ev_knock.rpc(u.pos + (tu.pos - u.pos).normalized() * 2.0)
				apply_effects(u, tu, sp.get("effects", []), sid, school)
			fx_at(sp["vfx"], tu.pos if tu else u.pos, u.pos, 0.0, tu.id if tu else u.id)
		"dash_ally":
			# Вмешательство: рывок к союзнику и защита
			if tu and tu != u:
				var dest2: Vector3 = tu.pos + (u.pos - tu.pos).normalized() * 1.5
				if hero.peer_id == multiplayer.get_unique_id():
					hero.ev_dash(dest2)
				else:
					hero.ev_dash.rpc_id(hero.peer_id, dest2)
			if tu:
				apply_effects(u, tu, sp.get("effects", []), sid, school)
				fx_at(sp["vfx"], tu.pos, u.pos, 0.0, tu.id)
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
		"trap":
			_place_trap(u, sid, sp, Vector3(ground.x, 0, ground.z), t)
		"totem":
			_place_totem(hero, sid, sp, t)
		"pet_call":
			world.mobs.pet_summon(hero, false)
		"pet_revive":
			world.mobs.pet_summon(hero, true)
		"pet_strike":
			# Команда «Взять!»: питомец бросается на цель, удар считается от охотника (его сила и таланты)
			var pet: Unit = world.mobs.pet_of(hero.hero_id)
			if pet:
				world.mobs.pet_command(hero, "attack", tu.id)
				apply_effects(u, tu, sp["effects"], sid, school)
				fx_at(sp["vfx"], tu.pos, pet.pos, 0.0, tu.id)
				st["auto_target"] = tu.id
	# эффекты на своего питомца (Лечение питомца, Звериный гнев, Бодрость)
	if sp.has("pet_fx"):
		var mypet: Unit = world.mobs.pet_of(hero.hero_id)
		if mypet:
			apply_effects(u, mypet, sp["pet_fx"], sid, school)
			fx_at("heal_small" if sid == "mend_pet" else "proc", mypet.pos, u.pos, 0.0, mypet.id)
	# Молот Рассвета: Правосудие оставляет под целью освящённую землю (как Освящение паладина)
	if sid == "judgement" and tu and u.flag("judgement_ground") > 0.0:
		var cs: Dictionary = GameData.SPELLS["consecration"]
		var cr := float(cs["radius"])
		_add_zone({"sid": "consecration", "kind": "circle", "pos": Vector3(tu.pos.x, 0, tu.pos.z), "radius": cr, "reach": cr, "caster": u.id,
			"until": t + float(cs["duration"]), "tick": float(cs["tick"]), "next": t + 0.05, "ally_dr": 0.0}, cs["vfx"], 0.0, cr, float(cs["duration"]))

# ---------------------------------------------------------------- ловушки охотника
## Ловушка лежит на земле до life сек., срабатывает, когда враг подходит на trigger м: эффекты enemy_fx всем
## в radius м (или зона горения trap.zone). Не больше MAX_TRAPS на охотника — новая заменяет самую старую.
const MAX_TRAPS := 3
var traps: Array = []       # {id, caster, sid, pos, until, arm}
var _next_trap := 1

func _place_trap(u: Unit, sid: String, sp: Dictionary, pos: Vector3, t: float) -> void:
	# ловушку ставят под ноги, не дальше 5 м
	var to := Vector2(pos.x - u.pos.x, pos.z - u.pos.z)
	if to.length() > 5.0:
		to = to.normalized() * 5.0
	pos = Vector3(u.pos.x + to.x, 0, u.pos.z + to.y)
	var mine: Array = traps.filter(func(tr): return tr["caster"] == u.id)
	if mine.size() >= MAX_TRAPS:
		_remove_trap(mine[0])
	var id := _next_trap
	_next_trap += 1
	traps.append({"id": id, "caster": u.id, "sid": sid, "pos": pos, "until": t + float(sp["trap"]["life"]), "arm": t + 1.0})
	ev_trap.rpc(id, str(sp["trap"]["vfx"]), pos, true)

func _remove_trap(tr: Dictionary) -> void:
	traps.erase(tr)
	ev_trap.rpc(int(tr["id"]), "", tr["pos"], false)

func _update_traps(t: float) -> void:
	for tr: Dictionary in traps.duplicate():
		if t >= float(tr["until"]):
			_remove_trap(tr)
			continue
		if t < float(tr["arm"]):
			continue
		var sp: Dictionary = GameData.SPELLS[tr["sid"]]
		var p: Vector3 = tr["pos"]
		if world.mobs.query_radius(Vector2(p.x, p.z), float(sp["trap"]["trigger"])).is_empty():
			continue
		var caster: Unit = world.get_unit(int(tr["caster"]))
		_remove_trap(tr)
		if caster == null:
			continue
		_trigger_trap(caster, tr["sid"], sp, p, t)

func _trigger_trap(u: Unit, sid: String, sp: Dictionary, p: Vector3, t: float) -> void:
	var tp: Dictionary = sp["trap"]
	var power := 1.0 + u.flag("trap_power")
	var fx: Array = _amplified(sp, power)["enemy_fx"] if power > 1.0 else sp["enemy_fx"]
	if power > 1.0:
		fx = fx.duplicate(true)
		for e in fx:
			if e["type"] in ["freeze", "stun", "root", "incapacitate"]:
				e["dur"] = float(e["dur"]) * power
	var r := float(tp["radius"])
	if tp.has("zone"):
		# Обжигающая ловушка: горящая земля, как Огненный столб
		var z: Dictionary = tp["zone"]
		_add_zone({"sid": sid, "kind": "circle", "pos": p, "radius": r, "reach": r, "caster": u.id,
			"until": t + float(z["dur"]) * power, "tick": float(z["tick"]), "next": t + 0.05, "ally_dr": 0.0}, z["vfx"], 0.0, r, float(z["dur"]) * power)
	else:
		for m in world.mobs.query_radius(Vector2(p.x, p.z), r):
			apply_effects(u, m, fx, sid, sp["school"])
		fx_at(sp["vfx"], p, p, r, 0)
	if u.flag("entrapment") > 0.0:
		for m in world.mobs.query_radius(Vector2(p.x, p.z), r):
			apply_effects(u, m, [{"type": "root", "dur": u.flag("entrapment")}], sid, sp["school"])
	ev_sound.rpc("trap", p)

# ---------------------------------------------------------------- тотемы шамана
## Тотем — зона у ног шамана (как Освящение), но со стихией: у каждого шамана одновременно по одному тотему
## огня, земли, воды и воздуха, новый той же стихии заменяет старый. Тики — в _update_zones: enemy_fx всем
## врагам в радиусе или (shoot) ближайшим врагам лучом от тотема; ally_fx — союзникам в радиусе
## (короткие баффы тотема продлеваются, пока союзник рядом). Без нод и физики на сервере, по сети — как зоны.
## Смещение тотема от шамана по стихии: [вправо, вперёд] в метрах — чтобы четыре тотема не стояли в одной точке.
const TOTEM_SLOTS := {"fire": Vector2(1.2, 1.0), "earth": Vector2(-1.2, 1.0), "water": Vector2(1.2, -1.0), "air": Vector2(-1.2, -1.0)}

func _place_totem(hero, sid: String, sp: Dictionary, t: float) -> void:
	var u: Unit = hero.unit
	var tp: Dictionary = sp["totem"]
	var el: String = tp["element"]
	for zid in zones.keys():
		if str(zones[zid].get("totem", "")) == el and zones[zid]["caster"] == u.id:
			_end_zone(zid)
	var off: Vector2 = TOTEM_SLOTS.get(el, Vector2.ZERO)
	var f: float = hero.rotation.y
	var right := Vector3(cos(f), 0, -sin(f))
	var fwd := Vector3(-sin(f), 0, -cos(f))
	var pos := Vector3(u.pos.x, 0, u.pos.z) + right * off.x + fwd * off.y
	var life := float(tp["life"]) * (1.0 + u.flag("totem_dur"))
	var radius := float(sp["radius"]) + u.mod("radius_add", sid, sp["school"])
	_add_zone({"sid": sid, "kind": "circle", "pos": pos, "radius": radius, "reach": radius, "caster": u.id,
		"until": t + life, "tick": float(sp["tick"]), "next": t + 0.3, "ally_dr": 0.0, "totem": el}, sp["vfx"], f, radius, life)
	ev_sound.rpc("totem", pos)

## Убрать зону раньше срока (тотем заменён новым): у клиентов она гаснет.
func _end_zone(zid: int) -> void:
	zones.erase(zid)
	ev_zone_end.rpc(10000 + zid)

## Тик тотема: стрельба по ближайшим врагам (shoot) и союзные эффекты с продлением баффов.
func _totem_tick(z: Dictionary, caster: Unit, sp: Dictionary, t: float) -> void:
	var sid: String = z["sid"]
	var school: String = sp["school"]
	var center: Vector3 = z["pos"]
	var power := 1.0 + caster.flag("totem_power")
	var tsp: Dictionary = _amplified(sp, power) if power > 1.0 else sp
	var shoot := int(sp["totem"].get("shoot", 0))
	if tsp.has("enemy_fx"):
		var near: Array = world.mobs.query_radius(Vector2(center.x, center.z), float(z["radius"]))
		if shoot > 0:
			near.sort_custom(func(a, b): return a.pos.distance_squared_to(center) < b.pos.distance_squared_to(center))
			near = near.slice(0, shoot)
		for m: Unit in near:
			apply_effects(caster, m, tsp["enemy_fx"], sid, school)
			if shoot > 0:
				fx_at("chain_" + school, m.pos, center + Vector3(0, 0.6, 0), 0.0, m.id)
	if tsp.has("ally_fx"):
		for h in world.heroes.values():
			if not h.unit.alive or not _in_zone(z, h.unit):
				continue
			for e: Dictionary in tsp["ally_fx"]:
				if e["type"] == "buff" and h.unit.has_buff(e["key"]):
					for b in h.unit.buffs:
						if b["key"] == e["key"]:
							b["until"] = maxf(float(b["until"]), t + float(e["dur"]))
					continue
				apply_effects(caster, h.unit, [e], sid, school)

@rpc("authority", "call_local", "reliable")
func ev_trap(id: int, kind: String, pos: Vector3, on: bool) -> void:
	Vfx.trap(world, id, kind, pos, on)

@rpc("authority", "call_local", "unreliable")
func ev_sound(name: String, pos: Vector3) -> void:
	Sfx.play_at(name, pos + Vector3(0, 0.5, 0))

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
		if z.has("totem"):
			_totem_tick(z, caster, sp, t)
			continue
		var center: Vector3 = z["pos"]
		for m in world.mobs.query_radius(Vector2(center.x, center.z), float(z["reach"]) + 1.5):
			if _in_zone(z, m):
				apply_effects(caster, m, sp.get("enemy_fx", []), z["sid"], sp["school"])
		if sp.has("ally_fx"):
			# зона лечения (Святое слово: Святилище)
			for h in world.heroes.values():
				if h.unit.alive and _in_zone(z, h.unit):
					apply_effects(caster, h.unit, sp["ally_fx"], z["sid"], sp["school"])
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
	_tick_auras_for(world.mobs.pet_units(), t)

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
					deal_damage(src, u, a["per_tick"], a["school"], false, a["key"])
					if a.get("procs", false) and src and u.alive:
						_trigger_procs(src, u, "spell_hit", a["key"], a["school"], false, t)
				elif a["kind"] == "pulse":
					if src:
						for m in world.mobs.query_radius(Vector2(u.pos.x, u.pos.z), float(a["radius"])):
							apply_effects(src, m, a["effects"], a["sid"], a["school"])
						fx_at(str(a.get("vfx", "whirl")), u.pos, u.pos, float(a["radius"]), u.id)
				else:
					heal(src, u, a["per_tick"], false, a["key"])
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
		deal_damage(src, m, randf_range(ex["min"], ex["max"]), "fire", false, "living_bomb")
	fx_at("explosion_fire", u.pos, u.pos, float(ex["radius"]), 0)

# ---------------------------------------------------------------- эффекты

func _m(u: Unit, key: String, sid: String = "", school: String = "") -> float:
	return u.mod(key, sid, school) if u else 0.0

## Неудержимый элитный не поддаётся контролю (кроме замедления).
const CONTROL_TYPES := ["stun", "freeze", "fear", "knockback", "root", "chill"]

## Помощь союзнику в бою (лечение, щит, бафф) вводит в бой и помогающего — как в WoW.
## Иначе лекарь за спинами считался бы вне боя и восполнял ману полностью.
func join_combat(helper: Unit, ally: Unit, t: float) -> void:
	if helper and ally and helper != ally and helper.kind == "hero" and ally.kind == "hero" and t < ally.combat_until:
		helper.combat_until = maxf(helper.combat_until, t + GameData.COMBAT_TIME)

func apply_effects(caster: Unit, target: Unit, effects: Array, sid: String, school: String) -> void:
	var t: float = world.now()
	var pw := 1.0
	if caster:
		pw = caster.phys_power if school == "physical" else caster.power
	var amp := _m(caster, "amount", sid, school)
	var crit_chance := (caster.crit_base if caster else 0.05) + _m(caster, "crit", sid, school)
	join_combat(caster, target, t)
	if caster and target.is_rooted(t):
		crit_chance += caster.flag("shatter")
	for e: Dictionary in effects:
		if not target.alive:
			return
		if (target.affixes.has("unstoppable") or target.has_buff("berserker")) and CONTROL_TYPES.has(e["type"]) and not (caster and caster.team == target.team):
			world.fx_number(target.id, 0.0, "immune", school, caster.id if caster else 0, false)
			continue
		match e["type"]:
			"damage":
				var mult := 1.0 + amp + _m(caster, "dmg")
				if sid == "auto":
					mult += _m(caster, "auto")
				var amount := randf_range(e["min"], e["max"]) * pw * maxf(0.1, mult)
				if e.has("frozen_bonus") and target.is_rooted(t):
					amount *= 1.0 + float(e["frozen_bonus"])
				var cc := crit_chance + (caster.mod("fire_crit") if caster and school == "fire" else 0.0)       # Возгорание
				var crit := randf() < cc
				if e.has("crit_if") and target.auras.any(func(a): return a["key"] == e["crit_if"]):
					crit = true      # Выброс лавы по цели с Огненным шоком
				if crit:
					amount *= 1.5
				deal_damage(caster, target, amount, school, crit, sid)
				# Рассекающий удар: удары воина задевают ещё двух врагов рядом
				if caster and caster.kind == "hero" and caster.has_buff("sweeping") and school == "physical" and not sid.begins_with("sweep"):
					var extra := 0
					for m in world.mobs.query_radius(Vector2(target.pos.x, target.pos.z), 5.0):
						if m != target and extra < 2:
							extra += 1
							deal_damage(caster, m, amount * 0.6, school, false, "sweep:" + sid)
				if caster and caster.kind == "hero":
					_on_damage_dealt(caster, target, amount, school, crit, t)
					if sid == "auto":
						if crit:
							_trigger_procs(caster, target, "auto_crit", sid, school, true, t)   # критическая автоатака
					else:
						_trigger_procs(caster, target, "spell_hit", sid, school, crit, t)
			"heal":
				var amount := randf_range(e["min"], e["max"]) * pw * (caster.heal_mult if caster else 1.0) * (1.0 + amp + _m(caster, "heal"))
				var crit := randf() < crit_chance
				if crit:
					amount *= 1.5
				heal(caster, target, amount, crit, sid)
				if crit and caster:
					_on_heal_crit(caster, target, sid, t)
				if caster:
					_trigger_procs(caster, target, "heal", sid, school, crit, t)
			"heal_self_pct":
				if caster:
					heal(caster, caster, caster.max_hp * float(e["pct"]), false, sid)
			"heal_pct":
				heal(caster, target, target.max_hp * float(e["pct"]), false, sid)
			"slow":
				if target.kind != "castle":
					var pct := minf(0.9, float(e["pct"]) + _m(caster, "slow_add", sid, school))
					target.slow_pct = maxf(pct, target.slow_pct if t < target.slow_until else 0.0)
					target.slow_until = maxf(target.slow_until, t + float(e["dur"]))
					_mark_src(target, "slowed", caster)
			"root":
				target.root_until = maxf(target.root_until, t + float(e["dur"]))
				_mark_src(target, "rooted", caster)
				fx_at("rooted", target.pos, target.pos, float(e["dur"]), target.id)
			"freeze":
				_mark_src(target, "frozen", caster)
				if target.kind == "mob":
					world.mobs.stop_cast(target)
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
					_mark_src(target, "chill", caster)
					_mark_src(target, "frozen", caster)
					if target.chill >= int(e["stacks"]):
						target.chill = 0
						_freeze(target, float(e["dur"]), t)
			"stun":
				var dur := (float(e["dur"]) + _m(caster, "stun_add", sid, school)) * (0.5 if target.kind == "mob" and _is_boss(target) else 1.0)
				target.stun_until = maxf(target.stun_until, t + dur)
				_mark_src(target, "stunned", caster)
				if e.has("key"):
					target.add_buff(e["key"], t + dur, {})      # «Очарован» и т.п. — своё название в рамке
				if target.kind == "mob":
					world.mobs.stop_cast(target)
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
				if e.get("procs", false):
					aura["procs"] = true      # тики — попадание заклинания для проков (Огненный шок → Волна лавы)
				if e.has("explode"):
					var ex: Dictionary = e["explode"]
					aura["explode"] = {"radius": ex["radius"], "min": float(ex["min"]) * pw * boost, "max": float(ex["max"]) * pw * boost}
					fx_at("bomb_mark", target.pos, target.pos, float(e["dur"]), target.id)
				target.auras.append(aura)
			"absorb":
				var amount := float(e.get("amount", 0.0)) * pw * (1.0 + amp + _m(caster, "heal"))
				if e.has("pct_max"):
					amount = target.max_hp * float(e["pct_max"]) * (1.0 + amp)
				target.absorb = maxf(target.absorb if t < target.absorb_until else 0.0, amount)
				target.absorb_until = t + float(e["dur"])
			"immune":
				target.immune_until = t + float(e["dur"])
				target.auras = target.auras.filter(func(a): return a["kind"] != "dot")
			"mana_burn":
				# выжигание маны: сгорает мана, половина сгоревшего — урон тьмой
				if target.kind == "hero" and target.resource == "mana":
					var burn := minf(target.mana, float(e["amount"]) * pw)
					target.mana -= burn
					if burn > 0.0:
						deal_damage(caster, target, burn * 0.5, "shadow", false, sid)
						world.fx_number(target.id, burn, "mana_burn", "shadow", caster.id if caster else 0, false)
			"mana_burn_pct":
				# выжигание доли запаса маны (Буря Скверны); ярость воина не трогает
				if target.kind == "hero" and target.resource == "mana":
					var pburn := minf(target.mana, target.max_mana * float(e["pct"]))
					target.mana -= pburn
					if pburn > 0.0:
						world.fx_number(target.id, pburn, "mana_burn", "shadow", caster.id if caster else 0, false)
			"knockback":
				_knockback(caster, target, float(e["dist"]), t)
			"incapacitate":
				# превращение, ослепление: враг выключен, но урон снимает эффект (боссы — вдвое короче)
				if target.kind == "mob":
					var idur := float(e["dur"]) * (0.5 if _is_boss(target) else 1.0)
					target.stun_until = maxf(target.stun_until, t + idur)
					target.incap = true
					_mark_src(target, "stunned", caster)
					world.mobs.stop_cast(target)
					fx_at("stunned", target.pos, target.pos, idur, target.id)
			"cleanse":
				# снять замедление и обездвиживание
				target.slow_until = 0.0
				target.root_until = 0.0
			"rage":
				gain_rage(target, float(e["amount"]), t)
			"reset_cds":
				# Готовность: все заклинания, кроме самой Готовности, сразу готовы
				var rh = world.heroes.get(target.id, null)
				if rh:
					var rst := _hstate(target.id)
					for k in rst["cds"].keys():
						if k != sid:
							rst["cds"][k] = 0.0
							_feedback(rh.peer_id, k, "", -1.0, 0.0)
					rst.erase("charges")
			"mana_return_pct":
				if caster and caster.resource == "mana":
					caster.mana = minf(caster.max_mana, caster.mana + caster.max_mana * float(e["pct"]))
			"mana_pct":
				# цель восполняет долю запаса маны (Тотем прилива маны, Гром и молния); ярость и концентрацию не трогает
				if target.resource == "mana" and target.max_mana > 0.0:
					target.mana = minf(target.max_mana, target.mana + target.max_mana * float(e["pct"]))
			"hot_pct":
				# лечение долей здоровья со временем (Безудержное восстановление)
				var n_ticks := float(e["dur"]) / float(e["tick"])
				target.auras.append({"key": e.get("key", sid), "kind": "hot", "per_tick": target.max_hp * float(e["pct"]) / n_ticks,
					"tick": float(e["tick"]), "next": t + float(e["tick"]), "until": t + float(e["dur"]), "school": school, "source": caster.id if caster else 0})
			"drop_aggro":
				# враги вокруг бросают заклинателя (Зеркальные копии)
				# dur — столько сек. враги не выбирают его целью и не отвечают на его удары
				target.unseen_until = maxf(target.unseen_until, t + float(e.get("dur", 0.0)))
				world.mobs.drop_aggro_on(target, float(e.get("radius", 30.0)))
				if e.get("copies", false):
					fx_at("mirror_copies", target.pos, target.pos, float(e.get("dur", 6.0)), target.id)
			"pulse":
				# аура, которая каждые tick сек. бьёт врагов вокруг носителя (Вихрь клинков)
				target.auras.append({"key": e.get("key", sid), "kind": "pulse", "per_tick": 0.0, "tick": float(e["tick"]),
					"next": t + float(e["tick"]), "until": t + float(e["dur"]), "school": school, "source": caster.id if caster else 0,
					"radius": float(e["radius"]), "effects": e["effects"], "sid": sid, "vfx": str(e.get("vfx", "whirl"))})
			"fear":
				if e.has("only") and target.kind == "mob" and not e["only"].has(GameData.MOBS.get(target.type_id, {}).get("faction", "")):
					continue        # Изгнание зла — только нежить и демоны
				if target.kind == "hero":
					target.fear_until = maxf(target.fear_until, t + float(e["dur"]))
					target.fear_from = caster.pos if caster else target.pos
					var fh = world.heroes.get(target.id, null)
					if fh:
						fh.ev_control.rpc("fear", float(e["dur"]), target.fear_from)
				else:
					target.stun_until = maxf(target.stun_until, t + float(e["dur"]))
			"silence":
				target.silence_until = maxf(target.silence_until, t + float(e["dur"]))
				if target.kind == "mob":
					world.mobs.stop_cast(target)
			"steal_gold":
				var vh = world.heroes.get(target.id, null)
				if vh and caster and caster.kind == "mob":
					var g := mini(vh.gold, int(float(e["amount"]) * (1.0 + 0.1 * float(caster.level))))
					vh.gold -= g
					world.mobs.on_steal(caster, vh, g)
			"interrupt":
				# сбить каст врага; школа заклинания заблокирована на lock сек.
				if target.kind == "mob" and world.mobs.interrupt(target, float(e.get("lock", 4.0))) and caster:
					world.meter.on_interrupt(caster, target)
					_trigger_procs(caster, target, "interrupt", sid, school, false, t)
			"buff":
				target.add_buff(e["key"], t + float(e["dur"]), e.get("mods", {}))
				if e.get("from_caster", false) and caster:
					target.buffs.back()["from"] = caster.id      # Длань жертвенности: кто принимает урон
				_mark_src(target, e["key"], caster)
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
					deal_damage(caster, m, amount, school, false, sid)
					fx_at("chain_" + school, m.pos, target.pos, 0.0, m.id)

## Особые эффекты талантов при нанесении урона.
func _on_damage_dealt(caster: Unit, target: Unit, amount: float, school: String, crit: bool, t: float) -> void:
	# Искупление: часть урона Кары и Священного огня лечит раненого союзника; Пламя веры — мана
	if caster.flag("atonement") > 0.0 and school == "holy":
		var low: Unit = null
		for h in world.heroes.values():
			if h.unit.alive and h.unit.hp_frac() < 0.95 and (low == null or h.unit.hp_frac() < low.hp_frac()):
				low = h.unit
		if low:
			heal(caster, low, amount * caster.flag("atonement"), false, "atonement")
	if caster.flag("smite_mana") > 0.0 and school == "holy":
		caster.mana = minf(caster.max_mana, caster.mana + caster.max_mana * caster.flag("smite_mana"))
	if crit and school == "fire" and caster.flag("ignite") > 0.0 and target.alive:
		var total := amount * caster.flag("ignite")
		for a in target.auras:
			if a["key"] == "ignite_talent":
				target.auras.erase(a)
				break
		target.auras.append({"key": "ignite_talent", "kind": "dot", "per_tick": total / 2.0, "tick": 2.0,
			"next": t + 2.0, "until": t + 4.0, "school": "fire", "source": caster.id})
	if school == "frost" and target.alive and caster.flag("frostbite") > 0.0 and randf() < caster.flag("frostbite"):
		_mark_src(target, "frozen", caster)
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
	world.mobs.stop_cast(target)
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
	u.combat_until = t + GameData.COMBAT_TIME

var _proc_cd: Dictionary = {}
var _proc_count: Dictionary = {}     # «каждое N-е событие»: ключ прока -> счётчик

## Проверка проков талантов и вещей: on = spell_hit | heal | auto | auto_crit (критическая автоатака) | cast | hit_taken | interrupt.
## Условия: school, spells, crit, magic (урон не физический), below (здоровье ниже доли), every (каждое N-е событие).
func _trigger_procs(u: Unit, target: Unit, on: String, sid: String, school: String, crit: bool, t: float) -> void:
	if u == null or u.kind != "hero" or u.mods.is_empty() or GameData.AUTO_SPELLS.has(sid):
		return
	for p in u.mods.get("procs", []):
		if not (p["on"] == on if p["on"] is String else (p["on"] as Array).has(on)):
			continue
		if p.has("school") and p["school"] != school:
			continue
		if p.has("spells") and not p["spells"].has(sid):
			continue
		if p.get("crit", false) and not crit:
			continue
		if p.get("magic", false) and school == "physical":
			continue
		if p.has("below") and u.hp_frac() >= float(p["below"]):
			continue
		var key := "%d:%s" % [u.id, p["id"]]
		if t < float(_proc_cd.get(key, 0.0)):
			continue
		if p.has("every"):
			_proc_count[key] = int(_proc_count.get(key, 0)) + 1
			if int(_proc_count[key]) < int(p["every"]) and not Net.cli.has("procall"):
				continue
			_proc_count[key] = 0
		elif randf() >= float(p["chance"]) and not Net.cli.has("procall"):
			continue
		_proc_cd[key] = t + float(p.get("icd", 1.0))
		if Net.cli.has("proclog"):
			print("PROC ", p["id"], " t=%.1f" % t)
		if p.has("reset"):
			# Щит и меч: сбросить перезарядку способности
			var rst := _hstate(u.id)
			rst["cds"][p["reset"]] = 0.0
			var rh = world.heroes.get(u.id, null)
			if rh:
				_feedback(rh.peer_id, p["reset"], "", -1.0, 0.0)
			fx_at("proc", u.pos, u.pos, 0.0, u.id)
			continue
		apply_item_effect(u, p, target, t)

## Действие прока или используемого аксессуара (item_data.ITEM_PROCS, проки талантов с buff/spell):
## buff (party — ещё и союзникам в радиусе), spell — автозаклинание у цели, absorb_pct — щит от запаса здоровья,
## heal_pct — лечение, mana_pct — мана (воину — ярость).
func apply_item_effect(u: Unit, p: Dictionary, target: Unit, t: float) -> void:
	var shown := false
	if p.has("buff"):
		# у проков вещей свои длительность и модификаторы (item_data.ITEM_PROCS)
		var who: Array = [u]
		if p.has("party"):
			who = []
			for h in world.heroes.values():
				if h.unit.alive and _dist(u, h.unit) <= float(p["party"]):
					who.append(h.unit)
		for w: Unit in who:
			w.add_buff(p["buff"], t + float(p.get("dur", 15.0)), p.get("mods", {}))
			_refresh_stats(w)
			fx_at("proc", w.pos, w.pos, 0.0, w.id)
		shown = true
	if p.has("absorb_pct"):
		u.absorb = maxf(u.absorb if t < u.absorb_until else 0.0, u.max_hp * float(p["absorb_pct"]))
		u.absorb_until = t + float(p.get("dur", 10.0))
		fx_at("shield", u.pos, u.pos, 0.0, u.id)
		shown = true
	if p.has("heal_pct"):
		heal(u, u, u.max_hp * float(p["heal_pct"]), false, "proc:" + str(p.get("id", "")))
		fx_at("heal_small", u.pos, u.pos, 0.0, u.id)
		shown = true
	if p.has("mana_pct"):
		u.mana = minf(u.max_mana, u.mana + u.max_mana * float(p["mana_pct"]))
		if not shown:
			fx_at("proc", u.pos, u.pos, 0.0, u.id)
	if p.has("spell"):
		var a: Dictionary = GameData.AUTO_SPELLS[p["spell"]]
		if target or a.get("around_caster", false):
			cast_auto_spell(u, p["spell"], target.pos if target else u.pos, t)

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
func deal_damage(src: Unit, dst: Unit, amount: float, school: String, crit: bool, sid: String = "") -> void:
	if dst == null or not dst.alive:
		return
	var t: float = world.now()
	var src_id := src.id if src else 0
	if t < dst.immune_until:
		world.fx_number(dst.id, 0.0, "immune", school, src_id, false)
		return
	# книга заклинаний: отражение заклинаний, перенаправление, физическая уязвимость, хрупкий лёд
	if dst.has_buff("spell_reflect") and school != "physical" and src and src.kind == "mob" and sid != "reflect":
		dst.remove_buff("spell_reflect")
		world.fx_number(dst.id, 0.0, "immune", school, src.id, false)
		deal_damage(dst, src, amount, school, false, "spell_reflection")
		return
	if school == "physical":
		amount *= maxf(0.0, 1.0 + dst.mod("phys_taken"))
	else:
		amount *= maxf(0.0, 1.0 + dst.mod("magic_taken"))   # эликсир защиты от магии
	if src and src.kind == "hero" and src.flag("brittle") > 0.0 and dst.is_frozen(t):
		amount *= 1.0 + src.flag("brittle")
	if dst.kind == "hero" and src and src.kind == "mob":
		for b in dst.buffs:
			if b["key"] == "sacrifice" and b.has("from"):
				var guard: Unit = world.get_unit(int(b["from"]))
				if guard and guard.alive and guard != dst:
					deal_damage(src, guard, amount * 0.3, school, false, "hand_of_sacrifice")
					amount *= 0.7
		# Щит молний и т.п.: бафф с thorns бьёт природой врага ближнего боя, ударившего героя
		# (не чаще раза в секунду)
		if school == "physical" and not src.def_ranged:
			for b in dst.buffs:
				if float(b["mods"].get("thorns", 0.0)) > 0.0 and t >= float(b.get("next_thorns", 0.0)):
					b["next_thorns"] = t + 1.0
					deal_damage(dst, src, float(b["mods"]["thorns"]) * dst.power, "nature", false, b["key"])
					break
		if dst.has_buff("blazing_barrier") and not src.def_ranged:
			src.auras.append({"key": "ignite", "kind": "dot", "per_tick": 6.0 * dst.power, "tick": 1.0, "next": t + 1.0, "until": t + 3.0, "school": "fire", "source": dst.id})
		# Аура воздаяния паладина рядом отражает часть урона ближнего боя
		if school == "physical" and not src.def_ranged:
			for ph in world.heroes.values():
				if ph.unit.alive and ph.unit.flag("ret_aura") > 0.0 and ph.unit.pos.distance_to(dst.pos) <= 15.0:
					deal_damage(ph.unit, src, amount * ph.unit.flag("ret_aura"), "holy", false, "retribution_aura")
					break
	amount *= dst.damage_taken_mult
	amount *= maxf(0.1, 1.0 + dst.mod("dmg_taken"))
	# блок щитом: физический удар с шансом теряет половину урона
	if school == "physical" and dst.kind == "hero" and src and dst.mod("block") > 0.0 and randf() < dst.mod("block"):
		var blocked: float = amount * GameData.ItemData.BLOCK_REDUCE
		amount -= blocked
		world.fx_number(dst.id, blocked, "block", school, src_id, false)
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
	world.meter.on_damage(src, dst, minf(amount, maxf(dst.hp, 0.0)), sid, crit)
	# аффиксы элитных: вампиризм и отражение урона
	if src and src.affixes.has("vampiric") and src.alive:
		src.hp = minf(src.max_hp, src.hp + amount * 0.3)
	if dst.affixes.has("reflect") and src and src.kind == "hero" and sid != "affix:reflect":
		deal_damage(dst, src, amount * 0.2, school, false, "affix:reflect")
	if src:
		src.stat_dmg += minf(amount, maxf(dst.hp, 0.0))
	if dst.incap:
		dst.incap = false
		dst.stun_until = 0.0         # превращение и ослепление снимаются уроном
	dst.hp -= amount
	if src:
		dst.last_attacker = src.id
		src.combat_until = t + GameData.COMBAT_TIME
	dst.combat_until = t + GameData.COMBAT_TIME
	# Дух гепарда и т.п.: любой удар снимает эффект (break_on_hit в BUFF_INFO)
	if not dst.buffs.is_empty() and amount > 0.0:
		var kept: Array = dst.buffs.filter(func(b): return not GameData.BUFF_INFO.get(b["key"], {}).get("break_on_hit", false))
		if kept.size() != dst.buffs.size():
			dst.buffs = kept
			_refresh_stats(dst)
	if dst.kind == "hero":
		if dst.resource == "rage":
			gain_rage(dst, amount / maxf(dst.max_hp, 1.0) * 60.0, t)
		_trigger_procs(dst, src, "hit_taken", "", school, false, t)
		if dst.hp > 0.0 and amount > 0.0:
			_heal_on_hit(dst, t)
	world.fx_number(dst.id, amount, "dmg", school, src_id, crit)
	if dst.kind == "mob":
		world.mobs.on_damaged(dst, src)
	if dst.hp <= 0.0:
		dst.hp = 0.0
		_on_death(dst, src)
		# Секира Раскола: Казнь, убившая врага, обрушивается на соседа (с запасом здоровья выше 25% — вполсилы)
		if sid == "execute" and src and src.kind == "hero" and src.flag("execute_chain") > 0.0:
			for m in world.mobs.query_radius(Vector2(dst.pos.x, dst.pos.z), 6.0):
				if m != dst and m.alive:
					var ex: Dictionary = GameData.SPELLS["execute"]
					apply_effects(src, m, ex["effects"] if m.hp_frac() < 0.25 else _amplified(ex, 0.5)["effects"], "execute", "physical")
					fx_at("hit_blood", m.pos, dst.pos, 0.0, m.id)
					break

## Щит земли и т.п.: бафф с heal_on_hit лечит носителя при ударе — от силы наложившего, не чаще раза в 2 сек.
func _heal_on_hit(dst: Unit, t: float) -> void:
	for b in dst.buffs:
		var v := float(b["mods"].get("heal_on_hit", 0.0))
		if v <= 0.0 or t < float(b.get("next_heal", 0.0)):
			continue
		b["next_heal"] = t + 2.0
		var from: Unit = world.get_unit(int(b.get("from", dst.id)))
		if from == null:
			from = dst
		heal(from, dst, v * from.power * from.heal_mult * (1.0 + from.mod("heal")), false, b["key"])
		fx_at("heal_small", dst.pos, dst.pos, 0.0, dst.id)

func heal(src: Unit, dst: Unit, amount: float, crit: bool, sid: String = "") -> void:
	if dst == null or not dst.alive:
		return
	join_combat(src, dst, world.now())
	amount *= maxf(0.0, 1.0 + dst.mod("heal_taken"))
	if src and src.flag("grace") > 0.0 and dst.hp_frac() < 0.35:
		amount *= 1.0 + src.flag("grace")      # Благодать: тяжело раненых лечит сильнее
	var before := dst.hp
	dst.hp = minf(dst.max_hp, dst.hp + amount)
	# Жезл Вечного Света: избыточное лечение — щит на цели
	if src and src.flag("overheal_shield") > 0.0 and amount - (dst.hp - before) > 1.0:
		var tnow: float = world.now()
		dst.absorb = maxf(dst.absorb if tnow < dst.absorb_until else 0.0, (amount - (dst.hp - before)) * src.flag("overheal_shield"))
		dst.absorb_until = tnow + 10.0
	world.fx_number(dst.id, dst.hp - before, "heal", "holy", src.id if src else 0, crit)
	world.meter.on_heal(src, dst, dst.hp - before, maxf(0.0, amount - (dst.hp - before)), sid, crit)
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
				world.meter.on_heal(src, b, b.hp - bb, maxf(0.0, amount * 0.4 - (b.hp - bb)), "beacon_of_light", false)
				world.fx_number(b.id, b.hp - bb, "heal", "holy", src.id, false)

func _on_death(dst: Unit, src: Unit) -> void:
	dst.alive = false
	world.meter.on_death(dst, src)
	world.marks.on_unit_died(dst.id)
	var bombs: Array = dst.auras.filter(func(a): return a.has("explode"))
	dst.auras.clear()
	dst.buffs.clear()
	_refresh_stats(dst)
	for a in bombs:
		_explode(a, dst)
	match dst.kind:
		"mob":
			world.mobs.kill(dst, src)
			if src and src.kind == "hero" and src.flag("kill_rage") > 0.0:
				gain_rage(src, src.flag("kill_rage"), world.now())     # Кровожадность
		"hero":
			var h = world.heroes.get(dst.id, null)
			if h:
				h.respawn_at = world.now() + GameData.RESPAWN_BASE + dst.level * 0.6
				_interrupt(h)
				world.announce_all("%s погибает!" % h.player_name, Color(1, 0.5, 0.4))
				world.mode.on_hero_died(h)
		"pet":
			world.mobs.pet_died(dst)
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

## Книга заклинаний: выбрать вариант в ряду. Сервер проверяет ряд, вариант, уровень и «не в бою»
## (бесплатно, как смена талантов: до первой волны, в передышку или через 5 с без боя).
@rpc("any_peer", "reliable")
func request_choose(row: int, sid: String) -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero == null or not GameData.BOOKS.has(hero.class_id):
		return
	var rows: Array = GameData.BOOKS[hero.class_id]["rows"]
	if row < 0 or row >= rows.size() or not rows[row]["options"].has(sid):
		return
	if hero.unit.level < int(rows[row]["level"]):
		return _feedback(hero.peer_id, "", "Ряд откроется на %d уровне" % int(rows[row]["level"]))
	if not can_rechoose(hero.unit):
		return _feedback(hero.peer_id, "", "Менять выбор можно вне боя: в передышку или через 5 сек. без боя")
	var c: Dictionary = hero.choices.duplicate()
	c[row] = sid
	world.ev_choices.rpc(hero.hero_id, c)

func can_rechoose(u: Unit) -> bool:
	var st: String = world.mode.state
	return st == "prep" or st == "break" or world.now() >= u.combat_until - 1.0

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

# ---------------------------------------------------------------- эффекты на цели (для рамки цели)
## Клиент сообщает, кто у него в цели (request_watch). Сервер шлёт список эффектов на этом враге
## только ему и только когда список меняется: наложили, сняли, обновили, сменились стаки.
## В снимок мобов ничего не добавляется — 200 мобов не платят за то, что смотрят 1–6 игроков.

var _watch: Dictionary = {}        # peer -> id врага в цели
var _watch_sig: Dictionary = {}    # peer -> подпись последнего отправленного списка
var _watch_acc := 0.0

func _mark_src(target: Unit, key: String, caster: Unit) -> void:
	if caster:
		target.fx_src[key] = caster.id

@rpc("any_peer", "reliable")
func request_watch(uid: int) -> void:
	if not Net.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	if peer == 0:
		peer = multiplayer.get_unique_id()
	_watch[peer] = uid
	_watch_sig.erase(peer)

## Эффекты на юните: [ключ, осталось сек., id наложившего, стаки].
func unit_effects(u: Unit, t: float) -> Array:
	var out: Array = []
	for a in u.auras:
		if a["kind"] == "dot":
			out.append([a["key"], float(a["until"]) - t, int(a.get("source", 0)), 0])
	if t < u.freeze_until:
		out.append(["frozen", u.freeze_until - t, int(u.fx_src.get("frozen", 0)), 0])
	elif t < u.stun_until:
		out.append(["stunned", u.stun_until - t, int(u.fx_src.get("stunned", 0)), 0])
	if t < u.root_until:
		out.append(["rooted", u.root_until - t, int(u.fx_src.get("rooted", 0)), 0])
	if t < u.slow_until and u.slow_pct > 0.0:
		out.append(["slowed", u.slow_until - t, int(u.fx_src.get("slowed", 0)), 0])
	if u.chill > 0 and t < u.chill_until:
		out.append(["chill", u.chill_until - t, int(u.fx_src.get("chill", 0)), u.chill])
	if u.kind == "mob":
		var tinfo: Array = world.mobs.taunt_info(u)
		if not tinfo.is_empty() and t < float(tinfo[0]):
			out.append(["taunted", float(tinfo[0]) - t, int(tinfo[1]), 0])
	for b in u.buffs:
		if GameData.BUFF_INFO.has(b["key"]):
			out.append([b["key"], float(b["until"]) - t, int(u.fx_src.get(b["key"], 0)), 0])
	return out

func _send_watched_effects(delta: float, t: float) -> void:
	_watch_acc += delta
	if _watch_acc < 0.25:
		return
	_watch_acc = 0.0
	var peers := multiplayer.get_peers()
	for peer in _watch.keys():
		if peer != multiplayer.get_unique_id() and not peers.has(peer):
			_watch.erase(peer)
			_watch_sig.erase(peer)
			continue
		var uid: int = _watch[peer]
		var u: Unit = world.get_unit(uid)
		var list: Array = unit_effects(u, t) if u and u.alive and u.kind == "mob" else []
		# подпись без «тиканья» времени: меняется при наложении, снятии, обновлении и стаках
		var sig := str(uid)
		for e in list:
			sig += "|%s:%d:%d:%d" % [e[0], int((t + float(e[1])) * 4.0), e[2], e[3]]
		if _watch_sig.get(peer, "") == sig:
			continue
		_watch_sig[peer] = sig
		if peer == multiplayer.get_unique_id():
			ev_effects(uid, list)
		else:
			ev_effects.rpc_id(peer, uid, list)

@rpc("authority", "reliable")
func ev_effects(uid: int, list: Array) -> void:
	world.hud.set_target_effects(uid, list)

## Отбрасывание: мобов толкает сервер, героя — сервер считает точку, а клиент героя летит туда
## (как Рывок и Скачок). Пока герой в полёте, сервер не принимает его движение.
func _knockback(caster: Unit, target: Unit, dist: float, t: float) -> void:
	var from := caster.pos if caster else target.pos
	var dir := Vector2(target.pos.x - from.x, target.pos.z - from.z)
	if dir.length() < 0.1:
		dir = Vector2(randf_range(-1, 1), randf_range(-1, 1))
	dir = dir.normalized() * dist
	if target.kind == "mob":
		world.mobs.push(target, dir)
	elif target.kind == "hero":
		var h = world.heroes.get(target.id, null)
		if h:
			target.knock_until = t + 0.45
			h.ev_knock.rpc(target.pos + Vector3(dir.x, 0, dir.y))

## Сервер: зоны (Снежная буря, Огненная стена…) и ловушки — игроку, вошедшему посреди партии.
func send_zones(peer: int) -> void:
	var t: float = world.now()
	for id in zones:
		var z: Dictionary = zones[id]
		var sp: Dictionary = GameData.SPELLS[z["sid"]]
		var size := float(z.get("radius", z.get("reach", 3.0)))
		ev_zone.rpc_id(peer, 10000 + int(id), str(sp.get("vfx", "")), z["pos"], 0.0, size, maxf(0.5, float(z["until"]) - t))
	for tr: Dictionary in traps:
		ev_trap.rpc_id(peer, int(tr["id"]), str(GameData.SPELLS[tr["sid"]]["trap"]["vfx"]), tr["pos"], true)
