class_name ArenaMode
extends GameMode
## «Арена» (по мотивам карты Warcraft 3 Angel Arena): команда на команду (1×1 … 3×3). У каждой команды база
## с лавками (кузнец, алхимик, Мастер сборки, Книжник), фонтаном и башнями. Между базами — лагеря монстров
## по кольцам силы, по краям — боссы. Герои фармят лагеря, покупают томики и вещи, собирают предметы и
## бьются друг с другом; раз в 3,5 минуты — дуэль на закрытой арене в центре.
## Победа — цель хоста (N убийств героев, N побед в дуэлях) или разрушенная база соперника; через 60 минут —
## по счёту. Числа и раскладка — scripts/data/arena_data.gd, карта — tools/bake_map_arena.gd.
## Бой героев — общая PvP-основа (spell_system, pvp_data.gd): режим только разрешает его (hero_pvp).

const A := preload("res://scripts/data/arena_data.gd")
const BASE_ID := 110                 # базы: 110 — команда 0, 111 — команда 1

var bases: Array = []
var spawn_pts: Array = [Vector3.ZERO, Vector3.ZERO]
var spawn_yaw: Array = [0.0, PI]
var fountains: Array = [Vector3.ZERO, Vector3.ZERO]
var duel_center := Vector3.ZERO
var team_n := 1                      # размер команд (по большей): от него — открытые лагеря и цель
var camps: Array = []                # сервер: {id, pos, tier, faction, boss, members: {uid: дом}, respawn_at}

# состояние партии (сервер — истина, клиенты — копия из снимка)
var elapsed := 0.0
var winner := -1
var score: Array = [0, 0]            # убийства вражеских героев
var duel_wins: Array = [0, 0]
var goal_kind := "kills"             # kills | duels | base
var goal_n := 20
var duel_state := "none"             # none | warn | fight
var duel_ids: Array = []             # [герой команды 0, герой команды 1]
var duel_left := 0.0                 # warn — до начала, fight — до конца
var next_duel_in := 0.0
var tomes: Dictionary = {}           # hero_id -> {"n": куплено, "stats": {стат: прибавка}}

var _t0 := 0.0
var _started := false
var _next_duel_at := 0.0
var _duel_at := 0.0                  # warn: когда начнётся; fight: когда началась
var _duel_saved: Dictionary = {}     # hero_id -> {pos, hp, mana, alive}
var _duel_turn: Array = [0, 0]       # по очереди: номер героя команды для следующей дуэли
var _tower_at: Array = [0.0, 0.0]
var _tick_acc := 0.0
var _home: Dictionary = {}           # id моба -> [номер лагеря, точка в лагере]
var stats: Dictionary = {}           # сервер: hero_id -> {hero_dmg, mob_dmg, duels}

func hero_pvp() -> bool:
	return true

func setup(w: Node3D) -> void:
	super.setup(w)
	var sizes := [0, 0]
	for pid in Net.players:
		sizes[clampi(int(Net.players[pid].get("team", 0)), 0, 1)] += 1
	team_n = clampi(maxi(sizes[0], sizes[1]), 1, A.MAX_TEAM)
	var g := str(Net.cli.get("arenagoal", Net.settings.get("arena_goal", "kills")))
	goal_kind = g.get_slice(":", 0) if g.get_slice(":", 0) in ["kills", "duels", "base"] else "kills"
	goal_n = int(g.get_slice(":", 1)) if g.contains(":") and g.get_slice(":", 1).is_valid_int() else A.goal_default(goal_kind, team_n)

func map_path() -> String:
	return "res://scenes/map_arena.tscn"

func read_map(map: Node3D) -> void:
	for team in 2:
		var core := map.get_node("Bases/Base%d" % team) as Node3D
		var b := Unit.new()
		b.id = BASE_ID + team
		b.kind = "castle"
		b.side = team
		b.display_name = A.TEAMS[team]["full"]
		b.max_hp = float(Net.cli.get("basehp", A.BASE_HP))
		b.hp = b.max_hp
		b.radius = float(core.get_meta("radius", A.BASE_RADIUS))
		b.pos = Vector3(core.position.x, 0, core.position.z)
		world.units[b.id] = b
		bases.append(b)
		var hs := map.get_node("HeroSpawn%d" % team) as Node3D
		spawn_pts[team] = hs.position
		spawn_yaw[team] = float(hs.get_meta("yaw", 0.0))
		fountains[team] = (map.get_node("Fountain%d" % team) as Node3D).position
	duel_center = (map.get_node("DuelArena") as Node3D).position
	var i := 0
	for c in A.all_camps():
		if int(c["min_team"]) <= team_n:
			c["members"] = {}
			c["respawn_at"] = 0.0
			c["idx"] = i
			camps.append(c)
			i += 1

