extends Node
## Экономика: торговцы в замке, покупка/продажа, зелья, снаряжение и добыча с врагов.
## Всё решает хост; владельцу героя приходит копия сумки и снаряжения.

const VENDORS := {
	# кузнец — тот же варвар, что и герой-воин, поэтому: перекраска в кожаный фартук, без шапки и плаща,
	# молот вместо топора, наковальня рядом и работа молотом — читается как торговец, а не игрок
	"smith": {"marker": "Blacksmith", "name": "Кузнец Торвальд", "desc": "Оружие и броня", "model": "Barbarian",
		"show": [], "hide": ["Barbarian_Hat", "Barbarian_Cape"], "recolor": "smith", "tool": "hammer", "prop": "anvil",
		"work": {"anim": "1H_Melee_Attack_Chop", "every": 3.2, "hit_at": 0.42}, "kind": "gear"},
	"alchemist": {"marker": "Alchemy", "name": "Алхимик Мирра", "desc": "Зелья и эликсиры", "model": "Rogue_Hooded",
		"show": ["Throwable"], "kind": "consumable"},
}
const VENDOR_RANGE := 9.0
const PICKUP_RANGE := 2.6
const LOOT_TIME := 90.0

var world: Node3D
var vendor_pos: Dictionary = {}       # id -> Vector3
var _vendor_nodes: Dictionary = {}
var _anvil_top: Dictionary = {}       # vid -> наковальня (искры при ударе)
var _work_t: Dictionary = {}          # vid -> время до следующего удара молотом
var _loot: Dictionary = {}            # сервер: id -> {item, pos, until}
var _loot_nodes: Dictionary = {}      # визуал: id -> Node3D
var _next_loot := 1
var _pickup_t := 0.0

func _ready() -> void:
	world = get_parent()

## Торговцы появляются у мастерских (точки Shops на карте).
func spawn_vendors() -> void:
	var shops: Node = world.map.get_node_or_null("Shops")
	for vid in VENDORS:
		var v: Dictionary = VENDORS[vid]
		var m: Node3D = shops.get_node_or_null(v["marker"]) if shops else null
		var pos: Vector3 = m.position if m else Vector3.ZERO
		vendor_pos[vid] = pos
		var holder := Node3D.new()
		var inst := (load("res://assets/heroes/%s.glb" % v["model"]) as PackedScene).instantiate() as Node3D
		holder.add_child(inst)
		var skel := inst.find_child("Skeleton3D", true, false)
		if skel:
			for att in skel.get_children():
				if att is BoneAttachment3D and att.bone_name.begins_with("handslot"):
					for mesh in att.get_children():
						(mesh as Node3D).visible = v["show"].has(mesh.name)
				if att is BoneAttachment3D:
					for mesh in att.get_children():
						if v.get("hide", []).has(mesh.name):
							(mesh as Node3D).visible = false
					if v.get("tool", "") == "hammer" and att.bone_name == "handslot.r":
						var hammer := _make_hammer()
						hammer.rotation_degrees = Vector3(0, -180, 0)
						hammer.position = Vector3(0, 0.033, 0)
						att.add_child(hammer)
		if v.get("recolor", "") != "":
			ModelFactory.recolor_model(inst, v["model"], v["recolor"])
		var ap := ModelFactory.find_anim(holder)
		if ap:
			ap.play("Idle")
		world.add_child(holder)
		holder.position = pos
		# лицом к центру замка
		holder.rotation.y = atan2(pos.x, pos.z) + PI
		var tag := Label3D.new()
		tag.text = "%s\n<%s>" % [v["name"], v["desc"]]
		tag.modulate = Color(1.0, 0.85, 0.4)
		tag.outline_modulate = Color(0, 0, 0, 0.9)
		tag.outline_size = 10
		tag.font_size = 28
		tag.pixel_size = 0.004
		tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		tag.position.y = 3.2
		holder.add_child(tag)
		if v.get("prop", "") == "anvil":
			var anvil := _make_anvil()
			anvil.position = Vector3(0.15, 0, 0.95)
			holder.add_child(anvil)
			_anvil_top[vid] = anvil
		_vendor_nodes[vid] = holder

