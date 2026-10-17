extends Node3D
## Корень игровой сцены. Сервер (хост) ведёт всю игровую логику,
## клиенты получают снимки состояния и события.

const HeroScript := preload("res://scripts/world/hero.gd")
const MobManagerScript := preload("res://scripts/world/mob_manager.gd")
const SpellSystemScript := preload("res://scripts/world/spell_system.gd")
const HudScript := preload("res://scripts/ui/hud.gd")
const EconomyScript := preload("res://scripts/world/economy.gd")
const TradeScript := preload("res://scripts/world/trade.gd")
const MeterScript := preload("res://scripts/world/meter.gd")
const MarksScript := preload("res://scripts/world/marks.gd")

var map: Node3D
var heroes_root: Node3D
var vfx_root: Node3D
var mobs: Node            # MobManager
var spells: Node          # SpellSystem
var mode: GameMode        # режим игры (осада, позже подземелья): волны, цели, победа и поражение
var economy: Node         # Economy: торговцы, предметы, добыча
var trade: Node           # обмен предметами между героями
var meter: Node           # счётчик урона и лечения
var marks: Node           # рейдовые метки и пинги
var hud: CanvasLayer

var units: Dictionary = {}        # id -> Unit
var heroes: Dictionary = {}       # hero_id -> Hero
var local_hero: CharacterBody3D = null

## Режимы игры. Выбор режима — Net.settings["mode"]: осада и предпросмотр интерфейса из главного меню.
const MODES := {"siege": preload("res://scripts/modes/siege_mode.gd"), "preview": preload("res://scripts/modes/preview_mode.gd"),
	"arena": preload("res://scripts/modes/arena_mode.gd")}

var _snap_accum := 0.0
var _state_accum := 0.0
var _ready_peers: Dictionary = {}

func now() -> float:
	return Time.get_ticks_msec() * 0.001

func is_server() -> bool:
	return Net.is_server()

func _ready() -> void:
	name = "World"
	map = (load("res://scenes/map.tscn") as PackedScene).instantiate()
	add_child(map)
	heroes_root = Node3D.new()
	heroes_root.name = "Heroes"
	add_child(heroes_root)
	vfx_root = Node3D.new()
	vfx_root.name = "Vfx"
	add_child(vfx_root)
	mobs = MobManagerScript.new()
	mobs.name = "Mobs"
	add_child(mobs)
	spells = SpellSystemScript.new()
	spells.name = "Spells"
	add_child(spells)
	var mode_name := "arena" if Net.cli.has("bossarena") else str(Net.settings.get("mode", "siege"))    # --bossarena: босс без осады
	var mode_script: GDScript = MODES.get(mode_name, MODES["siege"])
	mode = mode_script.new()
	mode.name = "Mode"
	add_child(mode)
	mode.setup(self)
	economy = EconomyScript.new()
	economy.name = "Economy"
	add_child(economy)
	trade = TradeScript.new()
	trade.name = "Trade"
	add_child(trade)
	meter = MeterScript.new()
	meter.name = "Meter"
	add_child(meter)
	marks = MarksScript.new()
	marks.name = "Marks"
	add_child(marks)

	_read_map()

	_spawn_heroes()
	hud = HudScript.new()
	hud.name = "HUD"
	add_child(hud)
	hud.setup(self)

	Net.disconnected.connect(_on_net_disconnected)
	multiplayer.peer_disconnected.connect(_on_peer_left)
	if is_server():
		_ready_peers[1] = true
		_apply_saved_heroes()
		mode.begin()
	else:
		if Net.joining_mid:
			# вошёл посреди партии: завершить вход (до этого RPC сюда не шли), дождаться соединения
			Net.finish_mid_join()
			await multiplayer.connected_to_server
			Net.joining_mid = false
		_client_ready.rpc_id(1)

func _read_map() -> void:
	mode.read_map(map)
	mobs.build_static_obstacles(map.get_node("Colliders"))
	if Net.cli.has("treetest"):
		var tt: Node = preload("res://scripts/world/tree_test.gd").new()
		add_child(tt)
		tt.setup(map.get_node("Colliders"))
	economy.spawn_vendors()
	_apply_cobblestone()
	Settings.apply_shadows(map.get_node_or_null("Sun") as DirectionalLight3D)

func _spawn_heroes() -> void:
	var peers := Net.players.keys()
	peers.sort()
	var i := 0
	for pid in peers:
		var info: Dictionary = Net.players[pid]
		var hero: CharacterBody3D = HeroScript.new()
		var hid := int(info.get("hero_id", i + 1))
		hero.name = "Hero_%d" % hid
		hero.setup(self, hid, pid, info)
		hero.position = mode.hero_spawn_point(i, peers.size())
		hero.rotation.y = mode.hero_spawn_yaw()
		heroes_root.add_child(hero)
		heroes[hid] = hero
		units[hid] = hero.unit
		if info.get("offline", false):
			hero.offline = true      # продолженная осада: игрок ещё не вернулся — герой ждёт
			hero.visible = false
		if pid == Net.my_id():
			local_hero = hero
		i += 1

func hero_count_alive() -> int:
	var n := 0
	for h in heroes.values():
		if h.unit.alive:
			n += 1
	return n

func get_unit(id: int) -> Unit:
	return units.get(id, null)

# ---------------------------------------------------------------- серверный цикл

func _physics_process(delta: float) -> void:
	if not is_server():
		return
	var t := now()
	for h in heroes.values():
		h.unit.pos = h.server_position()
	spells.server_tick(delta, t)
	mobs.server_tick(delta, t)
	mode.server_tick(delta, t)
	economy.server_tick(delta, t)
	trade.server_tick(t)
	meter.server_tick(delta)

	_snap_accum += delta
	if _snap_accum >= 0.1:
		_snap_accum = 0.0
		ev_hero_snapshot.rpc(_build_hero_snapshot(t))
	_state_accum += delta
	if _state_accum >= 0.5:
		_state_accum = 0.0
		ev_mode_state.rpc(mode.state_snapshot(), mobs.alive_count())

func _build_hero_snapshot(t: float) -> Array:
	var out: Array = []
	for hid in heroes:
		var h = heroes[hid]
		var u: Unit = h.unit
		var buffs: Array = []
		for a in u.auras:
			buffs.append([a["key"], maxf(0.0, a["until"] - t)])
		if u.absorb > 0.0 and t < u.absorb_until:
			buffs.append(["absorb", u.absorb_until - t])
		if t < u.immune_until:
			buffs.append(["immune", u.immune_until - t])
		if u.damage_taken_mult < 0.99:
			buffs.append(["barrier", 0.0])
		# контроль от врагов — видно в рамках героя и группы
		if t < u.stun_until:
			buffs.append(["stunned", u.stun_until - t])
		if t < u.fear_until:
			buffs.append(["feared", u.fear_until - t])
		if t < u.silence_until:
			buffs.append(["silenced", u.silence_until - t])
		for b in u.buffs:
			buffs.append([b["key"], maxf(0.0, b["until"] - t)])
		out.append([hid, u.hp, u.max_hp, u.mana, u.max_mana, u.level, h.xp, h.xp_next, h.gold,
			u.absorb if t < u.absorb_until else 0.0, u.alive, maxf(0.0, u.stun_until - t), buffs,
			h.respawn_at - t if not u.alive else 0.0, u.speed_mult(t)])
	return out

