class_name LinesMode
extends GameMode
## «Война линий» (по мотивам карты Warcraft 3 Hero Line Wars): команда на команду.
## У каждого игрока своя линия, по ней идут общие волны и враги, которых отправил соперник.
## Герой бьёт врагов на своей линии, получает золото и опыт; у Вербовщика покупает врагов на линию соперника —
## каждая покупка повышает доход (каждые 15 сек.). Победа — разрушить базу соперника.
##
## Маршруты (m.route): команда × 3 + линия. Линия команды t идёт от «ворот» соперника к базе команды t.
## Числа — scripts/data/lines_data.gd, отправки — sends.gd. Осаду этот режим не затрагивает.

const L := preload("res://scripts/data/lines_data.gd")
const SD := preload("res://scripts/data/sends.gd")
const BASE_ID := 100                 # базы: 100 — команда 0, 101 — команда 1

var lanes: Array = []                # маршрут -> PackedVector2Array (от ворот к базе)
var lane_count := 1                  # активных линий на сторону
var bases: Array = []                # Unit на команду
var spawn_pts: Array = [Vector3.ZERO, Vector3.ZERO]
var spawn_yaw: Array = [0.0, PI]

# состояние партии (сервер — истина, клиенты — копия из снимка)
var elapsed := 0.0
var wave := 0                        # номер общей волны (для ротации лавки)
var next_wave_in := 0.0
var next_income_in := 0.0
var winner := -1
var slot: Dictionary = {}            # hero_id -> номер линии в своей команде
var income: Dictionary = {}          # hero_id -> прибавка к доходу от отправок
var cds_left: Dictionary = {}        # клиенты: hero_id -> {отправка: сек.}
var team_cds_left: Array = [{}, {}]  # клиенты: перезарядки, общие на команду
var last_income: Dictionary = {}     # hero_id -> сколько пришло в последний раз (для панели)

var _t0 := 0.0
var _next_wave_at := 0.0
var _next_income_at := 0.0
var _started := false
var _queue: Array = []               # [время, тип, маршрут, hp_scale, opts]
var _cds: Dictionary = {}            # сервер: hero_id -> {отправка: до какого времени}
var _team_cds: Array = [{}, {}]
var _tower_at: Array = [0.0, 0.0]
var _leaked: Dictionary = {}         # id моба -> true (уже засчитан прорыв)
var _leak_t := 0.0
var _sudden_said := false
var stats: Dictionary = {}           # сервер: hero_id -> {sent: {имя: n}, sent_n, leaked, send_gold}

func setup(w: Node3D) -> void:
	super.setup(w)
	var sizes := [0, 0]
	for pid in Net.players:
		sizes[clampi(int(Net.players[pid].get("team", 0)), 0, 1)] += 1
	lane_count = clampi(maxi(sizes[0], sizes[1]), 1, L.MAX_LANES)

func map_path() -> String:
	return "res://scenes/map_lines.tscn"

func read_map(map: Node3D) -> void:
	for team in 2:
		for li in L.MAX_LANES:
			var pts := PackedVector2Array()
			for p in map.get_node("Lanes/T%dL%d" % [team, li]).get_children():
				var v: Vector3 = (p as Node3D).position
				pts.append(Vector2(v.x, v.z))
			lanes.append(pts)
		var core := map.get_node("Bases/Base%d" % team) as Node3D
		var b := Unit.new()
		b.id = BASE_ID + team
		b.kind = "castle"
		b.team = Unit.Team.PLAYERS
		b.display_name = L.TEAMS[team]["full"]
		b.max_hp = float(Net.cli.get("basehp", L.BASE_HP))      # --basehp=: тест — быстрая победа
		b.hp = b.max_hp
		b.radius = float(core.get_meta("radius", L.BASE_RADIUS))
		b.pos = Vector3(core.position.x, 0, core.position.z)
		world.units[b.id] = b
		bases.append(b)
		var hs := map.get_node("HeroSpawn%d" % team) as Node3D
		spawn_pts[team] = hs.position
		spawn_yaw[team] = float(hs.get_meta("yaw", 0.0))