## Торговец под курсором (для клика ПКМ).
func pick_vendor(cam: Camera3D, screen_pos: Vector2) -> String:
	for vid in vendor_pos:
		var p: Vector3 = vendor_pos[vid] + Vector3(0, 1.3, 0)
		if cam.is_position_behind(p):
			continue
		var d := cam.global_position.distance_to(p)
		var r := clampf(900.0 / maxf(d, 1.0), 25.0, 160.0)
		if cam.unproject_position(p).distance_to(screen_pos) < r:
			return vid
	return ""

func nearest_vendor(pos: Vector3) -> String:
	for vid in vendor_pos:
		if Vector2(pos.x - vendor_pos[vid].x, pos.z - vendor_pos[vid].z).length() <= VENDOR_RANGE:
			return vid
	return ""

## Что продаёт торговец.
func vendor_items(vid: String) -> Array:
	var out: Array = []
	for id in GameData.all_items():
		if GameData.item(id)["kind"] == VENDORS[vid]["kind"]:
			out.append(id)
	out.sort_custom(func(a, b):
		var ia := GameData.item(a)
		var ib := GameData.item(b)
		return [ia["level"], ia["name"]] < [ib["level"], ib["name"]])
	return out

# ---------------------------------------------------------------- запросы игроков

func send(method: String, args: Array) -> void:
	if Net.is_server():
		callv(method, args)
	else:
		match args.size():
			1: rpc_id(1, method, args[0])
			2: rpc_id(1, method, args[0], args[1])
			3: rpc_id(1, method, args[0], args[1], args[2])

func _sender_hero() -> Node:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	return world.heroes.get(Net.hero_id_of_peer(sender), null)

func _say(hero, text: String) -> void:
	if hero.peer_id == multiplayer.get_unique_id():
		ev_message(text)
	else:
		ev_message.rpc_id(hero.peer_id, text)

@rpc("authority", "reliable")
func ev_message(text: String) -> void:
	world.hud.error(text)

@rpc("any_peer", "reliable")
func request_buy(vid: String, item_id: String) -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	var it := GameData.item(item_id)
	if hero == null or it.is_empty() or not VENDORS.has(vid) or it["kind"] != VENDORS[vid]["kind"]:
		return
	if Vector2(hero.unit.pos.x - vendor_pos[vid].x, hero.unit.pos.z - vendor_pos[vid].z).length() > VENDOR_RANGE + 2.0:
		return _say(hero, "Подойдите ближе к торговцу")
	if hero.unit.level < int(it["level"]):
		return _say(hero, "Нужен %d уровень" % it["level"])
	if hero.gold < int(it["price"]):
		return _say(hero, "Недостаточно золота")
	if not hero.bag_add(item_id):
		return _say(hero, "Сумка полна")
	hero.gold -= int(it["price"])
	_sync(hero)
	_sound(hero, "coins")

@rpc("any_peer", "reliable")
func request_sell(idx: int) -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero == null or idx < 0 or idx >= hero.bag.size() or hero.bag[idx] == null:
		return
	if nearest_vendor(hero.unit.pos) == "":
		return _say(hero, "Продать можно только у торговца")
	var s: Dictionary = hero.bag[idx]
	var it := GameData.item(s["id"])
	hero.gold += int(float(it["price"]) * GameData.ItemData.SELL_RATIO) * int(s["n"])
	hero.bag[idx] = null
	_sync(hero)
	_sound(hero, "coins")

