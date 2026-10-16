class_name HeroSave
extends RefCounted
## Герой одним словарём: для переподключения, сохранённых героев «Похода» и сохранения осады.
## Формат: {v, id, name, class, race, level, xp, gold, talents, choices, equip, bag, pet, threat, played}.
## v — версия формата; старые версии поднимает migrate(). Чужие и битые данные не роняют хост:
## sanitize() отбрасывает всё, чего нет в данных игры, и обрезает числа по диапазонам.

const VERSION := 1

## Сервер: снять состояние героя.
static func capture(hero) -> Dictionary:
	var st: Dictionary = hero.world.mobs._pst(hero.hero_id) if hero.class_id == "hunter" else {}
	return {
		"v": VERSION, "id": str(hero.character_id), "name": hero.player_name, "class": hero.class_id, "race": hero.race_id,
		"level": hero.unit.level, "xp": hero.xp, "gold": hero.gold,
		"talents": hero.talents.duplicate(), "choices": hero.choices.duplicate(),
		"equip": hero.equip.duplicate(), "bag": hero.bag.duplicate(true),
		"pet": {"kind": st.get("kind", "pet_wolf"), "mode": st.get("mode", "defensive")} if not st.is_empty() else {},
		"threat": int(hero.threat), "played": int(hero.played),
	}

## Старые версии формата → текущая (пока одна версия: заготовка для будущих полей).
static func migrate(d: Dictionary) -> Dictionary:
	var out := d.duplicate(true)
	if int(out.get("v", 0)) < 1:
		out["v"] = 1
	return out

## Проверка на здравый смысл: версия, диапазоны, существующие id предметов, талантов и заклинаний.
## {} — данные не годятся (не тот формат или нет такого класса).
static func sanitize(raw: Variant) -> Dictionary:
	if not raw is Dictionary:
		return {}
	var d := migrate(raw)
	if int(d.get("v", 0)) > VERSION:
		return {}
	var cid := str(d.get("class", ""))
	if not GameData.CLASSES.has(cid):
		return {}
	var out := {"v": VERSION, "class": cid}
	out["id"] = str(d.get("id", "")).substr(0, 40)
	out["name"] = str(d.get("name", "Герой")).substr(0, 16)
	out["race"] = str(d.get("race", "human")) if GameData.RACES.has(str(d.get("race", ""))) else "human"
	out["level"] = clampi(int(d.get("level", 1)), 1, GameData.MAX_LEVEL)
	out["xp"] = clampi(int(d.get("xp", 0)), 0, 10000000)
	out["gold"] = clampi(int(d.get("gold", 0)), 0, 10000000)
	out["threat"] = clampi(int(d.get("threat", 0)), 0, 100)
	out["played"] = clampi(int(d.get("played", 0)), 0, 100000)
	# таланты: только существующие, ранг не выше максимума, очков не больше, чем даёт уровень
	var ranks := {}
	var tal: Variant = d.get("talents", {})
	if tal is Dictionary:
		for tid in tal:
			var info := GameData.find_talent(cid, str(tid))
			if not info.is_empty():
				ranks[str(tid)] = clampi(int(tal[tid]), 0, int(info["t"]["max"]))
	if GameData.talent_points_spent(ranks) > GameData.talent_points_total(out["level"]):
		ranks = {}
	out["talents"] = ranks
	# выбор в книге: номер ряда → один из вариантов этого ряда
	var ch := {}
	var cd: Variant = d.get("choices", {})
	if cd is Dictionary and GameData.BOOKS.has(cid):
		var rows: Array = GameData.BOOKS[cid]["rows"]
		for k in cd:
			var r := int(k)
			if r >= 0 and r < rows.size() and rows[r]["options"].has(str(cd[k])):
				ch[r] = str(cd[k])
	out["choices"] = ch
	# снаряжение: ячейка из списка, вещь читается и подходит к ячейке
	var eq := {}
	var ed: Variant = d.get("equip", {})
	if ed is Dictionary:
		for slot in ed:
			var s := str(slot)
			var id := str(ed[slot])
			var it := GameData.item(id)
			if GameData.ItemData.SLOT_ORDER.has(s) and not it.is_empty() and it.get("kind", "") == "gear" and _slot_ok(s, str(it["slot"])):
				eq[s] = id
	out["equip"] = eq
	# сумка: 20 ячеек, расходники стопками до STACK
	var bag: Array = []
	var bd: Variant = d.get("bag", [])
	if bd is Array:
		for e in bd:
			if bag.size() >= 20:
				break
			if e is Dictionary and not GameData.item(str(e.get("id", ""))).is_empty():
				bag.append({"id": str(e["id"]), "n": clampi(int(e.get("n", 1)), 1, GameData.ItemData.STACK)})
			else:
				bag.append(null)
	while bag.size() < 20:
		bag.append(null)
	out["bag"] = bag
	var pet := {}
	var pd: Variant = d.get("pet", {})
	if pd is Dictionary and cid == "hunter":
		pet["kind"] = str(pd.get("kind", "pet_wolf")) if ["pet_wolf", "pet_bear", "pet_cat"].has(str(pd.get("kind", ""))) else "pet_wolf"
		pet["mode"] = str(pd.get("mode", "defensive")) if ["aggressive", "defensive", "passive"].has(str(pd.get("mode", ""))) else "defensive"
	out["pet"] = pet
	return out

static func _slot_ok(equip_slot: String, item_slot: String) -> bool:
	if equip_slot == item_slot:
		return true
	if item_slot == "trinket":
		return equip_slot in ["trinket1", "trinket2"]
	return equip_slot == "offhand" and item_slot == "weapon"      # второе оружие воина

## Сервер: применить сохранённое состояние к герою (уровень, опыт, золото, снаряжение, сумка, таланты, книга, питомец).
static func apply(world: Node, hero, d: Dictionary) -> void:
	hero.unit.level = int(d["level"])
	hero.xp = int(d["xp"])
	hero.xp_next = GameData.xp_to_next(hero.unit.level)
	hero.gold = int(d["gold"])
	hero.threat = int(d.get("threat", 0))
	hero.played = int(d.get("played", 0))
	if str(d.get("id", "")) != "":
		hero.character_id = str(d["id"])
	hero.equip = d["equip"].duplicate()
	hero.bag = d["bag"].duplicate(true)
	world.ev_talents.rpc(hero.hero_id, d["talents"])
	world.ev_choices.rpc(hero.hero_id, d["choices"])
	hero.apply_level_stats(true)
	world.economy._sync(hero)
	if hero.class_id == "hunter" and not d.get("pet", {}).is_empty():
		var st: Dictionary = world.mobs._pst(hero.hero_id)
		st["kind"] = d["pet"]["kind"]
		st["mode"] = d["pet"]["mode"]
		world.mobs._send_pet_state(hero)

## Разбор JSON без сообщений об ошибке в консоли: битый файл — просто null.
static func parse_json(text: String) -> Variant:
	var j := JSON.new()
	return j.data if j.parse(text) == OK else null