func begin() -> void:
	_started = true
	_t0 = world.now() - float(Net.cli.get("startmin", 0.0)) * 60.0      # --startmin=N: тест поздней партии
	_next_wave_at = world.now() + (L.FIRST_WAVE_DELAY if not Net.cli.has("startmin") else 3.0)
	_next_income_at = world.now() + L.INCOME_EVERY
	_assign_slots()
	for h in world.heroes.values():
		h.gold = maxi(h.gold, L.START_GOLD)
	state = "running"
	var sizes := team_sizes()
	world.announce_all("%s: %d × %d. Разрушьте базу соперника! Общие волны — каждые %d сек." % [L.MODE_NAME, sizes[0], sizes[1], int(L.WAVE_EVERY)])
	world.announce_all("Вербовщик у базы продаёт врагов на линию соперника — каждая отправка повышает доход.", Color(0.6, 1.0, 0.7))

## Линии внутри команды — по порядку героев. Опоздавший занимает свободную линию своей команды.
func _assign_slots() -> void:
	for team in 2:
		var ids: Array = world.heroes.values().filter(func(h): return h.team == team).map(func(h): return h.hero_id)
		ids.sort()
		for i in ids.size():
			if not slot.has(ids[i]):
				slot[ids[i]] = _free_slot(team, ids[i]) if i >= lane_count else i
	for hid in slot.keys():
		slot[hid] = mini(int(slot[hid]), lane_count - 1)

func _free_slot(team: int, hid: int) -> int:
	var used := {}
	for h in world.heroes.values():
		if h.team == team and slot.has(h.hero_id) and h.hero_id != hid:
			used[int(slot[h.hero_id])] = true
	for li in L.MAX_LANES:
		if not used.has(li):
			return li
	return 0

func team_sizes() -> Array:
	var s := [0, 0]
	for h in world.heroes.values():
		if not h.offline:
			s[clampi(h.team, 0, 1)] += 1
	return s

func is_over() -> bool:
	return state == "over"

func is_combat() -> bool:
	return state == "running"

func minute() -> float:
	return elapsed / 60.0

# ---------------------------------------------------------------- серверный цикл

func server_tick(delta: float, t: float) -> void:
	if not _started or is_over():
		return
	elapsed = t - _t0
	_test_hooks()
	while not _queue.is_empty() and t >= _queue[0][0]:
		var e: Array = _queue.pop_front()
		var opts: Dictionary = e[4]
		if opts.has("lane_check") and int(opts["lane_check"]) >= lane_count:
			continue
		world.mobs.spawn(e[1], e[2], int(opts.get("wave", 1)), 1, e[3], opts)
	next_wave_in = maxf(0.0, _next_wave_at - t)
	if t >= _next_wave_at:
		_next_wave_at += L.WAVE_EVERY
		_general_wave(t)
	next_income_in = maxf(0.0, _next_income_at - t)
	if t >= _next_income_at:
		_next_income_at += L.INCOME_EVERY
		_pay_income()
	for team in 2:
		_tower_tick(team, t)
	_leak_t += delta
	if _leak_t >= 0.5:
		_leak_t = 0.0
		_track_leaks()
	var mins := minute()
	if mins >= L.SUDDEN_DEATH_MIN and not _sudden_said:
		_sudden_said = true
		world.announce_all("Внезапная смерть! Общие волны с каждой минутой всё сильнее.", Color(1, 0.4, 0.3))
		world.sound_all("bell")
	if mins >= L.HARD_END_MIN:
		var f0: float = bases[0].hp / bases[0].max_hp
		var f1: float = bases[1].hp / bases[1].max_hp
		world.announce_all("Время вышло: побеждает база с большим запасом здоровья.", Color(1, 0.85, 0.3))
		_end(0 if f0 >= f1 else 1)

## База разрушена — победа другой команды.
func on_unit_destroyed(u: Unit) -> void:
	for team in 2:
		if u == bases[team]:
			_end(1 - team)

func _end(win_team: int) -> void:
	if is_over():
		return
	winner = win_team
	state = "over"
	world.announce_all("Победа: %s!" % L.TEAMS[win_team]["full"], L.TEAMS[win_team]["color"])
	world.send_summary()

## Сервер: досрочный конец (--forcewin: победа команды 0).
func finish(victory: bool) -> void:
	_end(0 if victory else 1)

func local_victory() -> bool:
	var lh = world.local_hero
	return lh != null and lh.team == winner

# ---------------------------------------------------------------- общие волны