@rpc("authority", "call_local", "unreliable_ordered")
func ev_hero_snapshot(snap: Array) -> void:
	for e in snap:
		var h = heroes.get(int(e[0]), null)
		if h == null:
			continue
		var u: Unit = h.unit
		u.hp = e[1]
		u.max_hp = e[2]
		u.mana = e[3]
		u.max_mana = e[4]
		u.level = e[5]
		h.xp = e[6]
		h.xp_next = e[7]
		h.gold = e[8]
		h.net_absorb = e[9]
		h.set_alive_visual(e[10])
		h.net_stun_left = e[11]
		h.net_buffs = e[12]
		h.net_respawn_left = e[13]
		if e.size() > 14:
			h.net_speed = e[14]

@rpc("authority", "call_local", "unreliable_ordered")
func ev_mode_state(snap: Array, alive_mobs: int) -> void:
	if not is_server():
		mode.apply_snapshot(snap)
	mobs.client_alive_count = alive_mobs
	if mode.is_over() and not hud.game_over_shown:
		hud.show_game_over(mode.state == "victory")

# ---------------------------------------------------------------- опыт и уровни (сервер)

func award_kill(mob_pos: Vector3, xp: int, gold: int) -> void:
	var near: Array = []
	for h in heroes.values():
		if h.unit.alive and Vector2(h.unit.pos.x, h.unit.pos.z).distance_to(Vector2(mob_pos.x, mob_pos.z)) <= GameData.XP_SHARE_RADIUS:
			near.append(h)
	if near.is_empty():
		return
	var n := near.size()
	var share := float(xp) * (1.0 + 0.5 * float(n - 1)) / float(n)
	for h in near:
		h.gold += gold
		give_xp(h, share)

func give_xp(h, amount: float) -> void:
	if h.unit.level >= GameData.MAX_LEVEL:
		return
	if is_campaign() and h.unit.level < max_hero_level() - 2:
		amount *= 1.5      # «Поход»: отставший друг догоняет (врагов это не ослабляет)
	h.xp += int(round(amount * float(GameData.RACES[h.race_id].get("xp_mult", 1.0))))
	while h.xp >= h.xp_next and h.unit.level < GameData.MAX_LEVEL:
		h.xp -= h.xp_next
		h.unit.level += 1
		h.apply_level_stats(true)
		h.xp_next = GameData.xp_to_next(h.unit.level)
		ev_level_up.rpc(h.hero_id, h.unit.level)

@rpc("authority", "call_local", "reliable")
func ev_level_up(hero_id: int, level: int) -> void:
	var h = heroes.get(hero_id, null)
	if h == null:
		return
	h.unit.level = level
	Vfx.level_up(self, h)
	if h == local_hero:
		Sfx.play("level_up")
		var text := "Новый уровень: %d!" % level
		for sid in GameData.CLASSES[h.class_id]["spells"]:
			if GameData.spell_level(sid) == level:
				text += "   Новое заклинание: %s" % GameData.SPELLS[sid]["name"]
		hud.announce(text, Color(1, 0.85, 0.3))
		if h.talent_points_free() > 0:
			hud.error_info("Доступно очков талантов: %d  (клавиша N)" % h.talent_points_free())
		hud.on_level_changed()

## Выбор в книге заклинаний (сервер рассылает всем: нужен для подсказок и рамок группы).
@rpc("authority", "call_local", "reliable")
func ev_choices(hero_id: int, c: Dictionary) -> void:
	var h = heroes.get(hero_id, null)
	if h == null:
		return
	h.set_choices(c)
	if h == local_hero:
		hud.on_choices_changed()

## Изменение талантов героя (сервер рассылает всем).
@rpc("authority", "call_local", "reliable")
func ev_talents(hero_id: int, ranks: Dictionary) -> void:
	var h = heroes.get(hero_id, null)
	if h == null:
		return
	h.set_talents(ranks)
	if is_server():
		economy.check_offhand(h)
	if h == local_hero:
		hud.on_talents_changed()

# ---------------------------------------------------------------- события

## Всплывающие цифры урона/лечения.
func fx_number(target_id: int, amount: float, kind: String, school: String, source_id: int, crit: bool) -> void:
	ev_number.rpc(target_id, amount, kind, school, source_id, crit)

@rpc("authority", "call_local", "unreliable")
func ev_number(target_id: int, amount: float, kind: String, school: String, source_id: int, crit: bool) -> void:
	if local_hero == null:
		return
	var mine: bool = target_id == local_hero.hero_id or source_id == local_hero.hero_id
	if not mine:
		return
	var u := get_unit(target_id)
	if u == null:
		return
	hud.floating_number(u, amount, kind, school, crit, target_id == local_hero.hero_id)

func announce_all(text: String, color: Color = Color(1, 0.9, 0.6)) -> void:
	if not Net.cli.is_empty():
		print("ANNOUNCE [t=%d]: %s" % [int(now()), text])
	ev_announce.rpc(text, color)

@rpc("authority", "call_local", "reliable")
func ev_announce(text: String, color: Color) -> void:
	hud.announce(text, color)

## Звук сразу у всех игроков.
func sound_all(name: String) -> void:
	ev_sound.rpc(name)

@rpc("authority", "call_local", "unreliable")
func ev_sound(name: String) -> void:
	Sfx.play(name)

@rpc("any_peer", "reliable")
func _client_ready() -> void:
	var peer := multiplayer.get_remote_sender_id()
	_ready_peers[peer] = true
	if not _rejoining.has(peer):
		send_full_state(peer)      # начало партии: сохранённые герои и всё, что уже есть в мире
	else:
		# вошёл посреди партии (вернулся или новый): полный снимок мира, герой — у точки воскрешения
		var h = heroes.get(int(_rejoining[peer]), null)
		_rejoining.erase(peer)
		if h:
			_set_offline(h.hero_id, false)
			h.ev_respawn.rpc(mode.respawn_point(h))
		send_full_state(peer)

## Игрок отключился: герой ждёт его до конца партии (без ограничения по времени) — скрыт и неуязвим.
func _on_peer_left(peer: int) -> void:
	_ready_peers.erase(peer)
	_rejoining.erase(peer)
	var hid := 0
	for h in heroes.values():
		if h.peer_id == peer:
			hid = h.hero_id
	if hid == 0 or not is_server():
		return
	if Net.players.has(peer):
		Net.players[peer]["offline"] = true
		Net._sync_players.rpc(Net.players)
	_set_offline(hid, true)
	announce_all("%s отключился — его герой ждёт возвращения." % heroes[hid].player_name, Color(1, 0.7, 0.4))

func _on_net_disconnected(reason: String) -> void:
	Net.back_to_menu(reason)

func _exit_tree() -> void:
	if Net.disconnected.is_connected(_on_net_disconnected):
		Net.disconnected.disconnect(_on_net_disconnected)

# ---------------------------------------------------------------- тестовый режим (командная строка)

var _test_t := 0.0
var _log_t := 0.0
var _test_cam: Camera3D = null
var _start_ms := 0