## Использовать: расходник — выпить, снаряжение — надеть.
@rpc("any_peer", "reliable")
func request_use(idx: int) -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero == null or idx < 0 or idx >= hero.bag.size() or hero.bag[idx] == null or not hero.unit.alive:
		return
	var s: Dictionary = hero.bag[idx]
	var it := GameData.item(s["id"])
	if it["kind"] == "gear":
		_equip(hero, idx)
		return
	var t: float = world.now()
	if t < hero.potion_ready_at:
		return _say(hero, "Зелья ещё не готовы")
	var u: Unit = hero.unit
	var use: Dictionary = it["use"]
	if use.has("heal"):
		world.spells.heal(u, u, float(use["heal"]), false, "item:" + str(it["id"]))
	if use.has("mana"):
		u.mana = minf(u.max_mana, u.mana + float(use["mana"]))
	if use.has("buff"):
		u.add_buff(use["buff"], t + float(use["dur"]), use["mods"])
		hero.apply_level_stats(false)
	world.spells.fx_at("heal_small" if use.has("heal") else "proc", u.pos, u.pos, 0.0, u.id)
	hero.potion_ready_at = t + GameData.POTION_CD
	s["n"] = int(s["n"]) - 1
	if s["n"] <= 0:
		hero.bag[idx] = null
	_sync(hero)
	if hero.peer_id == multiplayer.get_unique_id():
		ev_potion_cd(GameData.POTION_CD)
	else:
		ev_potion_cd.rpc_id(hero.peer_id, GameData.POTION_CD)

## Использовать расходник по id (с панели заклинаний).
@rpc("any_peer", "reliable")
func request_use_id(item_id: String) -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero == null:
		return
	var idx: int = hero.bag_find(item_id)
	if idx < 0:
		return _say(hero, "Нет в сумке")
	request_use(idx)

@rpc("authority", "reliable")
func ev_potion_cd(cd: float) -> void:
	if world.local_hero:
		world.local_hero.controller.potion_until = world.now() + cd

func _equip(hero, idx: int) -> void:
	var it := GameData.item(hero.bag[idx]["id"])
	if not it["classes"].is_empty() and not it["classes"].has(hero.class_id):
		return _say(hero, "Ваш класс не может это носить")
	if hero.unit.level < int(it["level"]):
		return _say(hero, "Нужен %d уровень" % it["level"])
	var slot: String = it["slot"]
	# воин с «Боем двумя руками»: второе оружие идёт в левую руку
	if slot == "weapon" and hero.unit.flag("dual_wield") > 0.0 and hero.equip.has("weapon") and not hero.equip.has("offhand"):
		slot = "offhand"
	var old = hero.equip.get(slot, null)
	hero.equip[slot] = it["id"]
	hero.bag[idx] = {"id": old, "n": 1} if old != null else null
	hero.apply_level_stats(false)
	_sync(hero)
	_sound(hero, "ui_drop")

@rpc("any_peer", "reliable")
func request_unequip(slot: String) -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero == null or not hero.equip.has(slot):
		return
	var free: int = hero.bag.find(null)
	if free < 0:
		return _say(hero, "Сумка полна")
	hero.bag[free] = {"id": hero.equip[slot], "n": 1}
	hero.equip.erase(slot)
	hero.apply_level_stats(false)
	_sync(hero)

## Переставить предметы в сумке.
@rpc("any_peer", "reliable")
func request_swap(a: int, b: int) -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero == null or a < 0 or b < 0 or a >= hero.bag.size() or b >= hero.bag.size():
		return
	var tmp = hero.bag[a]
	hero.bag[a] = hero.bag[b]
	hero.bag[b] = tmp
	_sync(hero)

## Вторую руку без таланта носить нельзя — при сбросе талантов оружие уходит в сумку.
func check_offhand(hero) -> void:
	if hero.equip.has("offhand") and hero.unit.flag("dual_wield") <= 0.0:
		var free: int = hero.bag.find(null)
		if free >= 0:
			hero.bag[free] = {"id": hero.equip["offhand"], "n": 1}
		hero.equip.erase("offhand")
		hero.apply_level_stats(false)
		_sync(hero)