## Состав — как у волны осады той же силы (formulas.wave_plan), бюджет — доля WAVE_BUDGET_K.
## Одна фракция на волну (по очереди), одинаковый состав и элитные на всех линиях — честно для обеих сторон.
func _general_wave(t: float) -> void:
	wave += 1
	var mins := minute()
	var ew := L.wave_strength(mins)
	var w := maxi(1, int(round(ew)))
	var faction: String = _wave_faction(wave)
	var plan: Dictionary = GameData.wave_plan(w, [faction], 1)
	var budget_k := L.WAVE_BUDGET_K
	var hp_scale := 1.0
	if mins >= L.SUDDEN_DEATH_MIN:
		budget_k *= L.SUDDEN_BUDGET_K
		hp_scale *= 1.0 + L.SUDDEN_HP_PER_MIN * (mins - L.SUDDEN_DEATH_MIN)
	var full: Array = []
	for e in plan["list"]:
		var md: Dictionary = GameData.MOBS[e[0]]
		if not md.get("boss", false) and e[2] != "champion":
			full.append(e[0])
	var budget := GameData.Formulas.wave_budget(w, 1) * budget_k
	var rng := RandomNumberGenerator.new()
	rng.seed = wave * 92821 + 7
	# элитные — заранее для всей волны (одни и те же на каждой линии)
	var list: Array = []          # [тип, аффиксы]
	var spent := 0.0
	var reps := 0
	while spent < budget and reps < 4 and not full.is_empty():
		for id in full:
			if spent >= budget:
				break
			spent += float(GameData.MOBS[id]["cost"])
			var aff: Array = []
			if rng.randf() < GameData.AffixData.elite_chance(w):
				aff = _roll_affixes(1 + rng.randi() % clampi(1 + int(w >= 10) + int(w >= 18), 1, 3), "", rng)
			list.append([id, aff])
		reps += 1
	# босс-волны: чемпион, лейтенант, главный босс — на каждой линии свой
	var headliner := ""
	var boss_type := ""
	var champion := false
	if wave % L.MAIN_EVERY == 0:
		boss_type = GameData.BossData.BY_FACTION[faction]["main"]
	elif wave % L.LIEUTENANT_EVERY == 0:
		boss_type = GameData.BossData.BY_FACTION[faction]["lieutenant"]
	elif wave % L.CHAMPION_EVERY == 0 and GameData.FACTIONS[faction]["champion"] != "":
		boss_type = GameData.FACTIONS[faction]["champion"]
		champion = true
	var champ_aff: Array = _roll_affixes(3, "", rng) if champion else []
	if boss_type != "":
		headliner = ("чемпион %s" % GameData.MOBS[boss_type]["name"].to_lower()) if champion else GameData.MOBS[boss_type]["name"]
	var heroes_on := _occupied_lanes()
	for team in 2:
		for li in lane_count:
			var route := team * 3 + li
			var lane_list: Array = list
			if not heroes_on[team].has(li):
				lane_list = list.slice(0, int(ceil(list.size() * L.EMPTY_LANE_K)))
			var at := t
			for e in lane_list:
				var opts := {"wave": w, "no_elite": true, "lane_check": li}
				if not (e[1] as Array).is_empty():
					opts["affixes"] = e[1]
				_queue.append([at, e[0], route, hp_scale, opts])
				at += 0.8
			if boss_type != "":
				var bo := {"wave": w, "no_elite": true, "lane_check": li}
				if champion:
					bo["affixes"] = champ_aff
					bo["champion"] = true
				_queue.append([at + 3.0, boss_type, route, hp_scale * (1.0 if champion else L.BOSS_HP_K), bo])
	_queue.sort_custom(func(a, b): return a[0] < b[0])
	world.meter.new_segment("Волна %d" % wave)
	var fname: String = GameData.FACTIONS[faction]["name"]
	var txt := "Общая волна %d: %s." % [wave, fname.to_lower()]
	if headliner != "":
		txt += " Идёт %s!" % headliner
	# объявляем только первую волну и босс-волны (таймер следующей — на панели режима), чтобы не засорять экран
	if headliner != "" or wave == 1:
		world.announce_all(txt, Color(1, 0.6, 0.3) if headliner != "" else Color(1, 0.9, 0.6))
		world.sound_all("bell")

func _wave_faction(n: int) -> String:
	var mode_f := str(Net.settings.get("factions", "sides"))
	if Net.cli.has("faction") and GameData.FACTIONS.has(str(Net.cli["faction"])):
		return str(Net.cli["faction"])
	if mode_f == "single" and GameData.FACTIONS.has(str(Net.settings.get("faction", ""))):
		return str(Net.settings["faction"])
	var order: Array = GameData.FactionData.ORDER
	# по две волны каждой фракции подряд, по кругу
	return order[((n - 1) / 2) % order.size()]

