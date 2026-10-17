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
	# «Война линий»: продаёт врагов на линию соперника (окно отправок). На осадной карте его нет (нет точки).
	"recruiter": {"marker": "Recruiter", "name": "Вербовщик Борислав", "desc": "Отправка врагов сопернику", "model": "Knight",
		"show": ["1H_Sword"], "kind": "sends", "optional": true},
}

## Вид торговца по id: у режимов с командами торговцы у каждой базы — «smith#0», «recruiter#1».
static func vkind(vid: String) -> String:
	return vid.get_slice("#", 0)
const VENDOR_RANGE := 9.0
const PICKUP_RANGE := 2.6
const LOOT_TIME := 90.0
## Доля аксессуаров среди выпавших вещей.
const TRINKET_SHARE := 0.2
const TRINKET_SHARE_ELITE := 0.35

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

## Торговцы появляются у мастерских (точки Shops на карте). На карте «Линий» — у каждой базы свои:
## точка «Blacksmith_0» — торговец «smith#0» (команда 0).
func spawn_vendors() -> void:
	var shops: Node = world.map.get_node_or_null("Shops")
	var spots: Array = []         # [vid, вид, точка]
	for kind in VENDORS:
		var v: Dictionary = VENDORS[kind]
		var m: Node3D = shops.get_node_or_null(v["marker"]) if shops else null
		if m:
			spots.append([kind, kind, m])
		for team in 2:
			var mt: Node3D = shops.get_node_or_null("%s_%d" % [v["marker"], team]) if shops else null
			if mt:
				spots.append(["%s#%d" % [kind, team], kind, mt])
		if m == null and spots.filter(func(s): return s[1] == kind).is_empty() and not v.get("optional", false):
			spots.append([kind, kind, null])
	for sp in spots:
		var vid: String = sp[0]
		var v: Dictionary = VENDORS[sp[1]]
		var m: Node3D = sp[2]
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
		# лицом к центру замка (или куда задано точкой карты)
		holder.rotation.y = float(m.get_meta("yaw")) if m and m.has_meta("yaw") else atan2(pos.x, pos.z) + PI
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

## Что продаёт торговец герою уровня level (ассортимент кузнеца меняется каждые 3 волны).
func vendor_items(vid: String, level: int) -> Array:
	return GameData.vendor_stock(VENDORS[vkind(vid)]["kind"], level, _rotation(), world.mode.shop_blue())

func _rotation() -> int:
	var w = world.mode.get("wave")
	return int(w) / 3 if w != null else 0

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
	if world.acting_hero != null:
		return world.acting_hero      # герой-бот на хосте
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	return world.heroes.get(Net.hero_id_of_peer(sender), null)

func _say(hero, text: String) -> void:
	if Net.is_bot_peer(hero.peer_id):
		return
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
	if hero == null or not vendor_pos.has(vid) or VENDORS[vkind(vid)]["kind"] == "sends" or not world.mode.vendor_allowed(hero, vid):
		return
	# покупать можно только то, что сейчас лежит в лавке у этого героя (ассортимент сервер считает сам)
	if not vendor_items(vid, hero.unit.level).has(item_id):
		return _say(hero, "Этого товара уже нет — откройте лавку заново")
	var it := GameData.item(item_id)
	if Vector2(hero.unit.pos.x - vendor_pos[vid].x, hero.unit.pos.z - vendor_pos[vid].z).length() > VENDOR_RANGE + 2.0:
		return _say(hero, "Подойдите ближе к торговцу")
	if hero.unit.level < int(it["level"]):
		return _say(hero, "Нужен %d уровень" % it["level"])
	var cost := GameData.shop_price(item_id)
	if hero.gold < cost:
		return _say(hero, "Недостаточно золота")
	if not hero.bag_add(item_id):
		return _say(hero, "Сумка полна")
	hero.gold -= cost
	hero.gold_out += cost
	_sync(hero)
	_sound(hero, "coins")