func _sync(hero) -> void:
	ev_appearance.rpc(hero.hero_id, hero.equip.has("offhand"))
	if hero.peer_id == multiplayer.get_unique_id():
		ev_inventory(hero.hero_id, hero.bag, hero.equip)
	else:
		ev_inventory.rpc_id(hero.peer_id, hero.hero_id, hero.bag, hero.equip)

@rpc("authority", "reliable")
func ev_inventory(hero_id: int, bag: Array, equip: Dictionary) -> void:
	var h = world.heroes.get(hero_id, null)
	if h == null:
		return
	h.bag = bag.duplicate(true)
	h.equip = equip.duplicate()
	if not Net.is_server():
		h.apply_level_stats(false)
	world.hud.on_inventory_changed()

func _sound(hero, snd: String) -> void:
	if hero.peer_id == multiplayer.get_unique_id():
		Sfx.play(snd)

# ---------------------------------------------------------------- добыча с врагов

## Сервер: шанс выпадения предмета с убитого врага (лучше с ростом волны).
func roll_loot(pos: Vector3, wave: int, boss: bool) -> void:
	var drops: Array = []
	if boss:
		drops.append(_random_gear(wave + 4, pos))
		drops.append(_random_gear(wave + 4, pos))
		drops.append(_random_consumable(wave))
	elif randf() < (float(Net.cli["lootrate"]) if Net.cli.has("lootrate") else 0.06):
		drops.append(_random_gear(wave, pos) if randf() < 0.5 else _random_consumable(wave))
	for id in drops:
		var lid := _next_loot
		_next_loot += 1
		var p := pos + Vector3(randf_range(-1.2, 1.2), 0, randf_range(-1.2, 1.2))
		_loot[lid] = {"item": id, "pos": p, "until": world.now() + LOOT_TIME}
		ev_loot_spawn.rpc(lid, id, p)

## Ступень выпавшей вещи: по уровню героев рядом, номер волны ограничивает сверху.
## Раньше ступень зависела только от волны, и в одиночной игре, где уровень героя отстаёт,
## падали вещи, которые нельзя надеть.
func _random_gear(wave: int, pos: Vector3) -> String:
	var levels := _levels_near(pos)
	var tier := GameData.Formulas.gear_tier(wave, levels)
	if randf() < 0.25:
		tier = maxi(1, tier - 1)    # иногда попроще — для разнообразия, надеть всё равно можно
	if Net.cli.has("lootsim"):
		_lootsim_record(tier, GameData.Formulas.old_gear_tier(wave), levels)
	var keys: Array = GameData.ItemData.TEMPLATES.keys()
	return "%s_%d" % [keys[randi() % keys.size()], tier]

func _random_consumable(wave: int) -> String:
	if randf() < 0.25:
		return ["elixir_power", "elixir_fort", "elixir_wisdom"][randi() % 3]
	var tier := 1 if wave < 8 else (2 if wave < 16 else 3)
	return "potion_%s_%d" % ["heal" if randf() < 0.6 else "mana", tier]

func server_tick(delta: float, t: float) -> void:
	_pickup_t -= delta
	if _pickup_t > 0.0:
		return
	_pickup_t = 0.25
	var gone: Array = []
	for lid in _loot:
		var l: Dictionary = _loot[lid]
		if t >= l["until"]:
			gone.append(lid)
			continue
		for h in world.heroes.values():
			if not h.unit.alive:
				continue
			if Vector2(h.unit.pos.x - l["pos"].x, h.unit.pos.z - l["pos"].z).length() <= PICKUP_RANGE:
				if h.bag_add(l["item"]):
					gone.append(lid)
					_sync(h)
					_say_loot(h, l["item"])
				break
	for lid in gone:
		_loot.erase(lid)
		ev_loot_remove.rpc(lid)