func begin() -> void:
	_started = true
	_t0 = world.now() - float(Net.cli.get("startmin", 0.0)) * 60.0
	_next_duel_at = world.now() + (8.0 if Net.cli.has("duelnow") else A.DUEL_FIRST)
	for h in world.heroes.values():
		h.gold = maxi(h.gold, A.START_GOLD)
	for c in camps:
		_spawn_camp(c)
	state = "running"
	var goal := _goal_text()
	world.announce_all("%s: %d × %d. Цель — %s. Фармите лагеря, покупайте томики у Книжника, побеждайте в дуэлях!" % [A.MODE_NAME, team_sizes()[0], team_sizes()[1], goal])

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

func _goal_text() -> String:
	match goal_kind:
		"duels":
			return "%d побед в дуэлях" % goal_n
		"base":
			return "разрушить базу соперника"
	return "%d убийств героев" % goal_n

# ---------------------------------------------------------------- серверный цикл

func server_tick(delta: float, t: float) -> void:
	if not _started or is_over():
		return
	elapsed = t - _t0
	_tick_acc += delta
	if _tick_acc >= 0.5:
		_tick_acc = 0.0
		_camps_tick(t)
		_fountain_tick()
	for team in 2:
		_tower_tick(team, t)
	_duel_tick(t)
	next_duel_in = maxf(0.0, _next_duel_at - t) if duel_state == "none" else 0.0
	if minute() >= A.HARD_END_MIN:
		var w := 0 if [score[0], duel_wins[0], bases[0].hp] >= [score[1], duel_wins[1], bases[1].hp] else 1
		world.announce_all("Время вышло: побеждает команда с большим счётом.", Color(1, 0.85, 0.3))
		_end(w)

func _end(win_team: int) -> void:
	if is_over():
		return
	if duel_state == "fight":
		_finish_duel(-1, world.now())
	winner = win_team
	state = "over"
	world.announce_all("Победа: %s!" % A.TEAMS[win_team]["full"], A.TEAMS[win_team]["color"])
	world.send_summary()

func finish(victory: bool) -> void:
	_end(0 if victory else 1)

func local_victory() -> bool:
	var lh = world.local_hero
	return lh != null and lh.team == winner

func on_unit_destroyed(u: Unit) -> void:
	for team in 2:
		if u == bases[team]:
			world.announce_all("%s разрушена!" % A.TEAMS[team]["full"], Color(1, 0.4, 0.3))
			_end(1 - team)

# ---------------------------------------------------------------- лагеря

## Сила лагеря по кольцу и минуте партии (волна для формул осады).
func _camp_wave(tier: int) -> int:
	var td: Dictionary = A.TIERS[tier]
	return clampi(int(round(float(td["wave"]) + float(td["per_min"]) * minute())), 1, A.MAX_CAMP_WAVE)

func _spawn_camp(c: Dictionary) -> void:
	var tier := int(c["tier"])
	var td: Dictionary = A.TIERS[tier]
	var wave := _camp_wave(tier)
	var list: Array = []          # [тип, опции]
	if c.has("boss"):
		list.append([GameData.BossData.BY_FACTION[c["faction"]][c["boss"]], {"no_elite": true}])
	else:
		var fm: Dictionary = A.FACTION_MOBS[c["faction"]]
		for e in td["comp"]:
			for k in int(e[1]):
				list.append([fm[e[0]], {"no_elite": true}])
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		for k in int(td["elite"]):
			# элитный: 1–2 случайных аффикса (призыватель в лагере не нужен — подмога не вернётся домой)
			var pool: Array = GameData.AffixData.AFFIXES.keys().filter(func(a): return a != "summoner")
			pool.shuffle()
			list[k][1]["affixes"] = pool.slice(0, 1 + rng.randi() % 2)
	var n := list.size()
	var cp: Vector2 = c["pos"]
	for k in n:
		var a := TAU * float(k) / float(maxi(n, 1))
		var home := cp + (Vector2(cos(a), sin(a)) * (2.5 if n > 1 else 0.0))
		var opts: Dictionary = list[k][1]
		opts["pos"] = home
		var hp_k := float(td.get("boss_hp_k", 1.0))
		var uid: int = world.mobs.spawn(list[k][0], int(c["idx"]), wave, mob_players(), hp_k, opts)
		c["members"][uid] = home
		_home[uid] = [int(c["idx"]), home]
	c["respawn_at"] = 0.0