## Какие линии заняты героями: [команда] -> {линия: true}.
func _occupied_lanes() -> Array:
	var occ := [{}, {}]
	for h in world.heroes.values():
		if not h.offline and slot.has(h.hero_id):
			occ[clampi(h.team, 0, 1)][int(slot[h.hero_id])] = true
	return occ

## Аффиксы элитного: count штук, first — первым (выбор игрока у отправки), остальные случайно.
func _roll_affixes(count: int, first: String, rng: RandomNumberGenerator) -> Array:
	var pool: Array = GameData.AffixData.AFFIXES.keys()
	var out: Array = []
	if first != "" and pool.has(first):
		out.append(first)
	var guard := 0
	while out.size() < count and guard < 50:
		guard += 1
		var a: String = pool[rng.randi() % pool.size()]
		if not out.has(a):
			out.append(a)
	return out

# ---------------------------------------------------------------- доход

func _pay_income() -> void:
	var mins := minute()
	var sizes := team_sizes()
	var big := maxi(sizes[0], sizes[1])
	for h in world.heroes.values():
		if h.offline:
			continue
		var team: int = clampi(h.team, 0, 1)
		var amt := float(L.base_income(mins) + int(income.get(h.hero_id, 0)))
		amt *= income_mult(team, sizes, big)
		amt *= float(Net.cli.get("income", 1.0))
		var gain := int(round(amt))
		h.gold += gain
		h.gold_in += gain
		last_income[h.hero_id] = gain

## Множитель дохода команды: отстающая по здоровью базы получает больше, меньшая команда — тоже.
func income_mult(team: int, sizes: Array = [], big: int = -1) -> float:
	if sizes.is_empty():
		sizes = team_sizes()
		big = maxi(sizes[0], sizes[1])
	var mine: float = bases[team].hp / bases[team].max_hp
	var other: float = bases[1 - team].hp / bases[1 - team].max_hp
	var k := 1.0 + L.CATCHUP * maxf(0.0, other - mine)
	k += L.SMALL_TEAM * float(maxi(0, big - int(sizes[team])))
	return k

## Сколько придёт герою в следующий раз (панель режима).
func income_of(h) -> int:
	return int(round(float(L.base_income(minute()) + int(income.get(h.hero_id, 0))) * income_mult(clampi(h.team, 0, 1)) * float(Net.cli.get("income", 1.0))))

# ---------------------------------------------------------------- отправки

## Клиент: купить отправку. lane — линия соперника (для отправок «на выбранную»), affix — выбранный аффикс элитного.
func send(send_id: String, lane: int, affix: String) -> void:
	if Net.is_server():
		request_send(send_id, lane, affix)
	else:
		request_send.rpc_id(1, send_id, lane, affix)

@rpc("any_peer", "reliable")
func request_send(send_id: String, lane: int, affix: String) -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero == null:
		return
	var err := send_error(hero, send_id)
	if err != "":
		world.economy._say(hero, err)
		return
	do_send(hero, send_id, lane, affix)

## Почему нельзя купить отправку ("" — можно). Проверяет сервер (и бот — заранее).
func send_error(hero, send_id: String) -> String:
	if is_over() or not _started:
		return "Партия не идёт"
	if not SD.SENDS.has(send_id):
		return "Нет такой отправки"
	var s: Dictionary = SD.SENDS[send_id]
	if not hero.unit.alive:
		return "Вы мертвы"
	if minute() < float(s["minute"]):
		return "Доступно с %d минуты" % int(s["minute"])
	if hero.gold < int(s["price"]):
		return "Недостаточно золота"
	if cd_left(hero, send_id) > 0.0:
		return "Ещё не готово: %d сек." % int(ceil(cd_left(hero, send_id)))
	var vid := "recruiter#%d" % hero.team
	var vp: Vector3 = world.economy.vendor_pos.get(vid, Vector3(1e6, 0, 0))
	if Vector2(hero.unit.pos.x - vp.x, hero.unit.pos.z - vp.z).length() > world.economy.VENDOR_RANGE + 2.0:
		return "Подойдите к Вербовщику"
	return ""

## Сервер: перезарядка отправки у героя (личная или общая на команду), сек.
func cd_left(hero, send_id: String) -> float:
	var t: float = world.now()
	var s: Dictionary = SD.SENDS[send_id]
	var until := float(_cds.get(hero.hero_id, {}).get(send_id, 0.0))
	if s.get("team_cd", false):
		until = maxf(until, float(_team_cds[clampi(hero.team, 0, 1)].get(send_id, 0.0)))
	return maxf(0.0, until - t)