func _say_loot(hero, id: String) -> void:
	if hero.peer_id == multiplayer.get_unique_id():
		ev_got(id)
	else:
		ev_got.rpc_id(hero.peer_id, id)

@rpc("authority", "reliable")
func ev_got(id: String) -> void:
	world.hud.error_info("Получено: %s" % GameData.item(id)["name"])
	Sfx.play("coins")

@rpc("authority", "call_local", "reliable")
func ev_loot_spawn(lid: int, id: String, p: Vector3) -> void:
	var it := GameData.item(id)
	var holder := Node3D.new()
	var path := "res://assets/dungeon/chest.glb" if it["kind"] == "gear" else "res://assets/dungeon/bottle_A_labeled_green.gltf.glb"
	var model := (load(path) as PackedScene).instantiate() as Node3D
	model.scale = Vector3.ONE * (0.55 if it["kind"] == "gear" else 1.4)
	holder.add_child(model)
	var col := GameData.item_color(id)
	var beam := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.12
	cm.bottom_radius = 0.3
	cm.height = 4.5
	cm.cap_top = false
	cm.cap_bottom = false
	beam.mesh = cm
	beam.position.y = 2.25
	beam.material_override = Vfx.dome_material(col, 2.0, 4.0)
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(beam)
	var tag := Label3D.new()
	tag.text = it["name"]
	tag.modulate = col
	tag.outline_modulate = Color(0, 0, 0, 0.9)
	tag.outline_size = 8
	tag.font_size = 30
	tag.pixel_size = 0.006
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.position.y = 1.6
	holder.add_child(tag)
	world.vfx_root.add_child(holder)
	holder.global_position = p
	holder.create_tween().set_loops().tween_property(model, "rotation:y", TAU, 4.0).from(0.0)
	_loot_nodes[lid] = holder

@rpc("authority", "call_local", "reliable")
func ev_loot_remove(lid: int) -> void:
	var n: Node3D = _loot_nodes.get(lid, null)
	if n and is_instance_valid(n):
		n.queue_free()
	_loot_nodes.erase(lid)

@rpc("authority", "call_local", "reliable")
func ev_appearance(hero_id: int, dual: bool) -> void:
	var h = world.heroes.get(hero_id, null)
	if h:
		h.update_weapon_visual(dual)
# ---------------------------------------------------------------- уровень добычи

## Уровни живых героев рядом с местом выпадения (если рядом никого — всех героев).
func _levels_near(pos: Vector3) -> Array:
	var near: Array = []
	var all: Array = []
	for h in world.heroes.values():
		all.append(h.unit.level)
		if h.unit.alive and Vector2(h.unit.pos.x - pos.x, h.unit.pos.z - pos.z).length() <= GameData.XP_SHARE_RADIUS:
			near.append(h.unit.level)
	return near if not near.is_empty() else all

## --lootsim: копим, сколько выпавших вещей герои рядом могут надеть сразу или через 1–2 уровня.
var _ls: Dictionary = {"n": 0, "new_now": 0, "new_soon": 0, "old_now": 0, "old_soon": 0}

func _lootsim_record(tier: int, old_tier: int, levels: Array) -> void:
	var need_new := int(GameData.ItemData.TIERS[tier - 1]["level"])
	var need_old := int(GameData.ItemData.TIERS[old_tier - 1]["level"])
	for l in levels:
		_ls["n"] += 1
		_ls["new_now"] += 1 if l >= need_new else 0
		_ls["new_soon"] += 1 if l + 2 >= need_new else 0
		_ls["old_now"] += 1 if l >= need_old else 0
		_ls["old_soon"] += 1 if l + 2 >= need_old else 0

func lootsim_report() -> String:
	var n := maxf(1.0, float(_ls["n"]))
	return "LOOTSIM героев×вещей=%d | было: сразу %d%%, через ≤2 ур. %d%% | стало: сразу %d%%, через ≤2 ур. %d%%" % [_ls["n"],
		int(_ls["old_now"] / n * 100.0), int(_ls["old_soon"] / n * 100.0), int(_ls["new_now"] / n * 100.0), int(_ls["new_soon"] / n * 100.0)]