## Раз в 0,5 сек.: зачищенные лагеря возрождаются; вернувшиеся по поводку монстры восстанавливаются;
## если бьют одного — весь лагерь бросается в бой.
func _camps_tick(t: float) -> void:
	for c in camps:
		var members: Dictionary = c["members"]
		if members.is_empty():
			if float(c["respawn_at"]) <= 0.0:
				c["respawn_at"] = t + float(A.TIERS[int(c["tier"])]["respawn"]) * (0.2 if Net.cli.has("fastcamps") else 1.0)
			elif t >= float(c["respawn_at"]):
				_spawn_camp(c)
			continue
		var fighting: Variant = null
		for uid in members.keys():
			var m = world.mobs.mobs.get(uid, null)
			if m == null:
				members.erase(uid)
				continue
			if m.state == 1 and m.target != 0:        # MobManager.S.CHASE
				fighting = m
			elif m.state == 0 and m.pos2.distance_to(members[uid]) < 1.0 and m.unit.hp < m.unit.max_hp and t > m.unit.combat_until:
				m.unit.hp = m.unit.max_hp             # вернулся домой — восстановился
				m.unit.auras.clear()
		if fighting != null:
			for uid in members:
				var m = world.mobs.mobs.get(uid, null)
				if m and m.state == 0 and t >= m.reaggro_at:
					var tu: Unit = world.get_unit(fighting.target)
					if tu and tu.alive and m.unit.is_enemy_of(tu):
						m.state = 1
						m.target = fighting.target
						m.in_reach = false

func mob_start(source: int) -> Array:
	var p: Vector2 = camps[clampi(source, 0, camps.size() - 1)]["pos"] if not camps.is_empty() else Vector2.ZERO
	return [p, p + Vector2(0, -1)]

func mob_spawned(m) -> void:
	m.wp = 0

## Монстр лагеря стоит на своём месте; после погони — возвращается (поводок).
func mob_goal(m) -> Vector2:
	var h: Array = _home.get(m.unit.id, [])
	if h.is_empty():
		return mob_start(m.route)[0]
	return h[1]

func mob_resume(_m) -> void:
	pass

func mob_leash_dist(m) -> float:
	var h: Array = _home.get(m.unit.id, [])
	var p: Vector2 = h[1] if not h.is_empty() else mob_start(m.route)[0]
	return m.pos2.distance_to(p)

func leash_range() -> float:
	return A.LEASH

func mob_players() -> int:
	return team_n

func boss_voice_radius() -> float:
	return 50.0

func show_boss_bar(me, u: Unit) -> bool:
	return me != null and me.unit.pos.distance_to(u.pos) < 45.0

func _camp_of(u: Unit) -> Dictionary:
	var h: Array = _home.get(u.id, [])
	if not h.is_empty() and int(h[0]) < camps.size():
		return camps[int(h[0])]
	if u.route >= 0 and u.route < camps.size():
		return camps[u.route]
	return {}

func kill_reward(u: Unit, xp: int, gold: int) -> Array:
	var c := _camp_of(u)
	if c.is_empty():
		return [xp, gold]
	var td: Dictionary = A.TIERS[int(c["tier"])]
	return [int(xp * float(td["xp_k"])), int(round(gold * float(td["gold_k"])))]

## Опыт и золото за монстра — команде того, кто его добил (и её героям рядом).
func can_share(h, u: Unit) -> bool:
	if u == null:
		return true
	var k: Unit = world.get_unit(u.last_attacker)
	if k and k.kind == "pet":
		k = world.get_unit(k.owner_id)
	return k == null or k.side == h.unit.side

func on_mob_killed(u: Unit, killer: Unit, boss: bool) -> void:
	_home.erase(u.id)
	if boss and killer:
		var kh: Unit = world.get_unit(killer.owner_id) if killer.kind == "pet" else killer
		if kh and kh.kind == "hero":
			world.announce_all("%s: повержен %s!" % [A.TEAMS[clampi(kh.side, 0, 1)]["full"], u.display_name], A.TEAMS[clampi(kh.side, 0, 1)]["color"])

