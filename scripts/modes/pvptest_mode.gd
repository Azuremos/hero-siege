class_name PvpTestMode
extends GameMode
## --pvptest=<класс>: проверка баланса боя героев. Рядом появляется вражеский герой-бот этого класса,
## бой один на один (оба — боты: свой герой с --bot). Раунд — до смерти или --pvptime сек. (по умолчанию 120,
## дальше — у кого больше доля здоровья). После раунда оба воскресают на местах; --pvprounds=N раундов (3),
## итог — строка «PVPTEST RESULT» в лог и выход. Уровень и вещи — общими флагами (--level=, --outfit=).
## Таблица «класс × класс» в отчёте собирается этими прогонами.

var center := Vector3(0, 0, 40)
var rounds := 3
var round_time := 120.0
var _round := 0
var _round_start := 0.0
var _between_until := 0.0
var _results: Array = []          # [победитель, проигравший, сек., доля здоровья победителя]
var _started := false

func hero_pvp() -> bool:
	return true

func read_map(map: Node3D) -> void:
	var hs := map.get_node_or_null("HeroSpawn") as Node3D
	if hs:
		center = hs.position + Vector3(0, 0, 14)
	rounds = int(Net.cli.get("pvprounds", 3))
	round_time = float(Net.cli.get("pvptime", 120.0))

func begin() -> void:
	state = "prep"          # между раундами — «вне боя»: боты выбирают книгу заклинаний
	_between_until = world.now() + 4.0      # таланты, уровень и вещи — тестовыми флагами за первые секунды

func is_combat() -> bool:
	return true

func hero_spawn_for(info: Dictionary, _index: int, _count: int) -> Vector3:
	return _spot(clampi(int(info.get("team", 0)), 0, 1))

func hero_spawn_yaw_for(info: Dictionary) -> float:
	return 0.0 if int(info.get("team", 0)) == 0 else PI

func respawn_point(hero) -> Vector3:
	return _spot(clampi(hero.team, 0, 1))

func _spot(team: int) -> Vector3:
	return center + Vector3(0, 0, 11.0 if team == 0 else -11.0)

## Бот держится на дистанции своего боя от соперника: ближний бой — вплотную, дальний — 16 м.
func bot_post_for(hero) -> Vector3:
	var foe = _foe(hero)
	if foe == null or not foe.unit.alive:
		return respawn_point(hero)
	var ranged: bool = GameData.CLASSES[hero.class_id]["auto"]["ranged"]
	var to: Vector3 = hero.global_position - foe.unit.pos
	to.y = 0.0
	if to.length() < 0.1:
		to = Vector3(0, 0, 1)
	# дальний бой: в радиусе заклинаний стоит и колдует (бег сбивает произнесение), иначе подходит на 16 м
	if ranged and to.length() <= 22.0:
		return hero.global_position
	return foe.unit.pos + to.normalized() * (16.0 if ranged else 1.5)

func bot_post() -> Vector3:
	return bot_post_for(world.local_hero) if world.local_hero else center

func _foe(hero):
	for h in world.heroes.values():
		if h != hero and hero.unit.is_enemy_of(h.unit):
			return h
	return null

var _wall_check_until := 0.0
var _wall_log_t := 0.0
var _leap_done := false
var _cc_casts := 0
var _cc_log_t := 0.0