# ---------------------------------------------------------------- облик торговцев

static func _metal(col: Color, metallic: float = 0.8, rough: float = 0.45) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.metallic = metallic
	m.roughness = rough
	return m

static func _part(mesh: Mesh, mat: Material, pos: Vector3, rot_deg: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot_deg
	return mi

## Кузнечный молот из примитивов (в паке KayKit молота нет): рукоять вдоль Y, как у топора.
static func _make_hammer() -> Node3D:
	var n := Node3D.new()
	n.name = "Smith_Hammer"
	var handle := CylinderMesh.new()
	handle.top_radius = 0.035
	handle.bottom_radius = 0.04
	handle.height = 0.62
	n.add_child(_part(handle, _metal(Color(0.42, 0.26, 0.14), 0.0, 0.8), Vector3(0, 0.26, 0)))
	var head := BoxMesh.new()
	head.size = Vector3(0.3, 0.15, 0.15)
	n.add_child(_part(head, _metal(Color(0.32, 0.32, 0.36)), Vector3(0, 0.56, 0)))
	return n

## Наковальня с раскалённой заготовкой.
static func _make_anvil() -> Node3D:
	var n := Node3D.new()
	n.name = "Anvil"
	var iron := _metal(Color(0.2, 0.2, 0.23))
	var b1 := BoxMesh.new()
	b1.size = Vector3(0.42, 0.28, 0.3)
	n.add_child(_part(b1, iron, Vector3(0, 0.14, 0)))
	var b2 := BoxMesh.new()
	b2.size = Vector3(0.24, 0.18, 0.2)
	n.add_child(_part(b2, iron, Vector3(0, 0.37, 0)))
	var top := BoxMesh.new()
	top.size = Vector3(0.62, 0.13, 0.28)
	n.add_child(_part(top, iron, Vector3(0, 0.52, 0)))
	var horn := CylinderMesh.new()
	horn.top_radius = 0.0
	horn.bottom_radius = 0.1
	horn.height = 0.3
	n.add_child(_part(horn, iron, Vector3(0.46, 0.53, 0), Vector3(0, 0, -90)))
	var hot := BoxMesh.new()
	hot.size = Vector3(0.26, 0.04, 0.07)
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color(1.0, 0.45, 0.1)
	glow.emission_enabled = true
	glow.emission = Color(1.0, 0.4, 0.05)
	glow.emission_energy_multiplier = 2.5
	n.add_child(_part(hot, glow, Vector3(-0.05, 0.605, 0)))
	return n

## Кузнец время от времени бьёт молотом по наковальне: искры и негромкий звон. Только визуал, у каждого игрока свой.
func _process(delta: float) -> void:
	for vid in _vendor_nodes:
		var v: Dictionary = VENDORS[vid]
		if not v.has("work"):
			continue
		var w: Dictionary = v["work"]
		_work_t[vid] = float(_work_t.get(vid, randf() * 2.0)) - delta
		if _work_t[vid] > 0.0:
			continue
		_work_t[vid] = float(w["every"]) + randf_range(-0.4, 0.4)
		var ap := ModelFactory.find_anim(_vendor_nodes[vid])
		if ap == null or not ap.has_animation(w["anim"]):
			continue
		ap.play(w["anim"], 0.15)
		ap.queue("Idle")
		var anvil: Node3D = _anvil_top.get(vid, null)
		if anvil:
			get_tree().create_timer(float(w["hit_at"])).timeout.connect(func():
				if is_instance_valid(anvil):
					var p := anvil.global_position + Vector3(-0.05, 0.62, 0)
					Vfx.burst(world, p, Color(1.0, 0.65, 0.2))
					Sfx.play_at("blade_hit", p, -12.0))