func do_send(hero, send_id: String, lane: int, affix: String) -> void:
	var s: Dictionary = SD.SENDS[send_id]
	var t: float = world.now()
	var team: int = clampi(hero.team, 0, 1)
	var target_team := 1 - team
	if s["target"] == "opposite" or lane < 0 or lane >= lane_count:
		lane = mini(int(slot.get(hero.hero_id, 0)), lane_count - 1)
	var price := int(s["price"])
	hero.gold -= price
	hero.gold_out += price
	income[hero.hero_id] = int(income.get(hero.hero_id, 0)) + int(s["income"])
	if not _cds.has(hero.hero_id):
		_cds[hero.hero_id] = {}
	_cds[hero.hero_id][send_id] = t + float(s["cd"])
	if s.get("team_cd", false):
		_team_cds[team][send_id] = t + float(s["cd"])
	var w := maxi(1, int(round(L.wave_strength(minute()))))
	var count := int(s["count"])
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var bounty := int(round(float(price) * L.SEND_BOUNTY / float(count)))
	for i in count:
		var opts := {"wave": w, "no_elite": true, "sent_by": hero.hero_id, "bounty": bounty}
		var hp_k := 1.0
		if s.get("champion", false):
			opts["champion"] = true
			opts["affixes"] = _roll_affixes(3, affix if s.get("pick_affix", false) else "", rng)
		elif s.get("elite", false):
			opts["affixes"] = _roll_affixes(1 + rng.randi() % 2, affix if s.get("pick_affix", false) else "", rng)
		if s.get("boss", false):
			hp_k = L.BOSS_HP_K
		_queue.append([t + 2.5 + 0.6 * i, s["mob"], target_team * 3 + lane, hp_k, opts])
	_queue.sort_custom(func(a, b): return a[0] < b[0])
	var st := _stat(hero.hero_id)
	st["sent_n"] = int(st["sent_n"]) + count
	st["send_gold"] = int(st["send_gold"]) + price
	var victim := _lane_owner_name(target_team, lane)
	st["sent"][victim] = int(st["sent"].get(victim, 0)) + count
	var title := SD.title(send_id, GameData.MOBS)
	var lane_txt := "" if lane_count <= 1 else " (линия %d)" % (lane + 1)
	world.announce_team(target_team, "%s отправил: %s%s" % [hero.player_name, title, lane_txt], Color(1, 0.45, 0.35))
	world.announce_team(team, "%s отправил сопернику: %s%s" % [hero.player_name, title, lane_txt], Color(0.6, 0.9, 1.0))
	world.economy._sound(hero, "coins")
	if Net.cli.has("sendlog"):
		print("SEND t=%.0f %s -> team %d lane %d: %s, gold=%d income=+%d" % [elapsed, hero.player_name, target_team, lane, send_id, hero.gold, int(income[hero.hero_id])])

func _lane_owner_name(team: int, lane: int) -> String:
	for h in world.heroes.values():
		if h.team == team and int(slot.get(h.hero_id, -1)) == lane:
			return h.player_name
	return "%s, линия %d" % [L.TEAMS[team]["name"], lane + 1]

func _stat(hid: int) -> Dictionary:
	if not stats.has(hid):
		stats[hid] = {"sent": {}, "sent_n": 0, "leaked": 0, "send_gold": 0}
	return stats[hid]

## Выкуп: воскреснуть сразу за золото (растёт с уровнем).
func buyback() -> void:
	if Net.is_server():
		request_buyback()
	else:
		request_buyback.rpc_id(1)

@rpc("any_peer", "reliable")
func request_buyback() -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero == null or hero.unit.alive or hero.offline or is_over():
		return
	var price := L.buyback_price(hero.unit.level)
	if hero.gold < price:
		world.economy._say(hero, "Выкуп стоит %d золота" % price)
		return
	hero.gold -= price
	hero.gold_out += price
	hero.respawn_at = world.now()     # воскресит hero._server_tick в этом же кадре

func _sender_hero() -> Node:
	if world.acting_hero != null:
		return world.acting_hero
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	return world.heroes.get(Net.hero_id_of_peer(sender), null)

# ---------------------------------------------------------------- башни базы, прорывы

