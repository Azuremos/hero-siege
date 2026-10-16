class_name SiegeSave
extends RefCounted
## Сохранение недоигранной осады (сессия 07, §4а): хост пишет user://sieges/<id>.json.
## Что внутри: настройки партии (длительность, направления, фракции, зерно), сколько волн уже отбито, здоровье
## замка, уровень угрозы, состав отряда и герой каждого игрока по его uid (HeroSave). Живых мобов не сохраняем:
## сохранение — между волнами; из боя текущая волна при загрузке начнётся заново.
## Автосохранение — одна ячейка на осаду (id осады), перезаписывается после каждой волны.

const DIR := "user://sieges/"
const VERSION := 1

## Сервер: записать осаду. Возвращает путь или "" при ошибке.
static func save(world: Node) -> String:
	var mode = world.mode
	if not mode is SiegeMode:
		return ""
	var sid := str(Net.settings.get("siege_id", ""))
	if sid == "":
		sid = Net.new_uid().substr(0, 12)
		Net.settings["siege_id"] = sid
	# в бою (идёт волна) — сохраняем «до неё»: при загрузке волна начнётся заново
	var done: int = mode.wave if mode.state in ["prep", "break", "victory"] else maxi(0, mode.wave - 1)
	var heroes := {}
	var party: Array = []
	for h in world.heroes.values():
		var info: Dictionary = Net.players.get(h.peer_id, {})
		var uid := str(info.get("uid", ""))
		if uid == "":
			uid = "hero%d" % h.hero_id
		heroes[uid] = HeroSave.capture(h)
		party.append({"uid": uid, "name": h.player_name, "class": h.class_id, "race": h.race_id, "level": h.unit.level})
	var settings := Net.settings.duplicate()
	settings.erase("mode")
	var d := {
		"v": VERSION, "id": sid, "date": Time.get_datetime_string_from_system(false, true),
		"settings": settings, "wave": done, "castle": mode.castle.hp, "castle_max": mode.castle.max_hp,
		"threat": int(Net.settings.get("threat", 0)), "solo": Net.solo, "heroes": heroes, "party": party,
		"host_uid": Net.uid,
	}
	DirAccess.make_dir_recursive_absolute(DIR)
	var path := DIR + sid + ".json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(JSON.stringify(d, "  "))
	return path

## Список сохранённых осад: [{id, date, wave, waves, party: [имена], solo}], новые сверху. Битые файлы пропускаются.
static func list() -> Array:
	var out: Array = []
	var dir := DirAccess.open(DIR)
	if dir == null:
		return out
	for fn in dir.get_files():
		if not fn.ends_with(".json"):
			continue
		var d := load_file(fn.get_basename())
		if d.is_empty():
			continue
		out.append(d)
	out.sort_custom(func(a, b): return str(a["date"]) > str(b["date"]))
	return out

## Прочитать и проверить сохранение. {} — файла нет или он битый (игра не падает).
static func load_file(sid: String) -> Dictionary:
	var path := DIR + sid.get_file() + ".json"
	if not FileAccess.file_exists(path):
		return {}
	var raw: Variant = HeroSave.parse_json(FileAccess.get_file_as_string(path))
	if not raw is Dictionary:
		return {}
	var d: Dictionary = raw
	if int(d.get("v", 0)) < 1 or int(d.get("v", 0)) > VERSION or not d.get("settings", null) is Dictionary \
			or not d.get("heroes", null) is Dictionary or not d.get("party", null) is Array:
		return {}
	d["id"] = sid.get_file()
	d["wave"] = clampi(int(d.get("wave", 0)), 0, GameData.MAX_WAVES)
	d["castle"] = clampf(float(d.get("castle", GameData.CASTLE_HP)), 1.0, GameData.CASTLE_HP * 10.0)
	d["castle_max"] = clampf(float(d.get("castle_max", GameData.CASTLE_HP)), 1.0, GameData.CASTLE_HP * 10.0)
	var party: Array = []
	for p in d["party"]:
		if p is Dictionary and GameData.CLASSES.has(str(p.get("class", ""))):
			party.append({"uid": str(p.get("uid", "")), "name": str(p.get("name", "Герой")).substr(0, 16),
				"class": str(p["class"]), "race": str(p.get("race", "human")) if GameData.RACES.has(str(p.get("race", ""))) else "human",
				"level": clampi(int(p.get("level", 1)), 1, GameData.MAX_LEVEL)})
	if party.is_empty():
		return {}
	d["party"] = party
	return d

static func remove(sid: String) -> void:
	DirAccess.remove_absolute(DIR + sid.get_file() + ".json")