@rpc("any_peer", "reliable")
func request_sell(idx: int) -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero == null or idx < 0 or idx >= hero.bag.size() or hero.bag[idx] == null:
		return
	if world.trade.is_offered(hero, idx):
		return _say(hero, "Вещь лежит в окне обмена")
	if nearest_vendor(hero.unit.pos) == "":
		return _say(hero, "Продать можно только у торговца")
	var s: Dictionary = hero.bag[idx]
	var it := GameData.item(s["id"])
	var got := int(float(it["price"]) * GameData.ItemData.SELL_RATIO) * int(s["n"])
	hero.gold += got
	hero.gold_in += got
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
	# эликсиры не делят перезарядку с зельями: бафф на 3 минуты, повторный глоток лишь обновляет его
	var elixir: bool = it.get("elixir", false)
	if not elixir and t < hero.potion_ready_at:
		return _say(hero, "Зелья ещё не готовы")
	var u: Unit = hero.unit
	var use: Dictionary = it["use"]
	if use.has("heal_pct"):
		world.spells.heal(u, u, u.max_hp * float(use["heal_pct"]), false, "item:" + str(it["id"]))
	if use.has("mana_pct"):
		u.mana = minf(u.max_mana, u.mana + u.max_mana * float(use["mana_pct"]))
	if use.has("buff"):
		u.add_buff(use["buff"], t + float(use["dur"]), use["mods"])
		hero.apply_level_stats(false)
	world.spells.fx_at("heal_small" if use.has("heal_pct") else "proc", u.pos, u.pos, 0.0, u.id)
	s["n"] = int(s["n"]) - 1
	if s["n"] <= 0:
		hero.bag[idx] = null
	_sync(hero)
	if elixir:
		return
	hero.potion_ready_at = t + GameData.POTION_CD
	if hero.peer_id == multiplayer.get_unique_id():
		ev_potion_cd(GameData.POTION_CD)
	elif hero.ai:
		hero.controller.potion_until = world.now() + GameData.POTION_CD
	else:
		ev_potion_cd.rpc_id(hero.peer_id, GameData.POTION_CD)

## Используемый аксессуар (кнопка на панели «use:trinket1»): сервер проверяет, что вещь надета, эффект есть
## и перезарядка прошла. Перезарядка у каждого эффекта своя, с зельями не делится.
const EQUIP_USE_CD := 30.0

@rpc("any_peer", "reliable")
func request_use_slot(slot: String) -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero == null or not GameData.ItemData.TRINKET_SLOTS.has(slot) or not hero.unit.alive:
		return
	var use := GameData.ItemData.use_of(str(hero.equip.get(slot, "")))
	if use == "":
		return _say(hero, "Этот аксессуар нельзя использовать")
	var t: float = world.now()
	if t < float(hero.use_ready.get(use, 0.0)):
		return _say(hero, "Ещё не готово")
	if hero.unit.is_stunned(t):
		return _say(hero, "Вы оглушены")
	var pd: Dictionary = GameData.ItemData.ITEM_PROCS[use]
	hero.use_ready[use] = t + float(pd["cd"])
	world.spells.apply_item_effect(hero.unit, pd, hero.unit, t)
	if Net.cli.has("proclog"):
		print("USE ", use, " t=%.1f" % t)
	_send_use_cd(hero)

## Владельцу — перезарядки используемых аксессуаров (сколько секунд осталось).
func _send_use_cd(hero) -> void:
	var left := {}
	for k in hero.use_ready:
		left[k] = maxf(0.0, float(hero.use_ready[k]) - world.now())
	if hero.peer_id == multiplayer.get_unique_id():
		ev_use_cd(left)
	elif Net.is_bot_peer(hero.peer_id):
		pass      # бот на хосте читает use_ready героя напрямую
	else:
		ev_use_cd.rpc_id(hero.peer_id, left)