func shop_blue() -> Dictionary:
	return {"chance": 1.0, "min": 2, "extra": 0.5}

func vendor_allowed(hero, vid: String) -> bool:
	return not vid.contains("#") or vid.ends_with("#%d" % hero.team)

func party_visible(me, other) -> bool:
	return me == null or other.team == me.team

func team_for_new() -> int:
	var s := team_sizes()
	return 0 if s[0] <= s[1] else 1

func on_hero_joined(h) -> void:
	h.gold = maxi(h.gold, A.START_GOLD)

# ---------------------------------------------------------------- база: фонтан и башни

func _fountain_tick() -> void:
	for h in world.heroes.values():
		var u: Unit = h.unit
		if not u.alive or u.duel != 0:
			continue
		var f: Vector3 = fountains[clampi(h.team, 0, 1)]
		if Vector2(u.pos.x - f.x, u.pos.z - f.z).length() <= float(A.FOUNTAIN["radius"]):
			u.hp = minf(u.max_hp, u.hp + u.max_hp * float(A.FOUNTAIN["hp"]) * 0.5)
			if u.resource == "mana":
				u.mana = minf(u.max_mana, u.mana + u.max_mana * float(A.FOUNTAIN["mana"]) * 0.5)
	for pu: Unit in world.mobs.pet_units():
		var f2: Vector3 = fountains[clampi(pu.side, 0, 1)]
		if pu.alive and Vector2(pu.pos.x - f2.x, pu.pos.z - f2.z).length() <= float(A.FOUNTAIN["radius"]):
			pu.hp = minf(pu.max_hp, pu.hp + pu.max_hp * float(A.FOUNTAIN["hp"]) * 0.5)

## Башни базы бьют вражеских героев и их питомцев у базы.
func _tower_tick(team: int, t: float) -> void:
	var base: Unit = bases[team]
	if not base.alive or t < float(_tower_at[team]):
		return
	_tower_at[team] = t + float(A.TOWER["every"])
	var bp := Vector2(base.pos.x, base.pos.z)
	var best: Unit = null
	var bd := INF
	for e: Unit in world.enemies_near(base, bp, float(A.TOWER["radius"])):
		if e.kind != "hero" and e.kind != "pet":
			continue
		var d := Vector2(e.pos.x, e.pos.z).distance_to(bp)
		if d < bd:
			bd = d
			best = e
	if best:
		var k := 1.0 + float(A.TOWER["grow"]) * minute()
		world.spells._launch_projectile(base, best, [{"type": "damage", "min": float(A.TOWER["min"]) * k, "max": float(A.TOWER["max"]) * k}], "tower", "holy", 34.0, "bolt_holy", t)

# ---------------------------------------------------------------- убийства героев

func counts_kill(victim, _killer) -> bool:
	return not (duel_state == "fight" and duel_ids.has(victim.hero_id))

func on_hero_killed(victim, killer) -> void:
	if not counts_kill(victim, killer):
		return
	var team: int = clampi(killer.team, 0, 1)
	score[team] += 1
	var g: int = A.KILL_GOLD + A.KILL_GOLD_LVL * int(victim.unit.level)
	killer.gold += g
	killer.gold_in += g
	world.give_xp(killer, float(A.KILL_XP_LVL * victim.unit.level))
	world.announce_all("Счёт: %s %d — %d %s" % [A.TEAMS[0]["name"], score[0], score[1], A.TEAMS[1]["name"]], A.TEAMS[team]["color"])
	if goal_kind == "kills" and score[team] >= goal_n:
		_end(team)

func on_hero_died(hero) -> void:
	if duel_state == "fight" and duel_ids.has(hero.hero_id):
		hero.respawn_at = 0.0          # из дуэли не воскресают по таймеру — вернутся на своё место
		var other: int = duel_ids[1] if duel_ids[0] == hero.hero_id else duel_ids[0]
		_finish_duel(other, world.now())

func respawn_point(hero) -> Vector3:
	return spawn_pts[clampi(hero.team, 0, 1)] + Vector3(randf_range(-2, 2), 0, randf_range(-1, 1))

func hero_spawn_for(info: Dictionary, index: int, _count: int) -> Vector3:
	var team := clampi(int(info.get("team", 0)), 0, 1)
	return spawn_pts[team] + Vector3((index % 3 - 1) * 2.5, 0, 0)