## Башни базы бьют врагов у базы; при здоровье базы ниже 25% — «последний рубеж»: чаще, дальше, сильнее.
func _tower_tick(team: int, t: float) -> void:
	var base: Unit = bases[team]
	if not base.alive or t < float(_tower_at[team]):
		return
	var cfg: Dictionary = L.TOWERS["normal"]
	var ls: Dictionary = L.TOWERS["last_stand"]
	if base.hp / base.max_hp < float(ls["below"]):
		cfg = ls
	_tower_at[team] = t + float(cfg["every"])
	var bp := Vector2(base.pos.x, base.pos.z)
	var near: Array = world.mobs.query_radius(bp, float(cfg["radius"]))
	if near.is_empty():
		return
	near.sort_custom(func(a, b): return Vector2(a.pos.x, a.pos.z).distance_squared_to(bp) < Vector2(b.pos.x, b.pos.z).distance_squared_to(bp))
	var k := 1.0 + float(cfg["grow"]) * minute()
	for i in mini(int(cfg["shots"]), near.size()):
		var mu: Unit = near[i]
		world.spells._launch_projectile(base, mu, [{"type": "damage", "min": float(cfg["min"]) * k, "max": float(cfg["max"]) * k}], "tower", "holy", 34.0, "bolt_holy", t)

## Отправленные враги, дошедшие до базы соперника, — в итоги отправителя («прорвалось»).
func _track_leaks() -> void:
	for u: Unit in world.mobs.alive_units():
		if u.sent_by == 0 or _leaked.has(u.id):
			continue
		for team in 2:
			var b: Unit = bases[team]
			if u.pos.distance_to(b.pos) <= b.radius + 6.0:
				_leaked[u.id] = true
				var st := _stat(u.sent_by)
				st["leaked"] = int(st["leaked"]) + 1
	if _leaked.size() > 2000:
		_leaked.clear()

# ---------------------------------------------------------------- награды и добыча (хуки мира)

func kill_reward(u: Unit, xp: int, gold: int) -> Array:
	if u.sent_by != 0:
		return [int(xp * L.XP_K), u.bounty]
	return [int(xp * L.XP_K), int(round(gold * L.KILL_GOLD_K))]

## Доля вещей в добыче: общие волны — вдвое реже, отправленные — без вещей, боссы общих волн — как в осаде.
func loot_gear_k(u: Unit) -> float:
	if u.sent_by != 0:
		return L.SENT_GEAR_K
	if GameData.MOBS.get(u.type_id, {}).get("boss", false):
		return 1.0
	return L.GEAR_K

func shop_blue() -> Dictionary:
	return L.SHOP_BLUE

## Опыт и золото за убийство — только своей команде (линии соперника рядом, за хребтом).
func can_share(h, u: Unit) -> bool:
	if u == null:
		return true
	return h.team == route_team(u)

## Команда, на чьей линии идёт моб.
func route_team(u: Unit) -> int:
	return clampi(u.route / 3, 0, 1)

func vendor_allowed(hero, vid: String) -> bool:
	return not vid.contains("#") or vid.ends_with("#%d" % hero.team)

func mob_players() -> int:
	return 1       # на линии один герой — враги и механики боссов считаются как в одиночке

func party_visible(me, other) -> bool:
	return me == null or other.team == me.team

## Новичок посреди партии — в меньшую команду.
func team_for_new() -> int:
	var s := team_sizes()
	return 0 if s[0] <= s[1] else 1

func on_hero_joined(h) -> void:
	h.gold = maxi(h.gold, L.START_GOLD)
	lane_count = clampi(maxi(lane_count, team_sizes()[clampi(h.team, 0, 1)]), 1, L.MAX_LANES)
	slot[h.hero_id] = _free_slot(h.team, h.hero_id)

func summary_extra(h) -> Dictionary:
	var st := _stat(h.hero_id)
	return {"team": h.team, "gold_in": h.gold_in, "gold_out": h.gold_out, "sent_n": st["sent_n"], "sent": st["sent"],
		"leaked": st["leaked"], "winner": winner}

# ---------------------------------------------------------------- герои

func hero_spawn_for(info: Dictionary, index: int, _count: int) -> Vector3:
	var team := clampi(int(info.get("team", 0)), 0, 1)
	return spawn_pts[team] + Vector3((index % 3 - 1) * 2.5, 0, 0)

func hero_spawn_yaw_for(info: Dictionary) -> float:
	return spawn_yaw[clampi(int(info.get("team", 0)), 0, 1)]

func respawn_point(hero) -> Vector3:
	return spawn_pts[clampi(hero.team, 0, 1)] + Vector3(randf_range(-2, 2), 0, randf_range(-1, 1))