@rpc("authority", "reliable")
func ev_use_cd(left: Dictionary) -> void:
	if world.local_hero == null:
		return
	for k in left:
		world.local_hero.use_ready[k] = world.now() + float(left[k])

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
	if slot == "trinket":
		# аксессуар — в свободную из двух ячеек, иначе вместо первого
		slot = "trinket1"
		if hero.equip.has("trinket1") and not hero.equip.has("trinket2"):
			slot = "trinket2"
		# используемый эффект после надевания готов не раньше чем через 30 сек. (как в WoW) — нельзя сбросить перезарядку переодеванием
		var use: String = it.get("use", "")
		if use != "":
			hero.use_ready[use] = maxf(float(hero.use_ready.get(use, 0.0)), world.now() + EQUIP_USE_CD)
			_send_use_cd(hero)
	# воин с «Боем двумя руками»: второе оружие идёт в левую руку
	# двуручное оружие во вторую руку не берётся и само занимает обе руки
	var two: bool = slot == "weapon" and GameData.ItemData.is_two_handed(it["id"])
	if slot == "weapon" and not two and hero.unit.flag("dual_wield") > 0.0 and hero.equip.has("weapon") \
			and not hero.equip.has("offhand") and not GameData.ItemData.is_two_handed(hero.equip["weapon"]):
		slot = "offhand"
	# щит, том, сфера: двуручное оружие занимает обе руки
	if slot == "offhand" and it["slot"] == "offhand" and hero.equip.has("weapon") and GameData.ItemData.is_two_handed(hero.equip["weapon"]):
		return _say(hero, "Двуручное оружие занимает обе руки")
	if two and hero.equip.has("offhand"):
		var free: int = hero.bag.find(null)
		if free < 0 or free == idx:
			free = -1
			for i in hero.bag.size():
				if hero.bag[i] == null and i != idx:
					free = i
					break
		if free < 0:
			return _say(hero, "Сумка полна: некуда убрать второе оружие")
		hero.bag[free] = {"id": hero.equip["offhand"], "n": 1}
		hero.equip.erase("offhand")
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
	if hero.equip.has("offhand") and hero.unit.flag("dual_wield") <= 0.0 and GameData.item(hero.equip["offhand"]).get("slot", "") == "weapon":
		var free: int = hero.bag.find(null)
		if free >= 0:
			hero.bag[free] = {"id": hero.equip["offhand"], "n": 1}
		hero.equip.erase("offhand")
		hero.apply_level_stats(false)
		_sync(hero)

func _sync(hero) -> void:
	ev_appearance.rpc(hero.hero_id, look_of(hero))
	if hero.peer_id == multiplayer.get_unique_id():
		ev_inventory(hero.hero_id, hero.bag, hero.equip)
	elif Net.is_bot_peer(hero.peer_id):
		pass      # бот на хосте: сумка и снаряжение — те же данные героя
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

## Доля вещей в добыче обычного врага (остальное — зелья и эликсиры) и шанс вещи с элитного.
## Было 0,4 и 1,0 — пользователь попросил вещей чуть меньше (после v0.14.2).
const MOB_GEAR_SHARE := 0.3
const ELITE_GEAR := 0.75
## Сервер: добыча с убитого врага. source: mob / elite / champion / boss — повышает качество вещи и шанс зелий.
## gear_k — множитель доли вещей (режим: «Линии» — общие волны вдвое реже, отправленные враги — 0, только зелья).
func roll_loot(pos: Vector3, wave: int, source: String, gear_k: float = 1.0) -> void:
	var drops: Array = []
	match source:
		"boss", "champion":
			for i in 2:
				drops.append(_random_gear(wave, pos, source) if gear_k >= 1.0 or randf() < gear_k else _random_consumable(pos))
			drops.append(_random_consumable(pos))
			drops.append(_random_consumable(pos))
		"elite":
			# элитный — вещь получше в ELITE_GEAR случаев (иначе зелье), часто ещё зелье
			drops.append(_random_gear(wave, pos, source) if randf() < ELITE_GEAR * gear_k else _random_consumable(pos))
			if randf() < 0.75:
				drops.append(_random_consumable(pos))
		_:
			if randf() < (float(Net.cli["lootrate"]) if Net.cli.has("lootrate") else 0.06):
				drops.append(_random_gear(wave, pos, source) if randf() < MOB_GEAR_SHARE * gear_k else _random_consumable(pos))
	if source != "mob" and gear_k > 0.0 and (gear_k >= 1.0 or randf() < gear_k):
		_roll_special(pos, wave, source)      # части сетов и именные легендарки
	for id in drops:
		_spawn_loot(id, pos + Vector3(randf_range(-1.2, 1.2), 0, randf_range(-1.2, 1.2)))