func hero_spawn_yaw_for(info: Dictionary) -> float:
	return spawn_yaw[clampi(int(info.get("team", 0)), 0, 1)]

# ---------------------------------------------------------------- дуэли

## Кто идёт на дуэль от команды: по очереди среди героев в игре (живых — первыми).
func _pick_duelist(team: int):
	var list: Array = world.heroes.values().filter(func(h): return h.team == team and not h.offline)
	if list.is_empty():
		return null
	list.sort_custom(func(a, b): return a.hero_id < b.hero_id)
	var h = list[_duel_turn[team] % list.size()]
	_duel_turn[team] += 1
	return h

func _duel_tick(t: float) -> void:
	match duel_state:
		"none":
			if t < _next_duel_at:
				return
			var a = _pick_duelist(0)
			var b = _pick_duelist(1)
			if a == null or b == null:
				_next_duel_at = t + 20.0
				return
			duel_ids = [a.hero_id, b.hero_id]
			duel_state = "warn"
			_duel_at = t + A.DUEL_WARN
			world.announce_all("Дуэль через %d сек.: %s против %s!" % [int(A.DUEL_WARN), a.player_name, b.player_name], Color(1, 0.85, 0.3))
			world.sound_all("bell")
		"warn":
			duel_left = maxf(0.0, _duel_at - t)
			if t >= _duel_at:
				_start_duel(t)
		"fight":
			duel_left = maxf(0.0, _duel_at + A.DUEL_TIME - t)
			if t - _duel_at >= A.DUEL_TIME:
				var ha = world.heroes.get(duel_ids[0], null)
				var hb = world.heroes.get(duel_ids[1], null)
				var fa: float = ha.unit.hp_frac() if ha else 0.0
				var fb: float = hb.unit.hp_frac() if hb else 0.0
				world.announce_all("Время дуэли вышло — побеждает тот, у кого больше здоровья.", Color(1, 0.85, 0.3))
				_finish_duel(duel_ids[0] if fa >= fb else duel_ids[1], t)

func _start_duel(t: float) -> void:
	var hs: Array = []
	for hid in duel_ids:
		var h = world.heroes.get(hid, null)
		if h == null or h.offline:
			duel_state = "none"
			_next_duel_at = t + 20.0
			world.announce_all("Дуэль отменена: участника нет в игре.", Color(1, 0.7, 0.4))
			return
		hs.append(h)
	for i in 2:
		var h = hs[i]
		var u: Unit = h.unit
		_duel_saved[h.hero_id] = {"pos": h.global_position, "hp": u.hp_frac() if u.alive else 1.0, "mana": u.mana / maxf(u.max_mana, 1.0), "alive": u.alive}
		world.spells._interrupt(h)
		_restore(h)
		u.duel = 1
		var spot := duel_center + Vector3(0, 0, (8.0 if i == 0 else -8.0))
		h.ev_respawn.rpc(spot)
		h.rotation.y = 0.0 if i == 0 else PI
		var pet: Unit = world.mobs.pet_of(h.hero_id)
		if pet:
			pet.duel = 1
	duel_state = "fight"
	_duel_at = t
	world.announce_all("Дуэль: %s против %s — бой!" % [hs[0].player_name, hs[1].player_name], Color(1, 0.85, 0.3))
	world.sound_all("bell")

## Полное здоровье и мана, перезарядки, контроль и эффекты — сброшены (как перед раундом дуэли).
func _restore(h) -> void:
	var u: Unit = h.unit
	u.alive = true
	h.respawn_at = 0.0
	u.hp = u.max_hp
	u.mana = 0.0 if u.resource == "rage" else u.max_mana
	u.auras.clear()
	u.buffs = u.buffs.filter(func(b): return float(b["until"]) - world.now() > 120.0)
	u.dr.clear()
	u.stun_until = 0.0
	u.root_until = 0.0
	u.fear_until = 0.0
	u.silence_until = 0.0
	u.slow_until = 0.0
	u.absorb = 0.0
	var st: Dictionary = world.spells._hstate(h.hero_id)
	st["cds"] = {}
	st["cast"] = {}
	st.erase("charges")
	st.erase("locked")
	for sid in h.spell_list():
		world.spells._feedback(h.peer_id, sid, "", -1.0, 0.0)