## Бот держит свою линию: ближайший враг на линии (не дальше середины) или точка у выхода из коридора.
func bot_post() -> Vector3:
	var lh = world.local_hero
	return bot_post_for(lh) if lh else Vector3.ZERO

func bot_post_for(hero) -> Vector3:
	var team: int = clampi(hero.team, 0, 1)
	var li := mini(int(slot.get(hero.hero_id, 0)), lane_count - 1)
	var lane: PackedVector2Array = lanes[team * 3 + li]
	var home: Vector2 = lane[lane.size() - 3]          # у выхода из коридора к базе
	var far: Vector2 = lane[4]                          # дальше от базы не уходит
	var hp := Vector2(hero.global_position.x, hero.global_position.z)
	var best: Unit = null
	var best_d := 1e9
	for u: Unit in world.units.values():
		if u.kind != "mob" or not u.alive or u.team != Unit.Team.ENEMIES or not on_my_lane(hero, u.pos):
			continue
		var up := Vector2(u.pos.x, u.pos.z)
		# враги ближе к базе — опаснее
		var d := up.distance_to(Vector2(bases[team].pos.x, bases[team].pos.z))
		if d < best_d:
			best_d = d
			best = u
	if best:
		var bp := Vector2(best.pos.x, best.pos.z)
		if bp.distance_to(home) < far.distance_to(home) + 10.0:
			var to := (hp - bp)
			var keep := 0.0 if to.length() < 0.1 else minf(to.length(), 14.0)
			var p := bp + to.normalized() * keep if keep > 0.0 else bp
			return Vector3(p.x, 0, p.y)
	return Vector3(home.x, 0, home.y)

## Точка на линии героя (в её коридоре) или у его базы. По геометрии: клиент не знает маршрутов мобов.
func on_my_lane(hero, p: Vector3) -> bool:
	var team: int = clampi(hero.team, 0, 1)
	var p2 := Vector2(p.x, p.z)
	if p2.distance_to(Vector2(bases[team].pos.x, bases[team].pos.z)) < 26.0:
		return true
	var li := mini(int(slot.get(hero.hero_id, 0)), lane_count - 1)
	return lane_dist(team * 3 + li, p2) < 10.0

func lane_dist(route: int, p2: Vector2) -> float:
	var lane: PackedVector2Array = lanes[route]
	var best := INF
	for i in lane.size() - 1:
		best = minf(best, Geometry2D.get_closest_point_to_segment(p2, lane[i], lane[i + 1]).distance_to(p2))
	return best

# ---------------------------------------------------------------- цель движения мобов

func mob_start(source: int) -> Array:
	var lane: PackedVector2Array = lanes[clampi(source, 0, lanes.size() - 1)]
	return [lane[0], lane[1]]

func mob_spawned(m) -> void:
	m.wp = 0

func mob_goal(m) -> Vector2:
	var lane: PackedVector2Array = lanes[m.route]
	if m.wp < lane.size() - 1 and m.pos2.distance_to(lane[m.wp]) < 4.0:
		m.wp += 1
	return lane[m.wp]

func mob_objective(m) -> Unit:
	return bases[clampi(int(m.route) / 3, 0, 1)]

func mob_resume(m) -> void:
	var lane: PackedVector2Array = lanes[m.route]
	m.wp = mini(_nearest_segment(m) + 1, lane.size() - 1)

func mob_leash_dist(m) -> float:
	var lane: PackedVector2Array = lanes[m.route]
	var i := _nearest_segment(m)
	return Geometry2D.get_closest_point_to_segment(m.pos2, lane[i], lane[i + 1]).distance_to(m.pos2)

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
	var t: float = world.now()
	var cds := {}
	for hid in _cds:
		var d := {}
		for sid in _cds[hid]:
			var left := float(_cds[hid][sid]) - t
			if left > 0.0:
				d[sid] = left
		if not d.is_empty():
			cds[hid] = d
	var tcd := [{}, {}]
	for team in 2:
		for sid in _team_cds[team]:
			var left := float(_team_cds[team][sid]) - t
			if left > 0.0:
				tcd[team][sid] = left
	var inc := {}
	for h in world.heroes.values():
		inc[h.hero_id] = [int(income.get(h.hero_id, 0)), income_of(h)]
	return [state, elapsed, wave, next_wave_in, next_income_in, bases[0].hp, bases[0].max_hp, bases[1].hp, bases[1].max_hp,
		winner, lane_count, slot, inc, cds, tcd]