## Сервер: добыча с босса — одна именная вещь из его списка (главный — эпическая, лейтенант — редкая и выше)
## плюс обычная добыча босса (две вещи и два зелья).
func roll_boss_loot(pos: Vector3, wave: int, uniques: Array, rank: String) -> void:
	roll_loot(pos, wave, "boss")
	if uniques.is_empty():
		return
	var uid: String = uniques[randi() % uniques.size()]
	var ud: Dictionary = GameData.ItemData.UNIQUES[uid]
	var q := maxi(int(ud["q"]), GameData.ItemData.roll_quality(GameData.Formulas.typical_level(_levels_near(pos)), "boss", randf()))
	if rank != "main":
		q = mini(q, 3)
	var d: Dictionary = GameData.ItemData.roll(ud["base"], GameData.Formulas.gear_ilvl(wave, _levels_near(pos), "boss") + 1, q, randi() % 1000000)
	d["unique_id"] = uid
	var id: String = GameData.ItemData.encode(d)
	_spawn_loot(id, pos + Vector3(randf_range(-0.8, 0.8), 0, randf_range(-0.8, 0.8)))
	world.announce_all("Добыча: %s" % GameData.item(id)["name"], GameData.ItemData.QUALITY[q])

## Вещь: уровень — по уровню героев рядом (номер волны ограничивает сверху), качество — отдельным броском
## по уровню героев и источнику. Требуемый уровень = уровень предмета.
func _random_gear(wave: int, pos: Vector3, source: String) -> String:
	var levels := _levels_near(pos)
	var ilvl := GameData.Formulas.gear_ilvl(world.campaign_wave(wave), levels, source)
	if world.is_campaign() and GameData.Formulas.typical_level(levels) >= GameData.MAX_LEVEL:
		# «Поход» после 30-го уровня: добыча растёт с угрозой (Звёздные, Небесные вещи)
		ilvl = mini(ilvl + GameData.Formulas.threat_ilvl(int(Net.settings.get("threat", 0))), GameData.ItemData.MAX_ILVL)
	var q := GameData.ItemData.roll_quality(GameData.Formulas.typical_level(levels), source, randf())
	if Net.cli.has("lootsim"):
		_lootsim_record(ilvl, q, levels)
	# аксессуар — каждая пятая вещь, с элитных и боссов — каждая третья (их носят ради проков)
	var keys: Array = GameData.ItemData.TEMPLATES.keys()
	if randf() < (TRINKET_SHARE_ELITE if source != "mob" else TRINKET_SHARE):
		keys = GameData.ItemData.TRINKETS.keys()
	return GameData.make_gear(keys[randi() % keys.size()], ilvl, q)

## Зелье (ступень — по уровню героев рядом) или эликсир.
func _random_consumable(pos: Vector3) -> String:
	var lvl := GameData.Formulas.typical_level(_levels_near(pos))
	var cons: Dictionary = GameData.ItemData.CONSUMABLES
	if randf() < 0.3:
		var elixirs: Array = cons.keys().filter(func(c): return cons[c].get("elixir", false) and int(cons[c]["level"]) <= lvl + 2)
		if not elixirs.is_empty():
			return elixirs[randi() % elixirs.size()]
	var kind := "heal" if randf() < 0.55 else "mana"
	var best := "potion_%s_1" % kind
	for c in cons:
		if c.begins_with("potion_" + kind) and int(cons[c].get("drop_level", 99)) <= lvl and int(cons[c]["drop_level"]) >= int(cons[best]["drop_level"]):
			best = c
	return best

func _spawn_loot(id: String, p: Vector3, n: int = 1, owner: int = 0) -> int:
	var lid := _next_loot
	_next_loot += 1
	var l := {"item": id, "n": n, "pos": p, "until": world.now() + LOOT_TIME}
	if owner != 0:
		# выброшенное: лежит дольше, поднимается только кликом, выбросивший — не раньше чем через DROP_LOCK сек.
		l["owner"] = owner
		l["lock_until"] = world.now() + DROP_LOCK
		l["until"] = world.now() + LOOT_TIME * 2.0
	_loot[lid] = l
	ev_loot_spawn.rpc(lid, id, p, n, owner != 0)
	return lid

# ---------------------------------------------------------------- выбросить и поднять

## Выброшенное поднимается кликом ПКМ (не подходом — чтобы не схватить случайно), не дальше этого.
const CLICK_PICKUP_RANGE := 4.5
const DROP_LOCK := 5.0