## Конец дуэли: победителю — золото и очко команде; оба — на свои места с прежним здоровьем. win_id -1 — без победителя.
func _finish_duel(win_id: int, t: float) -> void:
	duel_state = "none"
	_next_duel_at = t + A.DUEL_EVERY
	var win = world.heroes.get(win_id, null)
	if win:
		var team: int = clampi(win.team, 0, 1)
		duel_wins[team] += 1
		var g := A.DUEL_GOLD + int(A.DUEL_GOLD_MIN * minute())
		win.gold += g
		win.gold_in += g
		_stat(win_id)["duels"] = int(_stat(win_id)["duels"]) + 1
		world.announce_all("%s побеждает в дуэли! (+%d золота)  Дуэли: %d — %d" % [win.player_name, g, duel_wins[0], duel_wins[1]], A.TEAMS[team]["color"])
	for hid in duel_ids:
		var h = world.heroes.get(hid, null)
		if h == null:
			continue
		var u: Unit = h.unit
		u.duel = 0
		var pet: Unit = world.mobs.pet_of(hid)
		if pet:
			pet.duel = 0
		var sv: Dictionary = _duel_saved.get(hid, {})
		_restore(h)
		if not sv.is_empty():
			u.hp = u.max_hp * maxf(0.05, float(sv["hp"]))
			if u.resource == "mana":
				u.mana = u.max_mana * float(sv["mana"])
			h.ev_respawn.rpc(sv["pos"])
	duel_ids = []
	_duel_saved.clear()
	if win and goal_kind == "duels" and duel_wins[clampi(win.team, 0, 1)] >= goal_n:
		_end(clampi(win.team, 0, 1))

## Утомление боем в дуэли растёт с её начала.
func dampen_since(hero) -> float:
	return _duel_at if duel_state == "fight" and duel_ids.has(hero.hero_id) else -1.0

# ---------------------------------------------------------------- томики (Книжник)

func tome_count(hero) -> int:
	return int(tomes.get(hero.hero_id, {}).get("n", 0))

func tome_price(hero) -> int:
	return A.tome_price(tome_count(hero))

## Сервер: купить томик — прибавка к характеристике навсегда (до конца партии), цена растёт с каждой покупкой.
func buy_tome(hero, vid: String, tid: String) -> void:
	if not A.TOMES.has(tid) or not world.economy.vendor_pos.has(vid) or not vendor_allowed(hero, vid):
		return
	var vp: Vector3 = world.economy.vendor_pos[vid]
	if Vector2(hero.unit.pos.x - vp.x, hero.unit.pos.z - vp.z).length() > world.economy.VENDOR_RANGE + 2.0:
		return world.economy._say(hero, "Подойдите ближе к Книжнику")
	var price := tome_price(hero)
	if hero.gold < price:
		return world.economy._say(hero, "Недостаточно золота")
	hero.gold -= price
	hero.gold_out += price
	var tm: Dictionary = tomes.get(hero.hero_id, {"n": 0, "stats": {}})
	var td: Dictionary = A.TOMES[tid]
	tm["n"] = int(tm["n"]) + 1
	tm["stats"][td["stat"]] = int(tm["stats"].get(td["stat"], 0)) + int(td["amount"])
	tomes[hero.hero_id] = tm
	hero.tome_stats = tm["stats"].duplicate()
	hero.apply_level_stats(false)
	world.economy._sound(hero, "coins")
	if Net.cli.has("tomelog"):
		print("TOME %s %s: куплено %d, цена %d, характеристики %s" % [hero.player_name, tid, int(tm["n"]), price, str(tm["stats"])])

# ---------------------------------------------------------------- итоги и статистика

func _stat(hid: int) -> Dictionary:
	if not stats.has(hid):
		stats[hid] = {"hero_dmg": 0.0, "mob_dmg": 0.0, "duels": 0}
	return stats[hid]

## Сервер (spell_system.deal_damage при бое героев): урон по героям и по монстрам — в итоги.
func on_damage(src: Unit, dst: Unit, amount: float) -> void:
	if src == null:
		return
	var hid := src.owner_id if src.kind == "pet" else src.id
	if not world.heroes.has(hid):
		return
	if dst.kind == "hero" or dst.kind == "pet":
		_stat(hid)["hero_dmg"] = float(_stat(hid)["hero_dmg"]) + amount
	elif dst.kind == "mob":
		_stat(hid)["mob_dmg"] = float(_stat(hid)["mob_dmg"]) + amount

