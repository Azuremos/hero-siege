extends Node3D
## Корень игровой сцены. Сервер (хост) ведёт всю игровую логику,
## клиенты получают снимки состояния и события.

const HeroScript := preload("res://scripts/world/hero.gd")
const MobManagerScript := preload("res://scripts/world/mob_manager.gd")
const SpellSystemScript := preload("res://scripts/world/spell_system.gd")
const HudScript := preload("res://scripts/ui/hud.gd")
const EconomyScript := preload("res://scripts/world/economy.gd")

var map: Node3D
var heroes_root: Node3D
var vfx_root: Node3D
var mobs: Node            # MobManager
var spells: Node          # SpellSystem
var mode: GameMode        # режим игры (осада, позже подземелья): волны, цели, победа и поражение
var economy: Node         # Economy: торговцы, предметы, добыча
var hud: CanvasLayer

var units: Dictionary = {}        # id -> Unit
var heroes: Dictionary = {}       # hero_id -> Hero
var local_hero: CharacterBody3D = null

## Режимы игры. Выбор режима — Net.settings["mode"]; пока есть только осада.
const MODES := {"siege": preload("res://scripts/modes/siege_mode.gd")}

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
	var mode_script: GDScript = MODES.get(str(Net.settings.get("mode", "siege")), MODES["siege"])
	mode = mode_script.new()
	mode.name = "Mode"
	add_child(mode)
	mode.setup(self)
	economy = EconomyScript.new()
	economy.name = "Economy"
	add_child(economy)

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
		mode.begin()
	else:
		_client_ready.rpc_id(1)

func _read_map() -> void:
	mode.read_map(map)
	mobs.build_static_obstacles(map.get_node("Colliders"))
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
		for b in u.buffs:
			buffs.append([b["key"], maxf(0.0, b["until"] - t)])
		out.append([hid, u.hp, u.max_hp, u.mana, u.max_mana, u.level, h.xp, h.xp_next, h.gold,
			u.absorb if t < u.absorb_until else 0.0, u.alive, maxf(0.0, u.stun_until - t), buffs,
			h.respawn_at - t if not u.alive else 0.0])
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
	_ready_peers[multiplayer.get_remote_sender_id()] = true

func _on_peer_left(peer: int) -> void:
	var hid := 0
	for h in heroes.values():
		if h.peer_id == peer:
			hid = h.hero_id
	if hid == 0:
		return
	var h = heroes[hid]
	heroes.erase(hid)
	units.erase(hid)
	h.queue_free()
	hud.rebuild_party()

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
	if Net.cli.has("level") and is_server() and _test_t >= 1.0 and _test_t - delta < 1.0:
		for h in heroes.values():
			while h.unit.level < int(Net.cli["level"]):
				give_xp(h, h.xp_next - h.xp)
	if Net.cli.has("cam") and _test_cam == null:
		var parts: PackedStringArray = Net.cli["cam"].split(":")
		var a := parts[0].split_floats(",")
		var b := parts[1].split_floats(",")
		_test_cam = Camera3D.new()
		add_child(_test_cam)
		_test_cam.look_at_from_position(Vector3(a[0], a[1], a[2]), Vector3(b[0], b[1], b[2]))
		_test_cam.fov = 50.0
		_test_cam.current = true
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
			h.bag_add("sword_3")
			h.bag_add("axe_4")
			h.bag_add("plate_3")
			economy._sync(h)
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
	if Net.cli.has("autotest") and is_server() and _test_t >= 3.0 and _test_t - delta < 3.0:
		var fwd := -local_hero.global_transform.basis.z
		spells.cast_auto_spell(local_hero.unit, Net.cli["autotest"], local_hero.global_position + fwd * 9.0, now())
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
	if Net.cli.has("quit-after") and _test_t >= float(Net.cli["quit-after"]) and not Sfx._quitting:
		if Net.cli.has("shot"):
			_save_shot(Net.cli["shot"].get_basename() + "_end.png")
		print("TEST END: wave=%d state=%s castle=%d" % [siege.wave if siege else 0, mode.state, int(siege.castle.hp) if siege else 0])
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