## Выбросить вещь из сумки на землю (перетащить за пределы сумки или ПКМ → «Выбросить»).
@rpc("any_peer", "reliable")
func request_drop(idx: int) -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero == null or idx < 0 or idx >= hero.bag.size() or hero.bag[idx] == null:
		return
	if world.trade.is_offered(hero, idx):
		return _say(hero, "Вещь лежит в окне обмена")
	var s: Dictionary = hero.bag[idx]
	hero.bag[idx] = null
	var fwd := Vector3(-sin(hero.rotation.y), 0, -cos(hero.rotation.y))
	var lid := _spawn_loot(s["id"], hero.unit.pos + fwd * 1.6, int(s["n"]), hero.hero_id)
	_sync(hero)
	_sound(hero, "ui_drop")
	if Net.cli.has("tradelog") or Net.cli.has("tradetest"):
		print("DROP hero=%d item=%s n=%d loot=%d" % [hero.hero_id, s["id"], int(s["n"]), lid])

## Поднять добычу кликом. Любую добычу можно поднять и так, выброшенную — только так.
@rpc("any_peer", "reliable")
func request_pickup(lid: int) -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero == null or not _loot.has(lid) or not hero.unit.alive:
		return
	var l: Dictionary = _loot[lid]
	if Vector2(hero.unit.pos.x - l["pos"].x, hero.unit.pos.z - l["pos"].z).length() > CLICK_PICKUP_RANGE + 0.5:
		return _say(hero, "Подойдите ближе")
	var t: float = world.now()
	if int(l.get("owner", 0)) == hero.hero_id and t < float(l.get("lock_until", 0.0)):
		if Net.cli.has("tradelog") or Net.cli.has("tradetest"):
			print("PICKUP refused (own drop) hero=%d loot=%d" % [hero.hero_id, lid])
		return _say(hero, "Свою выброшенную вещь можно поднять через %d сек." % int(ceil(float(l["lock_until"]) - t)))
	if not hero.bag_add(l["item"], int(l.get("n", 1))):
		return _say(hero, "Сумка полна")
	_loot.erase(lid)
	ev_loot_remove.rpc(lid)
	_sync(hero)
	_say_loot(hero, l["item"])
	if Net.cli.has("tradelog") or Net.cli.has("tradetest"):
		print("PICKUP hero=%d item=%s loot=%d" % [hero.hero_id, l["item"], lid])

## Добыча под курсором (клиент; для клика ПКМ). 0 — нет.
func pick_loot(cam: Camera3D, screen_pos: Vector2) -> int:
	var best := 0
	var best_d := 1e9
	for lid in _loot_nodes:
		var n: Node3D = _loot_nodes[lid]
		if not is_instance_valid(n):
			continue
		var p := n.global_position + Vector3(0, 0.6, 0)
		if cam.is_position_behind(p):
			continue
		var r := clampf(700.0 / maxf(cam.global_position.distance_to(p), 1.0), 18.0, 90.0)
		var d := cam.unproject_position(p).distance_to(screen_pos)
		if d < r and d < best_d:
			best_d = d
			best = lid
	return best

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
			if not l.has("owner") and Vector2(h.unit.pos.x - l["pos"].x, h.unit.pos.z - l["pos"].z).length() <= PICKUP_RANGE:
				if h.bag_add(l["item"], int(l.get("n", 1))):
					gone.append(lid)
					_sync(h)
					_say_loot(h, l["item"])
				break
	for lid in gone:
		_loot.erase(lid)
		ev_loot_remove.rpc(lid)

func _say_loot(hero, id: String) -> void:
	if GameData.SetData.LEGENDARIES.has(str(GameData.item(id).get("unique_id", ""))):
		world.announce_all("%s нашёл: %s!" % [hero.player_name, GameData.item(id)["name"]], GameData.ItemData.QUALITY[4])
	if GameData.item(id).get("kind", "") == "gear":
		world.items_got[hero.hero_id] = int(world.items_got.get(hero.hero_id, 0)) + 1      # итоги партии
	if hero.peer_id == multiplayer.get_unique_id():
		ev_got(id)
	elif Net.is_bot_peer(hero.peer_id):
		pass
	else:
		ev_got.rpc_id(hero.peer_id, id)

@rpc("authority", "reliable")
func ev_got(id: String) -> void:
	Collection.record(id, world.is_campaign())      # коллекция сетов и легендарок
	world.hud.error_info("Получено: %s" % GameData.item(id)["name"])
	Sfx.play("coins")