func _process(delta: float) -> void:
	_update_music(delta)
	ModelFactory.pulse(now())      # мерцание эпических вещей на героях
	if Net.cli.is_empty():
		return
	var siege: SiegeMode = mode as SiegeMode    # хуки волн — только для осады
	if _start_ms == 0:
		_start_ms = Time.get_ticks_msec()
	delta = (Time.get_ticks_msec() - _start_ms) * 0.001 - _test_t
	_test_t += delta
	if Net.cli.has("pauseat") and _test_t >= float(Net.cli["pauseat"]):
		Engine.time_scale = 0.0
	_log_t += delta
	if _log_t >= 5.0:
		_log_t = 0.0
		var lh = local_hero
		if lh:
			print("   talents=%s  bar=%s" % [str(lh.talents), str(lh.controller.bar)])
		print("[t=%d] fps=%d wave=%d mobs=%d castle=%d hero_lvl=%d xp=%d hp=%d/%d mana=%d gold=%d" % [
			int(_test_t), Engine.get_frames_per_second(), siege.wave if siege else 0,
			mobs.alive_count() if is_server() else mobs.client_alive_count, int(siege.castle.hp) if siege else 0,
			lh.unit.level if lh else 0, lh.xp if lh else 0, int(lh.unit.hp) if lh else 0, int(lh.unit.max_hp) if lh else 0,
			int(lh.unit.mana) if lh else 0, lh.gold if lh else 0])
	if Net.cli.has("chasedebug") and _test_t >= 1.0 and _test_t - delta < 1.0:
		for i in siege.lanes.size():
			print("LANE ", i, " ", siege.lanes[i])
	if Net.cli.has("chasedebug") and Net.cli.has("post") and _test_t >= 1.5 and _test_t - delta < 1.5:
		var pf: PackedFloat64Array = Net.cli["post"].split_floats(",")
		local_hero.global_position = Vector3(pf[0], 0.5, pf[1])
	if Net.cli.has("chasedebug") and is_server() and _log_t == 0.0:
		print("CHASE chases=%d drops=%d flips=%d hero=%s" % [mobs.dbg_chases, mobs.dbg_drops, mobs.dbg_flips, local_hero.global_position if local_hero else Vector3.ZERO])
	# --forcewin=T: засчитать победу на T-й секунде (проверка «Похода»: угроза растёт после победы)
	if Net.cli.has("forcewin") and is_server() and _test_t >= float(Net.cli["forcewin"]) and _test_t - delta < float(Net.cli["forcewin"]):
		mode.finish(true)
	# --savesiege=T: хост сохраняет осаду на T-й секунде и выходит (проверка «Сохранить осаду и продолжить»)
	if Net.cli.has("savesiege") and is_server() and _test_t >= float(Net.cli["savesiege"]) and _test_t - delta < float(Net.cli["savesiege"]):
		print("SIEGE SAVED ", SiegeSave.save(self), " wave=", (mode as SiegeMode).wave, " castle=", int((mode as SiegeMode).castle.hp))
		for h in heroes.values():
			print("HERO ", h.player_name, " lvl=", h.unit.level, " xp=", h.xp, " gold=", h.gold, " talents=", h.talents.size(), " equip=", h.equip.size(), " bag=", h.bag.filter(func(s): return s != null).size())
		Sfx.quit_game.call_deferred()
	if Net.cli.has("level") and is_server() and _test_t >= 1.0 and _test_t - delta < 1.0:
		for h in heroes.values():
			while h.unit.level < int(Net.cli["level"]):
				give_xp(h, h.xp_next - h.xp)
	# --choices=213 — столбец (1–3) для каждого ряда книги по порядку; одна цифра — для всех рядов
	if Net.cli.has("choices") and is_server() and _test_t >= 1.1 and _test_t - delta < 1.1:
		var code := str(Net.cli["choices"])
		for h in heroes.values():
			if not GameData.BOOKS.has(h.class_id):
				continue
			var rows: Array = GameData.BOOKS[h.class_id]["rows"]
			var c := {}
			for i in rows.size():
				var col := clampi(int(code[mini(i, code.length() - 1)]) - 1, 0, 2)
				c[i] = rows[i]["options"][col]
			ev_choices.rpc(h.hero_id, c)
	if Net.cli.has("cam") and _test_cam == null:
		var parts: PackedStringArray = Net.cli["cam"].split(":")
		var a := parts[0].split_floats(",")
		var b := parts[1].split_floats(",")
		_test_cam = Camera3D.new()
		add_child(_test_cam)
		_test_cam.look_at_from_position(Vector3(a[0], a[1], a[2]), Vector3(b[0], b[1], b[2]))
		_test_cam.fov = 50.0
		_test_cam.current = true
	if Net.cli.has("charwin") and _test_t >= float(Net.cli["charwin"]) and _test_t - delta < float(Net.cli["charwin"]):
		hud.toggle_character()   # --charwin=T: открыть окно персонажа (снимок)
	# --hover=x,y: через 1 сек. после --charwin навести мышь на точку экрана — снимок всплывающей подсказки
	if Net.cli.has("hover") and Net.cli.has("charwin") and _test_t >= float(Net.cli["charwin"]) + 1.0 and _test_t - delta < float(Net.cli["charwin"]) + 1.0:
		var hp: PackedFloat64Array = str(Net.cli["hover"]).split_floats(",")
		get_viewport().warp_mouse(Vector2(hp[0], hp[1]))
		var mm := InputEventMouseMotion.new()
		mm.position = Vector2(hp[0], hp[1])
		mm.global_position = mm.position
		get_viewport().push_input(mm)
	if Net.cli.has("shot2") and absf(_test_t - float(Net.cli["shot2"])) < delta * 0.5 + 0.001:
		_save_shot(Net.cli.get("shot", "user://shot.png").get_basename() + "_b.png")
	if Net.cli.has("freezeall") and is_server() and absf(_test_t - float(Net.cli["freezeall"])) < delta * 0.5 + 0.001:
		for u in mobs.alive_units():
			spells._freeze(u, 10.0, now())
	if Net.cli.has("walltest") and _test_t >= 3.0 and _test_t - delta < 3.0:
		spells.send_to_server("request_cast", ["ice_wall", 0, Vector3(0, 0, 22), 0.6, 6.0])
	if Net.cli.has("walltest") and _test_t >= 5.0 and _test_t - delta < 5.0:
		spells.send_to_server("request_cast", ["fire_wall", 0, Vector3(0, 0, 24), 0.0, 8.0])
	if Net.cli.has("walldmg") and is_server():
		for st in [1, 2]:
			if _test_t >= 4.0 + st and _test_t - delta < 4.0 + st:
				for id in mobs.walls:
					var w: Dictionary = mobs.walls[id]
					w["hp"] = w["max"] * (0.45 if st == 1 else 0.2)
					w["stage"] = st
					mobs.ev_wall_damage.rpc(id, st)
					print("WALL ", id, " stage=", st, " hp=", int(w["hp"]), "/", int(w["max"]))
	if Net.cli.has("walltest") and _test_t >= 6.0 and _test_t - delta < 6.0:
		for id in mobs.walls:
			print("WALL ", id, " len=", (mobs.walls[id]["a"] as Vector2).distance_to(mobs.walls[id]["b"]))
		for id in spells.zones:
			print("ZONE ", spells.zones[id]["sid"], " len=", (spells.zones[id]["a"] as Vector3).distance_to(spells.zones[id]["b"]))
	if Net.cli.has("posedebug") and _test_t >= 9.0 and _test_t - delta < 9.0:
		for m in mobs.mobs.values():
			var sk: Skeleton3D = m.node.find_child("Skeleton3D", true, false)
			var bi := sk.find_bone("upperarm.l")
			var diff := sk.get_bone_pose_rotation(bi).angle_to(sk.get_bone_rest(bi).basis.get_rotation_quaternion())
			print("MOB %s anim=%s playing=%s pos=%.2f st=%d armdiff=%.2f merged=%s" % [m.unit.type_id, m.anim.current_animation, m.anim.is_playing(), m.anim.current_animation_position, m.anim_state, diff, sk.has_node("MergedBody")])
	if Net.cli.has("mergedebug") and _test_t >= 9.0 and _test_t - delta < 9.0:
		var mm = mobs.mobs.values()[0]
		var sk2: Skeleton3D = mm.node.find_child("Skeleton3D", true, false)
		for c in sk2.get_children():
			if c is MeshInstance3D:
				var fm: int = c.mesh.surface_get_format(0)
				print("MI ", c.name, " fmt=", fm, " bones=", (fm & Mesh.ARRAY_FORMAT_BONES) != 0, " skin=", c.skin != null, " path=", c.skeleton, " resolved=", c.get_node_or_null(c.skeleton), " skinref=", c.get_skin_reference() != null)
	if Net.cli.has("lanedebug") and _test_t >= 14.0 and _test_t - delta < 14.0:
		var per := {}
		for m in mobs.mobs.values():
			per[m.route] = per.get(m.route, 0) + 1
		print("LANES active=", siege.active_lanes, " mobs_per_lane=", per)
	if Net.cli.has("gold") and is_server() and _test_t >= 1.0 and _test_t - delta < 1.0:
		for h in heroes.values():
			h.gold = int(Net.cli["gold"])
			h.bag_add("potion_heal_2", 5)
			h.bag_add("potion_mana_2", 5)
			h.bag_add("elixir_haste", 2)
			# по вещи каждого качества (зелёная, синяя, фиолетовая с проком, легендарная) — проверка подсказок и проков
			h.bag_add(GameData.make_gear("sword", 10, 1))
			h.bag_add(GameData.make_gear("axe", 15, 2))
			h.bag_add(GameData.make_gear("plate", 10, 3))
			h.bag_add(GameData.make_gear("staff", 12, 4))
			h.bag_add(GameData.make_gear("robe", 12, 3))
			h.bag_add(GameData.make_gear("pads_mail", 10, 2))   # плечи — проверка раскладки окна персонажа
			# аксессуары: фиолетовый, синий и зелёный
			h.bag_add(GameData.make_gear("tr_thunder", 10, 3))
			h.bag_add(GameData.make_gear("tr_guard" if h.class_id in ["warrior", "paladin"] else "tr_ember", 10, 2))
			h.bag_add(GameData.make_gear("tr_seal", 8, 1))
			economy._sync(h)
	# --trinkets=a_thunder,u_berserk: надеть аксессуары с этими проками / используемыми эффектами (фиолетовые)
	if Net.cli.has("trinkets") and is_server() and _test_t >= 1.2 and _test_t - delta < 1.2:
		for h in heroes.values():
			var pids: PackedStringArray = str(Net.cli["trinkets"]).split(",", false)
			for k in mini(pids.size(), 2):
				var pid: String = pids[k]
				var base := ""
				for tb in GameData.ItemData.TRINKETS:
					if GameData.ItemData.TRINKETS[tb]["procs"].has(pid):
						base = tb
						break
				if base == "":
					push_warning("--trinkets: нет аксессуара с %s" % pid)
					continue
				var d: Dictionary = GameData.ItemData.roll(base, h.unit.level, 3, randi() % 1000000)
				d["proc"] = pid
				var tid: String = GameData.ItemData.encode(d)
				var slot: String = GameData.ItemData.TRINKET_SLOTS[k]
				h.equip[slot] = tid
				if GameData.ItemData.use_of(tid) != "":
					h.use_ready.erase(GameData.ItemData.use_of(tid))
			h.apply_level_stats(false)
			economy._sync(h)
			print("TRINKETS ", h.class_id, " ", h.equip, " procs=", h.unit.mods.get("procs", []).map(func(p): return p["id"]))
	# --giveset=<id сета>|auto (сет ветки --bottree) и --giveleg=<id>|auto: полный сет и легендарка каждому герою своего класса
	if (Net.cli.has("giveset") or Net.cli.has("giveleg")) and is_server() and _test_t >= 2.0 and _test_t - delta < 2.0:
		for h in heroes.values():
			var gsid := str(Net.cli.get("giveset", ""))
			if gsid == "auto":
				for s in GameData.SetData.SETS:
					if GameData.SetData.SETS[s]["class"] == h.class_id and int(GameData.SetData.SETS[s]["tree"]) == int(Net.cli.get("bottree", 0)):
						gsid = s
			if GameData.SetData.SETS.has(gsid) and GameData.SetData.SETS[gsid]["class"] == h.class_id:
				for slot in GameData.SetData.SLOTS:
					h.equip[slot] = GameData.make_set_piece(gsid, slot, h.unit.level)
			var glid := str(Net.cli.get("giveleg", ""))
			if glid == "auto":
				for l in GameData.SetData.LEGENDARIES:
					if GameData.SetData.LEGENDARIES[l]["class"] == h.class_id:
						glid = l
						break
			if GameData.SetData.LEGENDARIES.has(glid):
				var lit := GameData.make_legendary(glid, h.unit.level)
				var lslot: String = GameData.item(lit)["slot"]
				h.equip["trinket1" if lslot == "trinket" else lslot] = lit
				if GameData.ItemData.is_two_handed(lit):
					h.equip.erase("offhand")
			h.apply_level_stats(false)
			economy._sync(h)
			print("GIVESET ", h.class_id, " sets=", GameData.set_counts(h.equip), " procs=", h.unit.mods["procs"].map(func(p): return p["id"]), " flags=", h.unit.mods["flags"].keys())
	# --outfit=<уровень>:<качество>: надеть оружие класса (у каждого героя — своё по порядку шаблонов) и броню
	if Net.cli.has("outfit") and is_server() and _test_t >= 1.5 and _test_t - delta < 1.5:
		var op: PackedStringArray = (Net.cli["outfit"] + ":").split(":")
		var oil: int = int(op[0]) if op[0].is_valid_int() else 25
		var oq: int = int(op[1]) if op[1].is_valid_int() else 4
		# третье поле — вариант набора: сдвигает выбор оружия, шлема, доспеха и левой руки
		var hi: int = int(op[2]) if op.size() > 2 and op[2].is_valid_int() else 0
		for h in heroes.values():
			var bases: Array = preload("res://tools/hero_shot.gd").outfit_bases(h.class_id, hi)
			hi += 1
			for b in bases:
				h.bag_add(GameData.make_gear(b, oil, oq))
			for i in h.bag.size():
				if h.bag[i] != null and GameData.item(h.bag[i]["id"])["kind"] == "gear":
					economy._equip(h, i)
			print("OUTFIT ", h.class_id, " ", h.equip)
	if Net.cli.has("equip") and is_server() and _test_t >= float(Net.cli["equip"]) and _test_t - delta < float(Net.cli["equip"]):
		for h in heroes.values():
			for i in h.bag.size():
				if h.bag[i] != null and GameData.item(h.bag[i]["id"])["kind"] == "gear":
					economy._equip(h, i)
			print("EQUIP ", h.equip, " dual=", h.unit.flag("dual_wield"), " ap=", h.attack_power, " phys=", h.unit.phys_power, " procs=", h.unit.mods.get("procs", []), " talents=", h.talents)
	if Net.cli.has("givebuff") and is_server() and _test_t >= 2.0 and _test_t - delta < 2.0:
		var bsp: Dictionary = GameData.SPELLS[Net.cli["givebuff"]]
		spells.apply_effects(local_hero.unit, local_hero.unit, bsp["effects"], Net.cli["givebuff"], "holy")
	if Net.cli.has("walldraw") and _test_t >= 3.0 and _test_t - delta < 3.0:
		var ctl = local_hero.controller
		var wsid: String = Net.cli["walldraw"]
		ctl.try_cast(wsid)
		var pa: Vector2 = ctl.camera.unproject_position(Vector3(-4, 0, 26))
		var pb: Vector2 = ctl.camera.unproject_position(Vector3(5, 0, 31))
		var ev1 := InputEventMouseButton.new()
		ev1.button_index = MOUSE_BUTTON_LEFT
		ev1.pressed = true
		ev1.position = pa
		Input.parse_input_event(ev1)
		var ev2 := InputEventMouseButton.new()
		ev2.button_index = MOUSE_BUTTON_LEFT
		ev2.pressed = false
		ev2.position = pb
		Input.parse_input_event(ev2)
	if Net.cli.has("walldraw") and _test_t >= 4.0 and _test_t - delta < 4.0:
		for id in mobs.walls:
			print("DRAWN WALL len=%.2f a=%s b=%s" % [(mobs.walls[id]["a"] as Vector2).distance_to(mobs.walls[id]["b"]), mobs.walls[id]["a"], mobs.walls[id]["b"]])
		for id in spells.zones:
			print("DRAWN ZONE len=%.2f" % (spells.zones[id]["a"] as Vector3).distance_to(spells.zones[id]["b"]))
	if Net.cli.has("open") and _test_t >= 9.0 and _test_t - delta < 9.0:
		if Net.cli["open"] == "char":
			hud.toggle_character()
		elif Net.cli["open"] == "shop":
			local_hero.global_position = economy.vendor_pos["smith"] + Vector3(2, 0, 2)
			hud.open_shop("smith")
		elif Net.cli["open"] == "edit":
			hud.set_edit_mode(true)
		elif Net.cli["open"] == "keys":
			hud.toggle_keybinds()
		elif Net.cli["open"] == "talents":
			hud.toggle_talents()
		else:
			hud.toggle_spellbook()
	# --poslog — раз в 5 сек. позиции всех героев глазами этого процесса (проверка сетевого движения)
	if Net.cli.has("poslog") and fmod(_test_t, 5.0) < delta:
		for h in heroes.values():
			print("POS me=%d hero=%d local=%s pos=(%.1f, %.1f) alive=%s stun=%.1f spd=%.2f fwd=%.1f" % [Net.my_id(), h.peer_id, h.is_local, h.global_position.x, h.global_position.z, h.unit.alive, h.net_stun_left, h.net_speed, h.controller.move_forward if h.controller else 0.0])
	# --testcast=fire_dash — герой произносит заклинание на 9-й секунде (точка — 9 м перед ним)
	if Net.cli.has("testcast") and is_server() and _test_t >= 9.0 and _test_t - delta < 9.0:
		var fwd3 := -local_hero.global_transform.basis.z
		spells._complete_cast(local_hero, Net.cli["testcast"], local_hero.unit.id, local_hero.global_position + fwd3 * 9.0, local_hero.rotation.y)
	# --chaselog: раз в секунду — сколько врагов гонится за героем (проверка Зеркальных копий, Притворства)
	if Net.cli.has("chaselog") and is_server() and int(_test_t) != int(_test_t - delta):
		var chasing := 0
		for cm in mobs.mobs.values():
			if cm.target == local_hero.unit.id:
				chasing += 1
		print("CHASE t=%d за героем: %d" % [int(_test_t), chasing])
	if Net.cli.has("autotest") and is_server() and _test_t >= 3.0 and _test_t - delta < 3.0:
		var fwd := -local_hero.global_transform.basis.z
		spells.cast_auto_spell(local_hero.unit, Net.cli["autotest"], local_hero.global_position + fwd * 9.0, now())
	if Net.cli.has("giveproc") and is_server() and _test_t >= 3.0 and _test_t - delta < 3.0:
		local_hero.unit.add_buff(Net.cli["giveproc"], now() + 30.0, {})
	if Net.cli.has("targetally") and _test_t >= 8.0 and _test_t - delta < 8.0:
		for th in heroes.values():
			if th != local_hero:
				local_hero.controller.target_id = th.hero_id
				th.unit.add_buff("weakened_soul", now() + 30.0, {})
	if Net.cli.has("fxdemo") and is_server() and _test_t >= float(Net.cli["fxdemo"]) and _test_t - delta < float(Net.cli["fxdemo"]):
		var best: Unit = null
		for mu in mobs.alive_units():
			if best == null or mu.pos.distance_to(local_hero.unit.pos) < best.pos.distance_to(local_hero.unit.pos):
				best = mu
		if best:
			local_hero.controller.target_id = best.id
			var lu: Unit = local_hero.unit
			spells.apply_effects(lu, best, [{"type": "slow", "pct": 0.4, "dur": 20.0}, {"type": "chill", "stacks": 3, "dur": 3.0}, {"type": "chill", "stacks": 3, "dur": 3.0},
				{"type": "dot", "total": 6.0, "dur": 20.0, "tick": 2.0, "key": "ignite"}], "frostbolt", "frost")
			spells.apply_effects(null, best, [{"type": "dot", "total": 6.0, "dur": 20.0, "tick": 2.0, "key": "burn"}], "fire_wall", "fire")
			# эффекты книги заклинаний (описание собирается из заклинания): Кровопускание и Раскол брони
			spells.apply_effects(lu, best, GameData.SPELLS["rend"]["effects"], "rend", "physical")
			spells.apply_effects(lu, best, [GameData.SPELLS["sunder_armor"]["effects"][1]], "sunder_armor", "physical")
	if Net.cli.has("marktest") and _test_t >= float(Net.cli["marktest"]) and _test_t - delta < float(Net.cli["marktest"]):
		var near: Array = units.values().filter(func(mu): return mu.kind == "mob" and mu.alive)
		near.sort_custom(func(a, b): return a.pos.distance_to(local_hero.unit.pos) < b.pos.distance_to(local_hero.unit.pos))
		if near.size() >= 2:
			local_hero.controller.target_id = near[0].id
			marks.send("request_mark", [near[0].id, 8])
			marks.send("request_mark", [near[1].id, 1])
			marks.send("request_ping", [near[1].pos, near[1].id])
		var fwd := -local_hero.global_transform.basis.z
		get_tree().create_timer(1.1).timeout.connect(func(): marks.send("request_ping", [local_hero.global_position + fwd * 6.0, 0]))
		print("MARKS ", marks.marks)
	if Net.cli.has("mobtest") and is_server() and _test_t >= 3.0 and _test_t - delta < 3.0:
		var want: String = Net.cli["mobtest"]
		var types: Array = []
		for mid in GameData.MOBS:
			var md: Dictionary = GameData.MOBS[mid]
			if mid == want or (md.get("faction", "") == want and not md["role"] in ["boss", "test", "summon"]) \
					or (want == "bosses" and (md["role"] == "boss" or md.get("boss_look", false))):
				types.append(mid)
		var fwd := -local_hero.global_transform.basis.z
		var side := fwd.cross(Vector3.UP)
		for i in types.size():
			var p3: Vector3 = local_hero.global_position + fwd * (4.0 if Net.cli.has("near") else 9.0) + side * (float(i) - float(types.size() - 1) * 0.5) * 2.6
			var uid: int = mobs.spawn(types[i], 2, 5, 1, 1.0, {"pos": Vector2(p3.x, p3.z)})
			var mu: Unit = get_unit(uid)
			if not Net.cli.has("near"):
				mu.root_until = now() + 1e6     # стоят на месте для осмотра
		print("MOBTEST ", types, " центр ", local_hero.global_position + fwd * (4.0 if Net.cli.has("near") else 9.0), " взгляд ", fwd)
	if Net.cli.has("casttest") and is_server() and _test_t >= 3.0 and _test_t - delta < 3.0:
		var cfwd := -local_hero.global_transform.basis.z
		var cp := local_hero.global_position + cfwd * 8.0
		var cid: int = mobs.spawn("cast_dummy", 2, 5, 1, 1.0, {"pos": Vector2(cp.x, cp.z)})
		get_unit(cid).root_until = now() + 1e6
		local_hero.controller.target_id = cid
	if Net.cli.has("godmode") and is_server():
		for gh in heroes.values():
			gh.unit.hp = maxf(gh.unit.hp, gh.unit.max_hp * 0.35)   # не погибает, но лекарю есть кого лечить
			gh.unit.alive = true
	if Net.cli.has("manalog") and is_server():
		_manalog_tick()
	if Net.cli.has("focustest"):
		_focus_test_step()
	if Net.cli.has("vfxtest") and _test_t >= 2.0 and _test_t - delta < 2.0:
		_vfx_showcase()
	if Net.cli.has("startwave") and siege and is_server() and siege.wave == 0 and _test_t > 1.0:
		siege.wave = int(Net.cli["startwave"]) - 1
		siege._next_wave_at = now()
	if Net.cli.has("wavegap") and siege and is_server() and siege.wave > 0 and siege._next_wave_at - now() > float(Net.cli["wavegap"]):
		siege._next_wave_at = now() + float(Net.cli["wavegap"])
	if Net.cli.has("fastwaves") and siege and is_server() and _test_t > 3.0 and siege.wave == 0:
		siege._next_wave_at = now()
	if Net.cli.has("shot-at") and absf(_test_t - float(Net.cli["shot-at"])) < delta * 0.5 + 0.001:
		_save_shot(Net.cli.get("shot", "user://shot.png"))
	# --balancelog: партия кончилась — итог и выход через 2 сек.
	if Net.cli.has("balancelog") and siege and is_server() and mode.is_over() and not Net.cli.has("bal-done"):
		Net.cli["bal-done"] = "1"
		print(siege.balance_summary())
		Net.cli["quit-after"] = str(_test_t + 2.0)
	if Net.cli.has("quit-after") and _test_t >= float(Net.cli["quit-after"]) and not Sfx._quitting:
		if Net.cli.has("shot"):
			_save_shot(Net.cli["shot"].get_basename() + "_end.png")
		if Net.cli.has("manalog"):
			_manalog_summary()
		if Net.cli.has("lootsim"):
			print(economy.lootsim_report())
		if Net.cli.has("marktest"):
			print("MARKS END ", marks.marks)
		if Net.cli.has("meterlog"):
			meter.request_detail("total", local_hero.hero_id, "dmg")
			print("METER total=", meter.view["total"]["rows"], " current=", meter.view["current"]["name"], " last=", meter.view["last"]["name"])
			print("METER detail=", meter.detail.get("list", []).map(func(e): return [meter.key_name(e[0]), int(e[1]), e[2], e[3]]))
		print("TEST END: wave=%d state=%s castle=%d" % [siege.wave if siege else 0, mode.state, int(siege.castle.hp) if siege else 0])
		if Net.cli.has("balancelog") and siege and not Net.cli.has("bal-done"):
			print(siege.balance_summary())
		Sfx.quit_game()