func apply_snapshot(s: Array) -> void:
	state = s[0]
	elapsed = s[1]
	wave = s[2]
	next_wave_in = s[3]
	next_income_in = s[4]
	bases[0].hp = s[5]
	bases[0].max_hp = s[6]
	bases[1].hp = s[7]
	bases[1].max_hp = s[8]
	winner = s[9]
	lane_count = s[10]
	slot = s[11]
	var inc: Dictionary = s[12]
	income = {}
	_client_next_income = {}
	for hid in inc:
		income[hid] = int(inc[hid][0])
		_client_next_income[hid] = int(inc[hid][1])
	cds_left = s[13]
	team_cds_left = s[14]
	_snap_time = world.now()

var _client_next_income: Dictionary = {}
var _snap_time := 0.0

## Клиент и сервер: сколько осталось до готовности отправки у героя (для окна лавки).
func cd_left_view(hero, send_id: String) -> float:
	if Net.is_server():
		return cd_left(hero, send_id)
	var gone: float = world.now() - _snap_time
	var a := float(cds_left.get(hero.hero_id, {}).get(send_id, 0.0))
	var b := float(team_cds_left[clampi(hero.team, 0, 1)].get(send_id, 0.0)) if SD.SENDS[send_id].get("team_cd", false) else 0.0
	return maxf(0.0, maxf(a, b) - gone)

func next_income_view(hero) -> int:
	if Net.is_server():
		return income_of(hero)
	return int(_client_next_income.get(hero.hero_id, 0))

# ---------------------------------------------------------------- интерфейс

static func fmt_time(sec: float) -> String:
	return "%d:%02d" % [int(sec) / 60, int(sec) % 60]

func hud_panel(alive_mobs: int) -> Dictionary:
	var lh = world.local_hero
	var my_team: int = lh.team if lh else 0
	var title := "%s  •  %s" % [L.MODE_NAME, fmt_time(elapsed)]
	if minute() >= L.SUDDEN_DEATH_MIN:
		title += "  •  внезапная смерть!"
	if lh:
		title += "\nДоход: +%d через %d сек.  (от отправок +%d)" % [next_income_view(lh), int(ceil(next_income_in)), int(income.get(lh.hero_id, 0))]
	title += "\nОбщая волна %d через %d сек." % [wave + 1, int(ceil(next_wave_in))]
	var me: Unit = bases[my_team]
	var foe: Unit = bases[1 - my_team]
	return {
		"title": title,
		"bar_visible": true, "bar": me.hp, "bar_max": me.max_hp,
		"bar_text": "Наша база: %d / %d" % [int(me.hp), int(me.max_hp)],
		"bar_color": L.TEAMS[my_team]["color"],
		"bar2": foe.hp, "bar2_max": foe.max_hp, "bar2_color": L.TEAMS[1 - my_team]["color"],
		"bar2_text": "База соперника: %d / %d      Врагов: %d" % [int(foe.hp), int(foe.max_hp), alive_mobs],
		"can_skip": false, "skip_text": "",
	}

func game_over_text(_victory: bool) -> String:
	return "Победа: %s!" % L.TEAMS[clampi(winner, 0, 1)]["full"]

func game_over_details(victory: bool) -> String:
	var who: String = L.TEAMS[clampi(winner, 0, 1)]["full"]
	return ("Ваша команда победила! %s выстояла." if victory else "Ваша база разрушена. Победила %s.") % who + "  Время партии: %s." % fmt_time(elapsed)

## Строка тестового лога раз в 5 сек.
func log_line() -> String:
	var parts: Array = []
	for h in world.heroes.values():
		parts.append("%s[%s t%d л%d ур%d з%d +%d]" % [h.player_name, h.class_id, h.team, int(slot.get(h.hero_id, -1)), h.unit.level, h.gold, int(income.get(h.hero_id, 0))])
	return "LINES t=%s wave=%d base0=%d base1=%d %s" % [fmt_time(elapsed), wave, int(bases[0].hp), int(bases[1].hp), " ".join(parts)]

# ---------------------------------------------------------------- тесты (--sendtest)

var _sendtest_done := false

func _test_hooks() -> void:
	if Net.cli.has("sendtest") and not _sendtest_done and elapsed > 3.0:
		_sendtest_done = true
		# по одному врагу каждой ступени от каждого героя (без золота и проверок)
		for h in world.heroes.values():
			var seen := {}
			for sid in SD.ordered():
				var tier := int(SD.SENDS[sid]["tier"])
				if seen.has(tier):
					continue
				seen[tier] = true
				h.gold += int(SD.SENDS[sid]["price"])
				do_send(h, sid, 0, "")