@rpc("authority", "call_local", "reliable")
func ev_loot_spawn(lid: int, id: String, p: Vector3, n: int = 1, dropped: bool = false) -> void:
	if _loot_nodes.has(lid):
		return
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
	tag.text = it["name"] + (" ×%d" % n if n > 1 else "") + ("\n(ПКМ — поднять)" if dropped else "")
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

## Облик героя: {ячейка: id вещи} только видимых ячеек (ItemData.LOOK_SLOTS).
func look_of(hero) -> Dictionary:
	var out := {}
	for slot in GameData.ItemData.LOOK_SLOTS:
		if hero.equip.has(slot):
			out[slot] = str(hero.equip[slot])
	return out

## Сервер: облик всех героев одному игроку (подключился или загрузился позже — видит снаряжение сразу).
func send_all_looks(peer: int) -> void:
	for h in world.heroes.values():
		if not h.equip.is_empty():
			ev_appearance.rpc_id(peer, h.hero_id, look_of(h))

@rpc("authority", "call_local", "reliable")
func ev_appearance(hero_id: int, ids: Dictionary) -> void:
	var h = world.heroes.get(hero_id, null)
	if h == null:
		return
	# клиенту не доверяем и тут: только строки в видимых ячейках
	var clean := {}
	for slot in ids:
		if GameData.ItemData.LOOK_SLOTS.has(slot) and ids[slot] is String:
			clean[slot] = ids[slot]
	h.update_outfit(clean)
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

## --lootsim: копим, сколько выпавших вещей герои рядом могут надеть сразу или через 1–2 уровня,
## и распределение качества.
var _ls: Dictionary = {"n": 0, "now": 0, "soon": 0, "q": [0, 0, 0, 0, 0]}

func _lootsim_record(ilvl: int, q: int, levels: Array) -> void:
	_ls["q"][q] += 1
	for l in levels:
		_ls["n"] += 1
		_ls["now"] += 1 if l >= ilvl else 0
		_ls["soon"] += 1 if l + 2 >= ilvl else 0

func lootsim_report() -> String:
	var n := maxf(1.0, float(_ls["n"]))
	var qn := 0
	for c in _ls["q"]:
		qn += c
	var qs := []
	for i in 5:
		qs.append("%s %d" % [GameData.ItemData.QUALITY_NAMES[i], _ls["q"][i]])
	return "LOOTSIM героев×вещей=%d | надеть сразу %d%%, через ≤2 ур. %d%% | вещей %d: %s" % [_ls["n"],
		int(_ls["now"] / n * 100.0), int(_ls["soon"] / n * 100.0), qn, ", ".join(qs)]

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
		var v: Dictionary = VENDORS[vkind(vid)]
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

## Сервер: добыча на земле — игроку, вошедшему посреди партии.
func send_loot(peer: int) -> void:
	for lid in _loot:
		var l: Dictionary = _loot[lid]
		ev_loot_spawn.rpc_id(peer, lid, l["item"], l["pos"], int(l.get("n", 1)), l.has("owner"))

# ---------------------------------------------------------------- части сетов и именные легендарки (сессия 07б)
## Шанс части сета с элитного, чемпиона и босса — с 10-го уровня героев; легендарки — с 15-го, очень редко.
## Без привязки к боссам (решение пользователя). Защита от невезения: каждый элитный или босс без выпадения
## добавляет к следующему шансу шаг PITY. 70% вещей — для классов, которые есть в отряде.
## Числа подобраны симуляцией tools/loot_sim.gd (таблица в отчёте 07б).
const SET_CHANCE := {"elite": 0.05, "champion": 0.1, "boss": 0.25}
const SET_PITY := 0.01
## Часть для героя отряда: сет его основной ветки (больше всего очков талантов) с этой долей, иначе любой сет класса;
## ячейка, которой у него ещё нет (ни надето, ни в сумке), — с долей MISSING_SHARE.
const MAIN_TREE_SHARE := 0.6
const MISSING_SHARE := 0.7
const SET_MIN_LEVEL := 10
const LEG_CHANCE := {"elite": 0.002, "champion": 0.005, "boss": 0.03}
const LEG_PITY := 0.0008
const LEG_MIN_LEVEL := 15
const PARTY_SHARE := 0.7
var _set_pity := 0.0
var _leg_pity := 0.0