func _save_shot(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("shot saved: ", path)

## --vfxtest: показать все эффекты областей перед героем (для проверки визуала).
func _vfx_showcase() -> void:
	Vfx.zone(self, 900001, "zone_blizzard", Vector3(-9, 0, 30), 0.0, 7.0, 30.0)
	Vfx.zone(self, 900002, "zone_consecration", Vector3(9, 0, 27), 0.0, 7.0, 30.0)
	Vfx.zone(self, 900003, "zone_barrier", Vector3(0, 0, 24), 0.0, 5.0, 30.0)
	Vfx.zone(self, 900004, "wall_ice", Vector3(-6, 0, 40), 0.0, 12.0, 30.0)
	Vfx.zone(self, 900005, "wall_fire", Vector3(9, 0, 40), 0.0, 12.0, 30.0)
	Vfx.zone(self, 900006, "zone_flamestrike", Vector3(18, 0, 32), 0.0, 6.0, 30.0)
	Vfx.spawn(self, "nova_frost", Vector3(-16, 0, 22), Vector3.ZERO, 8.0, 0)
	Vfx.spawn(self, "beam_holy", Vector3(4, 0, 34), Vector3.ZERO, 0.0, 0)
	if local_hero:
		Vfx.spawn(self, "heal_burst", local_hero.global_position, Vector3.ZERO, 0.0, local_hero.hero_id)
		local_hero.net_absorb = 50.0

## Дороги и площадь у замка — серая брусчатка.
func _apply_cobblestone() -> void:
	var roads := map.get_node_or_null("Roads") as MeshInstance3D
	if roads == null:
		return
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/cobblestone.gdshader")
	roads.material_override = mat
## Музыка по ходу осады: бой во время волн, спокойная — на подготовке и передышке.
var _music_t := 0.0
func _update_music(delta: float) -> void:
	_music_t -= delta
	if _music_t > 0.0:
		return
	_music_t = 0.5
	var track := "rest"
	if mode.is_combat():
		track = "battle"
		for bid in mobs.boss_state:
			if mobs.mobs.has(bid):
				track = "boss"      # на время боя с боссом — своя музыка
				break
	Sfx.play_music(track)
## --focustest: клик мышью по кнопкам у панели, закрытие окон, затем Пробел —
## герой должен прыгнуть, а окна не открыться (кнопки HUD не берут фокус).
var _ft_step := 0
var _ft_y0 := 0.0
var _ft_max_y := 0.0

func _focus_test_step() -> void:
	var steps := [3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 6.0, 6.6]
	if _ft_step >= steps.size() or _test_t < steps[_ft_step]:
		if _ft_step == 7:
			_ft_max_y = maxf(_ft_max_y, local_hero.global_position.y)
		return
	var btns: Array = [hud._talent_btn, hud._book_btn, hud._char_btn]
	match _ft_step:
		0, 2, 4:
			var b: Control = btns[_ft_step / 2]
			_ft_click(b.get_global_rect().get_center())
		1, 3, 5:
			var shown: Array = []
			for w in [hud._talent_window, hud._spellbook, hud._char_window]:
				if w and w.visible:
					shown.append(w.name)
			print("FOCUS click opened: ", shown)
			_ft_key(KEY_ESCAPE)
		6:
			_ft_y0 = local_hero.global_position.y
			_ft_max_y = _ft_y0
			print("FOCUS owner before space: ", get_viewport().gui_get_focus_owner())
			_ft_key(KEY_SPACE)
			_ft_key(KEY_TAB)
		7:
			var open: Array = []
			for w in [hud._talent_window, hud._spellbook, hud._char_window]:
				if w and w.visible:
					open.append(w.name)
			print("FOCUS TEST: jumped=%s (dy=%.2f) open_windows=%s focus=%s" % [_ft_max_y - _ft_y0 > 0.3, _ft_max_y - _ft_y0, open, get_viewport().gui_get_focus_owner()])
	_ft_step += 1

func _ft_click(p: Vector2) -> void:
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = p
		ev.global_position = p
		Input.parse_input_event(ev)

func _ft_key(code: Key) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.pressed = pressed
		Input.parse_input_event(ev)

## --manalog: раз в 5 с — мана, расход, урон и лечение в секунду; момент, когда мана впервые кончилась.
## В конце (--quit-after) — итог за минуту по каждому герою. Нужен для баланса маны и перезарядок.
var _ml_t := 0.0
var _ml_prev: Dictionary = {}       # hero_id -> [spent, dmg, heal]
var _ml_empty: Dictionary = {}      # hero_id -> время, когда мана впервые упала ниже 10%
var _ml_start: Dictionary = {}      # hero_id -> время начала боя (первая трата)

func _manalog_tick() -> void:
	for h in heroes.values():
		var u: Unit = h.unit
		if u.stat_spent > 0.0 and not _ml_start.has(h.hero_id):
			_ml_start[h.hero_id] = _test_t
		if u.resource == "mana" and _ml_start.has(h.hero_id) and not _ml_empty.has(h.hero_id) and u.mana < u.max_mana * 0.1:
			_ml_empty[h.hero_id] = _test_t
			print("MANA EMPTY %s (%s): через %.0f с боя, t=%.0f" % [h.player_name, h.class_id, _test_t - float(_ml_start[h.hero_id]), _test_t])
	if _test_t - _ml_t < 5.0:
		return
	var dt := _test_t - _ml_t
	_ml_t = _test_t
	for h in heroes.values():
		var u: Unit = h.unit
		var prev: Array = _ml_prev.get(h.hero_id, [0.0, 0.0, 0.0])
		print("MANA %s %s lvl=%d mana=%d/%d (%d%%) расход=%.1f/с урон=%.0f/с лечение=%.0f/с" % [h.player_name, h.class_id, u.level,
			int(u.mana), int(u.max_mana), int(u.mana / maxf(u.max_mana, 1.0) * 100.0),
			(u.stat_spent - prev[0]) / dt, (u.stat_dmg - prev[1]) / dt, (u.stat_heal - prev[2]) / dt])
		_ml_prev[h.hero_id] = [u.stat_spent, u.stat_dmg, u.stat_heal]

func _manalog_summary() -> void:
	for h in heroes.values():
		var u: Unit = h.unit
		var fight := maxf(1.0, _test_t - float(_ml_start.get(h.hero_id, 0.0)))
		print("BALANCE %s %s lvl=%d: урон %.0f/мин, лечение %.0f/мин, мана %.0f/мин, мана кончилась: %s" % [h.player_name, h.class_id, u.level,
			u.stat_dmg / fight * 60.0, u.stat_heal / fight * 60.0, u.stat_spent / fight * 60.0,
			"через %.0f с" % (float(_ml_empty[h.hero_id]) - float(_ml_start[h.hero_id])) if _ml_empty.has(h.hero_id) else "нет"])

## Звук в точке мира у всех игроков (клич фракции со стороны её логова).
@rpc("authority", "call_local", "unreliable")
func ev_sound_at(snd: String, pos: Vector3, vol: float, pitch: float) -> void:
	Sfx.play_at(snd, pos, vol, pitch)

# ---------------------------------------------------------------- отключение, переподключение, поздний вход (сессия 07)

## Герои, чьи игроки сейчас в игре (сила волн считается по ним).
func online_hero_count() -> int:
	var n := 0
	for h in heroes.values():
		if not h.offline:
			n += 1
	return maxi(1, n)

## Сервер: игрок пришёл посреди партии. Тот же uid — его отключённый герой; иначе — новый герой (поздний вход).
## false — пустить нельзя (поздний вход выключен или отряд полон).
func server_join(peer: int, rec: Dictionary) -> bool:
	for pid in Net.players.keys():
		var old: Dictionary = Net.players[pid]
		if str(old.get("uid", "")) != "" and str(old.get("uid", "")) == str(rec.get("uid", "")) and old.get("offline", false):
			# переподключение: та же запись игрока и тот же герой, новый транспорт
			Net.players.erase(pid)
			old["offline"] = false
			old["version"] = rec.get("version", "")
			Net.players[peer] = old
			var h = heroes.get(int(old["hero_id"]), null)
			if h:
				h.peer_id = peer
			_rejoining[peer] = int(old["hero_id"])
			ev_rebind_hero.rpc(int(old["hero_id"]), peer)
			announce_all("%s вернулся в игру." % old["name"], Color(0.6, 1.0, 0.7))
			return true
	if not bool(Net.settings.get("late_join", true)):
		return false
	var online := 0
	for pid in Net.players:
		if not Net.players[pid].get("offline", false):
			online += 1
	if online >= Net.MAX_PLAYERS:
		return false
	var hid := 1
	for h in heroes.keys():
		hid = maxi(hid, int(h) + 1)
	rec["hero_id"] = hid
	Net.players[peer] = rec
	ev_add_hero.rpc(peer, rec)
	_late_setup(heroes[hid])
	_rejoining[peer] = hid
	announce_all("%s присоединился к осаде." % rec["name"], Color(0.6, 1.0, 0.7))
	return true

var _rejoining: Dictionary = {}       # сервер: peer -> hero_id, ждём, пока у него загрузится мир

## Поздний вход: уровень — медиана уровней отряда, немного золота на старт. В «Походе» — свой сохранённый герой.
func _late_setup(h) -> void:
	var saved: Dictionary = HeroSave.sanitize(Net.players.get(h.peer_id, {}).get("character", null))
	if not saved.is_empty() and saved["class"] == h.class_id:
		HeroSave.apply(self, h, saved)
		return
	var levels: Array = []
	for o in heroes.values():
		if o != h and not o.offline:
			levels.append(o.unit.level)
	levels.sort()
	var lvl: int = levels[levels.size() / 2] if not levels.is_empty() else 1
	h.unit.level = lvl
	h.xp_next = GameData.xp_to_next(lvl)
	h.gold = 25 * lvl
	h.apply_level_stats(true)

## Создать героя игрока, вошедшего посреди партии (у всех, кто уже в игре).
@rpc("authority", "call_local", "reliable")
func ev_add_hero(pid: int, info: Dictionary) -> void:
	Net.players[pid] = info
	var hid := int(info["hero_id"])
	if heroes.has(hid):
		return
	var hero: CharacterBody3D = HeroScript.new()
	hero.name = "Hero_%d" % hid
	hero.setup(self, hid, pid, info)
	hero.position = mode.respawn_point(hero)
	hero.rotation.y = mode.hero_spawn_yaw()
	heroes_root.add_child(hero)
	heroes[hid] = hero
	units[hid] = hero.unit
	hud.rebuild_party()

## Игрок вернулся: герой теперь управляется с нового соединения.
@rpc("authority", "call_local", "reliable")
func ev_rebind_hero(hid: int, peer: int) -> void:
	var h = heroes.get(hid, null)
	if h:
		h.peer_id = peer

## Отключён / вернулся: герой скрыт, враги его не видят, опыт не идёт; рамка в группе серая.
@rpc("authority", "call_local", "reliable")
func ev_hero_offline(hid: int, off: bool) -> void:
	var h = heroes.get(hid, null)
	if h == null:
		return
	h.offline = off
	h.visible = not off
	if is_server():
		h.unit.alive = not off
		h.respawn_at = 0.0
		if off:
			spells._interrupt(h)
			h.unit.auras.clear()
	hud.rebuild_party()

func _set_offline(hid: int, off: bool) -> void:
	ev_hero_offline.rpc(hid, off)

## Сервер: полный снимок мира тому, кто загрузился посреди партии — герои, враги и питомцы, добыча,
## зоны, стены, ловушки, облик. Состояние режима (волна, таймер, замок) идёт само раз в 0,5 сек.
func send_full_state(peer: int) -> void:
	for h in heroes.values():
		ev_hero_full.rpc_id(peer, h.hero_id, HeroSave.capture(h), h.global_position, h.offline)
	mobs.send_full(peer)
	economy.send_loot(peer)
	spells.send_zones(peer)
	economy.send_all_looks(peer)

## Клиент: состояние героя целиком (уровень, таланты, книга, снаряжение, сумка, золото, место).
@rpc("authority", "reliable")
func ev_hero_full(hid: int, d: Dictionary, pos: Vector3, off: bool) -> void:
	var h = heroes.get(hid, null)
	if h == null:
		return
	h.unit.level = int(d["level"])
	h.xp = int(d["xp"])
	h.gold = int(d["gold"])
	h.equip = d["equip"].duplicate()
	h.bag = d["bag"].duplicate(true)
	h.set_talents(d["talents"])
	h.set_choices(d["choices"])
	h.offline = off
	h.visible = not off
	if not h.is_local:
		h.global_position = pos
	if h == local_hero:
		hud.on_level_changed()
		hud.on_talents_changed()
		hud.on_inventory_changed()
	hud.rebuild_party()

## Сервер, начало партии: сохранённые герои (продолженная осада — по uid игрока, «Поход» — герой из файла игрока),
## отключённые с самого начала — ждут своих игроков.
func _apply_saved_heroes() -> void:
	var siege: Dictionary = Net.pending_siege
	for h in heroes.values():
		var info: Dictionary = Net.players.get(h.peer_id, {})
		var raw: Variant = null
		if not siege.is_empty():
			raw = siege.get("heroes", {}).get(str(info.get("uid", "")), null)
		if raw == null and info.get("character", null) is Dictionary:
			raw = info["character"]
		var d := HeroSave.sanitize(raw)
		if not d.is_empty() and d["class"] == h.class_id:
			HeroSave.apply(self, h, d)
			if not Net.cli.is_empty():
				print("HERO LOADED ", h.player_name, " lvl=", h.unit.level, " xp=", h.xp, " gold=", h.gold, " talents=", h.talents.size(), " equip=", h.equip.size(), " bag=", h.bag.filter(func(s): return s != null).size(), " offline=", h.offline)
		if h.offline:
			h.unit.alive = false

	if is_campaign():
		# уровень угрозы партии — наивысший у героев отряда
		var thr := 0
		for h in heroes.values():
			thr = maxi(thr, h.threat)
		Net.settings["threat"] = thr
		announce_all("Поход: уровень угрозы %d." % thr, Color(1, 0.7, 0.4))
# ---------------------------------------------------------------- «Поход»: угроза, сила врагов, запись героев (сессия 07)

func is_campaign() -> bool:
	return bool(Net.settings.get("campaign", false))

func max_hero_level() -> int:
	var m := 1
	for h in heroes.values():
		m = maxi(m, h.unit.level)
	return m

## Волна, по которой считается сила врагов: в «Походе» — не ниже уровня сильнейшего героя.
func campaign_wave(wave: int) -> int:
	return GameData.Formulas.campaign_wave(wave, max_hero_level()) if is_campaign() else wave

## Множитель угрозы: hp — здоровье врагов, иначе урон.
func threat_k(hp: bool) -> float:
	if not is_campaign():
		return 1.0
	var t := int(Net.settings.get("threat", 0))
	return GameData.Formulas.threat_hp(t) if hp else GameData.Formulas.threat_dmg(t)

## Сервер: записать героев «Похода» — каждому игроку его героя (ev_save_character), свой — сразу в файл.
## После каждой волны, в передышке и в конце партии.
func save_characters() -> void:
	if not is_campaign() or not is_server():
		return
	for h in heroes.values():
		if h.character_id == "":
			continue
		var d := HeroSave.capture(h)
		if h.peer_id == multiplayer.get_unique_id():
			CharacterStore.save(d)
		elif h.peer_id > 0 and not h.offline:
			ev_save_character.rpc_id(h.peer_id, d)

## Клиент: хост прислал моего героя — записать в user://characters/.
@rpc("authority", "reliable")
func ev_save_character(d: Dictionary) -> void:
	CharacterStore.save(d)

## Сервер, конец партии «Похода»: победа — угроза +1; поражение — мягкий штраф: −10% золота (герой не теряется).
func campaign_finish(victory: bool) -> void:
	if not is_campaign():
		return
	for h in heroes.values():
		h.played += 1
		if victory:
			h.threat = maxi(h.threat, int(Net.settings.get("threat", 0)) + 1)
		else:
			h.gold = int(h.gold * 0.9)
	save_characters()

# ---------------------------------------------------------------- итоги партии (сессия 07)
var kills: Dictionary = {}          # сервер: hero_id -> убито врагов (с питомцем)
var items_got: Dictionary = {}      # сервер: hero_id -> получено вещей
var summary: Array = []             # у всех: строки окна итогов

## Сервер, конец партии: итоги каждого героя — всем (окно итогов в любом режиме).
func send_summary() -> void:
	var total: Dictionary = meter.segs["total"]["heroes"]
	var rows: Array = []
	for h in heroes.values():
		var r: Dictionary = total.get(h.hero_id, {})
		rows.append([h.player_name, h.class_id, float(r.get("dmg", 0.0)), float(r.get("heal", 0.0)),
			int(kills.get(h.hero_id, 0)), int(items_got.get(h.hero_id, 0)), h.unit.level, h.threat])
	ev_summary.rpc(rows, int(Net.settings.get("threat", 0)), is_campaign())

@rpc("authority", "call_local", "reliable")
func ev_summary(rows: Array, threat: int, campaign: bool) -> void:
	summary = rows
	summary_threat = threat
	summary_campaign = campaign
	if hud.game_over_shown:
		hud.fill_summary()

var summary_threat := 0
var summary_campaign := false