func summary_extra(h) -> Dictionary:
	var st := _stat(h.hero_id)
	return {"team": h.team, "winner": winner, "arena": true, "hero_kills": int(world.hero_kills.get(h.hero_id, 0)),
		"deaths": int(world.hero_deaths.get(h.hero_id, 0)), "hero_dmg": float(st["hero_dmg"]), "mob_dmg": float(st["mob_dmg"]),
		"duels": int(st["duels"]), "crafted": int(world.economy.crafted.get(h.hero_id, 0)), "tomes": tome_count(h),
		"gold_in": h.gold_in, "gold_out": h.gold_out}

# ---------------------------------------------------------------- сеть

func state_snapshot() -> Array:
	var tm := {}
	for hid in tomes:
		tm[hid] = [int(tomes[hid]["n"]), tomes[hid]["stats"]]
	return [state, elapsed, winner, score, duel_wins, goal_kind, goal_n, bases[0].hp, bases[0].max_hp, bases[1].hp, bases[1].max_hp,
		duel_state, duel_ids, duel_left, next_duel_in, tm]

func apply_snapshot(s: Array) -> void:
	state = s[0]
	elapsed = s[1]
	winner = s[2]
	score = s[3]
	duel_wins = s[4]
	goal_kind = s[5]
	goal_n = s[6]
	bases[0].hp = s[7]
	bases[0].max_hp = s[8]
	bases[1].hp = s[9]
	bases[1].max_hp = s[10]
	duel_state = s[11]
	duel_ids = s[12]
	duel_left = s[13]
	next_duel_in = s[14]
	for h in world.heroes.values():
		h.unit.duel = 1 if duel_state == "fight" and duel_ids.has(h.hero_id) else 0
	var tm: Dictionary = s[15]
	for hid in tm:
		var h = world.heroes.get(int(hid), null)
		if h == null:
			continue
		tomes[int(hid)] = {"n": int(tm[hid][0]), "stats": tm[hid][1]}
		if h.tome_stats != tm[hid][1]:
			h.tome_stats = (tm[hid][1] as Dictionary).duplicate()
			h.apply_level_stats(false)

# ---------------------------------------------------------------- интерфейс

static func fmt_time(sec: float) -> String:
	return "%d:%02d" % [int(sec) / 60, int(sec) % 60]

func hud_panel(_alive_mobs: int) -> Dictionary:
	var lh = world.local_hero
	var my_team: int = clampi(lh.team, 0, 1) if lh else 0
	var title := "%s  •  %s  •  цель: %s" % [A.MODE_NAME, fmt_time(elapsed), _goal_text()]
	title += "\nСчёт: %s %d — %d %s   (дуэли %d — %d)" % [A.TEAMS[0]["name"], score[0], score[1], A.TEAMS[1]["name"], duel_wins[0], duel_wins[1]]
	match duel_state:
		"warn":
			title += "\nДуэль через %d сек.: %s" % [int(ceil(duel_left)), _duel_names()]
		"fight":
			title += "\nИдёт дуэль: %s — %d сек." % [_duel_names(), int(ceil(duel_left))]
		_:
			title += "\nДуэль через %s" % fmt_time(next_duel_in)
	var me: Unit = bases[my_team]
	var foe: Unit = bases[1 - my_team]
	return {
		"title": title,
		"bar_visible": true, "bar": me.hp, "bar_max": me.max_hp,
		"bar_text": "Наша база: %d / %d" % [int(me.hp), int(me.max_hp)],
		"bar_color": A.TEAMS[my_team]["color"],
		"bar2": foe.hp, "bar2_max": foe.max_hp, "bar2_color": A.TEAMS[1 - my_team]["color"],
		"bar2_text": "База соперника: %d / %d" % [int(foe.hp), int(foe.max_hp)],
		"can_skip": false, "skip_text": "",
	}

func _duel_names() -> String:
	var n: Array = []
	for hid in duel_ids:
		var h = world.heroes.get(int(hid), null)
		n.append(h.player_name if h else "?")
	return " против ".join(n)

func game_over_text(_victory: bool) -> String:
	return "Победа: %s!" % A.TEAMS[clampi(winner, 0, 1)]["full"]

func game_over_details(victory: bool) -> String:
	return ("Ваша команда победила!" if victory else "Победила команда «%s»." % A.TEAMS[clampi(winner, 0, 1)]["name"]) + \
		"  Счёт %d — %d, дуэли %d — %d.  Время партии: %s." % [score[0], score[1], duel_wins[0], duel_wins[1], fmt_time(elapsed)]