func _roll_special(pos: Vector3, wave: int, source: String) -> void:
	var levels := _levels_near(pos)
	var lvl := GameData.Formulas.typical_level(levels)
	var ilvl := GameData.Formulas.gear_ilvl(world.campaign_wave(wave), levels, "boss")
	if lvl >= SET_MIN_LEVEL:
		if randf() < float(SET_CHANCE[source]) + _set_pity or Net.cli.has("setdrop"):
			_set_pity = 0.0
			var pick := _pick_set_piece()
			var sid: String = pick[0]
			var slot: String = pick[1]
			var id := GameData.make_set_piece(sid, slot, ilvl)
			_spawn_loot(id, pos + Vector3(randf_range(-1.0, 1.0), 0, randf_range(-1.0, 1.0)))
			world.announce_all("Выпала часть сета: %s!" % GameData.item(id)["name"], GameData.ItemData.QUALITY[3])
		else:
			_set_pity += SET_PITY
	if lvl >= LEG_MIN_LEVEL:
		if randf() < float(LEG_CHANCE[source]) + _leg_pity or Net.cli.has("legdrop"):
			_leg_pity = 0.0
			var cid2 := _drop_class()
			var legs: Array = GameData.SetData.LEGENDARIES.keys().filter(func(l): return GameData.SetData.LEGENDARIES[l]["class"] in [cid2, ""])
			var lid: String = legs[randi() % legs.size()]
			var lid_item := GameData.make_legendary(lid, ilvl + 1)
			_spawn_loot(lid_item, pos + Vector3(randf_range(-1.0, 1.0), 0, randf_range(-1.0, 1.0)))
			world.announce_all("Легендарная добыча: %s!" % GameData.item(lid_item)["name"], GameData.ItemData.QUALITY[4])
			world.sound_all("victory")
		else:
			_leg_pity += LEG_PITY

## Для какого класса вещь: с вероятностью PARTY_SHARE — для класса из отряда, иначе для любого.
func _drop_class() -> String:
	var party: Array = []
	for h in world.heroes.values():
		if not h.offline:
			party.append(h.class_id)
	if not party.is_empty() and randf() < PARTY_SHARE:
		return party[randi() % party.size()]
	var all: Array = GameData.CLASSES.keys()
	return all[randi() % all.size()]

## Какую часть сета уронить: [id сета, ячейка]. С долей PARTY_SHARE — для героя отряда (сет основной ветки
## с долей MAIN_TREE_SHARE, ячейка, которой у него нет, с долей MISSING_SHARE), иначе — любая часть любого класса.
func _pick_set_piece() -> Array:
	var sets: Dictionary = GameData.SetData.SETS
	var party: Array = world.heroes.values().filter(func(h): return not h.offline)
	if party.is_empty() or randf() >= PARTY_SHARE:
		var any: Array = sets.keys()
		return [any[randi() % any.size()], GameData.SetData.SLOTS[randi() % GameData.SetData.SLOTS.size()]]
	var h = party[randi() % party.size()]
	var own: Array = sets.keys().filter(func(s): return sets[s]["class"] == h.class_id)
	var sid: String = own[randi() % own.size()]
	if randf() < MAIN_TREE_SHARE:
		var trees: Array = GameData.talent_trees(h.class_id)
		var best := 0
		for i in trees.size():
			if GameData.tree_points(h.class_id, h.talents, i) > GameData.tree_points(h.class_id, h.talents, best):
				best = i
		for s in own:
			if int(sets[s]["tree"]) == best:
				sid = s
	var have := {}
	for slot in h.equip:
		if str(GameData.item(str(h.equip[slot])).get("set_id", "")) == sid:
			have[GameData.item(str(h.equip[slot]))["slot"]] = true
	for b in h.bag:
		if b != null and str(GameData.item(str(b["id"])).get("set_id", "")) == sid:
			have[GameData.item(str(b["id"]))["slot"]] = true
	var missing: Array = GameData.SetData.SLOTS.filter(func(s): return not have.has(s))
	if not missing.is_empty() and randf() < MISSING_SHARE:
		return [sid, missing[randi() % missing.size()]]
	return [sid, GameData.SetData.SLOTS[randi() % GameData.SetData.SLOTS.size()]]