func server_tick(_delta: float, t: float) -> void:
	if is_over():
		return
	# --pvpwalltest с воином: через 2 сек. после стены — Героический прыжок к магу (перелетает стену)
	if _wall_check_until > 0.0 and t >= _wall_check_until - 4.0 and not _leap_done:
		_leap_done = true
		for h in world.heroes.values():
			var f = _foe(h)
			if h.class_id == "warrior" and f:
				print("PVPWALL прыжок воина к магу")
				world.spells._complete_cast(h, "heroic_leap", 0, f.unit.pos + Vector3(0, 0, 3.0 if f.unit.pos.z < h.unit.pos.z else -3.0), 0.0, 0.0)
	# --pvpcctest=<заклинание>: через 2 сек. раунда соперник накладывает контроль заклинания на своего героя
	# (дважды, чтобы видеть убывание); 5 сек. лог: место, оглушён ли (на сервере и в снимке), обездвижен.
	if Net.cli.has("pvpcctest") and _round_start > 0.0:
		var since := t - _round_start
		var me = world.local_hero
		var foe = _foe(me) if me else null
		if foe and since >= 2.0 and _cc_casts == 0 or foe and since >= 6.0 and _cc_casts == 1:
			_cc_casts += 1
			var csid := str(Net.cli["pvpcctest"])
			var csp: Dictionary = GameData.SPELLS[csid]
			var fx: Array = csp.get("effects", []) + csp.get("enemy_fx", []) + csp.get("impact_fx", [])
			world.spells.apply_effects(foe.unit, me.unit, fx.filter(func(e): return e["type"] != "damage"), csid, csp["school"])
			print("PVPCC %s №%d по %s (база %s)" % [csid, _cc_casts, me.class_id, str(fx.filter(func(e): return e.has("dur")).map(func(e): return "%s %.1f" % [e["type"], float(e["dur"])]))])
		if foe and since >= 2.0 and since < 10.0 and t - _cc_log_t >= 0.25:
			_cc_log_t = t
			var mu: Unit = me.unit
			print("PVPCC t=%.2f pos=(%.1f,%.1f) stun=%.2f net_stun=%.2f root=%.2f fear=%.2f incap=%s cast=%s" % [since, me.global_position.x, me.global_position.z,
				maxf(0.0, mu.stun_until - t), me.net_stun_left, maxf(0.0, mu.root_until - t), maxf(0.0, mu.fear_until - t), mu.incap, me.controller.cast_spell])
	if t < _wall_check_until and t - _wall_log_t >= 1.0:
		_wall_log_t = t
		for h in world.heroes.values():
			print("PVPWALL %s z=%.1f (стена z=%.1f)" % [h.class_id, h.unit.pos.z, center.z])
	if _round_start == 0.0:
		if t >= _between_until:
			_start_round(t)
		return
	var alive: Array = world.heroes.values().filter(func(h): return h.unit.alive)
	var timeout := t - _round_start >= round_time
	if alive.size() >= 2 and not timeout:
		return
	var win = null
	var lose = null
	if alive.size() == 1:
		win = alive[0]
		lose = _foe(win)
	else:
		var hs: Array = world.heroes.values()
		hs.sort_custom(func(a, b): return a.unit.hp_frac() > b.unit.hp_frac())
		win = hs[0]
		lose = hs[1] if hs.size() > 1 else null
	if win == null or lose == null:
		return
	var dur := t - _round_start
	_results.append([win.class_id, lose.class_id, dur, win.unit.hp_frac(), timeout])
	print("PVPTEST round %d: %s (%s) победил %s (%s) за %.1f сек., здоровье победителя %d%%%s" % [_round, win.player_name, win.class_id,
		lose.player_name, lose.class_id, dur, int(win.unit.hp_frac() * 100.0), " (по времени)" if timeout else ""])
	world.announce_all("Раунд %d: победил %s за %d сек." % [_round, win.player_name, int(dur)], Color(1, 0.85, 0.3))
	_round_start = 0.0
	state = "prep"
	if _round >= rounds:
		_summary()
		return
	_between_until = t + 3.0

func _start_round(t: float) -> void:
	_round += 1
	_round_start = t
	state = "running"
	for h in world.heroes.values():
		_restore(h)
	world.announce_all("Раунд %d: бой!" % _round)
	# --pvpwalltest: маг сразу ставит Ледяную стену между героями — соперник не должен пройти сквозь неё
	if Net.cli.has("pvpwalltest"):
		for h in world.heroes.values():
			if h.class_id == "mage":
				world.spells._complete_cast(h, "ice_wall", 0, center, 0.0, 0.0)
				_wall_check_until = t + 6.0

## Оба героя — на свои места с полным здоровьем и маной, перезарядки и убывание контроля сброшены.
func _restore(h) -> void:
	var u: Unit = h.unit
	u.alive = true
	u.hp = u.max_hp
	u.mana = 0.0 if u.resource == "rage" else u.max_mana
	u.auras.clear()
	u.buffs = u.buffs.filter(func(b): return float(b["until"]) - world.now() > 120.0)     # долгие баффы оставляем
	u.dr.clear()
	u.stun_until = 0.0
	u.root_until = 0.0
	u.fear_until = 0.0
	u.silence_until = 0.0
	u.slow_until = 0.0
	u.pvp_since = -100.0
	u.pvp_last = -100.0
	h.respawn_at = 0.0
	var st: Dictionary = world.spells._hstate(h.hero_id)
	st["cds"] = {}
	st.erase("charges")
	st.erase("locked")
	h.ev_respawn.rpc(respawn_point(h))
	h.rotation.y = 0.0 if h.team == 0 else PI

func on_hero_died(hero) -> void:
	hero.respawn_at = 0.0       # воскрешает раунд, а не таймер

func _summary() -> void:
	var w := {}
	var total := 0.0
	for r in _results:
		w[r[0]] = int(w.get(r[0], 0)) + 1
		total += float(r[2])
	var cls: Array = world.heroes.values().map(func(h): return h.class_id)
	print("PVPTEST RESULT %s: %s, средняя длительность %.1f сек., раунды: %s" % [" vs ".join(cls), str(w),
		total / maxf(1.0, float(_results.size())), str(_results.map(func(r): return "%s %.0fс %d%%%s" % [r[0], r[2], int(r[3] * 100.0), "*" if r[4] else ""]))])
	state = "victory"
	Net.cli["quit-after"] = "0"

func hud_panel(_alive_mobs: int) -> Dictionary:
	var left := maxf(0.0, round_time - (world.now() - _round_start)) if _round_start > 0.0 else 0.0
	return {"title": "Проверка PvP: раунд %d из %d  •  %d сек." % [maxi(1, _round), rounds, int(left)], "bar_visible": false,
		"bar": 0.0, "bar_max": 1.0, "bar_text": "", "can_skip": false, "skip_text": ""}

func local_victory() -> bool:
	return true

func game_over_text(_victory: bool) -> String:
	return "Проверка PvP окончена"