func log_line() -> String:
	var parts: Array = []
	for h in world.heroes.values():
		parts.append("%s[%s t%d ур%d з%d т%d hp%d%%]" % [h.player_name, h.class_id, h.team, h.unit.level, h.gold, tome_count(h), int(h.unit.hp_frac() * 100.0)])
	var alive := 0
	for c in camps:
		if not (c["members"] as Dictionary).is_empty():
			alive += 1
	return "ARENA t=%s score=%d:%d duels=%d:%d duel=%s base0=%d base1=%d camps=%d/%d %s" % [fmt_time(elapsed), score[0], score[1], duel_wins[0], duel_wins[1],
		duel_state, int(bases[0].hp), int(bases[1].hp), alive, camps.size(), " ".join(parts)]

# ---------------------------------------------------------------- бот

## Куда идти боту (решения — раз в 0,4 сек.): дуэль → враг рядом → лечиться у фонтана → защищать базу → лагерь по силе.
var _post_cache: Dictionary = {}

func bot_post() -> Vector3:
	return bot_post_for(world.local_hero) if world.local_hero else Vector3.ZERO

func bot_post_for(hero) -> Vector3:
	var c: Array = _post_cache.get(hero.hero_id, [-1.0, Vector3.ZERO])
	var t: float = world.now()
	if t - float(c[0]) < 0.4:
		return c[1]
	var p := _bot_post_calc(hero)
	_post_cache[hero.hero_id] = [t, p]
	return p

func _bot_post_calc(hero) -> Vector3:
	var u: Unit = hero.unit
	var team: int = clampi(hero.team, 0, 1)
	var ranged: bool = GameData.CLASSES[hero.class_id]["auto"]["ranged"]
	var hp2 := Vector2(u.pos.x, u.pos.z)
	# враг-герой рядом (в дуэли — соперник)
	var foe: Unit = null
	var fd := 30.0 if u.duel == 0 else 999.0
	for h in world.enemy_heroes(u):
		if h.unit.alive and Vector2(h.unit.pos.x, h.unit.pos.z).distance_to(hp2) < fd:
			fd = Vector2(h.unit.pos.x, h.unit.pos.z).distance_to(hp2)
			foe = h.unit
	if foe and (u.duel != 0 or u.hp_frac() > 0.45):
		if ranged and fd <= 22.0:
			return u.pos
		var to := Vector2(u.pos.x - foe.pos.x, u.pos.z - foe.pos.z)
		var d := to.normalized() * (16.0 if ranged else 1.5) if to.length() > 0.1 else Vector2(0, 1)
		return Vector3(foe.pos.x + d.x, 0, foe.pos.z + d.y)
	if u.duel != 0:
		return u.pos
	# мало здоровья — к фонтану
	var fnt: Vector3 = fountains[team]
	if u.hp_frac() < 0.4 or (Vector2(u.pos.x - fnt.x, u.pos.z - fnt.z).length() < 8.0 and u.hp_frac() < 0.95):
		return fnt
	# защита базы: вражеский герой у нашей базы
	var bp := Vector2(bases[team].pos.x, bases[team].pos.z)
	for h in world.enemy_heroes(u):
		if h.unit.alive and Vector2(h.unit.pos.x, h.unit.pos.z).distance_to(bp) < 40.0:
			return h.unit.pos
	# лагерь: самый сильный, что по уровню, ближе — лучше
	var best: Dictionary = {}
	var bs := -INF
	for cp in camps:
		if (cp["members"] as Dictionary).is_empty():
			continue
		var td: Dictionary = A.TIERS[int(cp["tier"])]
		if u.level < int(td["bot_level"]):
			continue
		if int(cp["tier"]) == 4 and team_sizes()[team] < 2 and u.level < 24:
			continue      # босса в одиночку — только поздно
		var score_c := float(cp["tier"]) * 60.0 - (cp["pos"] as Vector2).distance_to(hp2) * 0.6
		if score_c > bs:
			bs = score_c
			best = cp
	if best.is_empty():
		return spawn_pts[team]
	var cpos: Vector2 = best["pos"]
	var dir := (hp2 - cpos).normalized() if hp2.distance_to(cpos) > 0.1 else Vector2(0, 1)
	var stand := cpos + dir * (12.0 if ranged else 3.0)
	return Vector3(stand.x, 0, stand.y)
