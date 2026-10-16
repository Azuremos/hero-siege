class_name CharacterStore
extends RefCounted
## Свои герои «Похода»: каждый игрок хранит их у себя, user://characters/<id>.json (формат HeroSave).
## При входе в партию клиент отдаёт героя хосту; хост ведёт его в бою и присылает обратно для записи
## (после каждой волны, в передышке и в конце партии).

const DIR := "user://characters/"

## Новый герой 1-го уровня.
static func create(name: String, class_id: String, race_id: String) -> Dictionary:
	var d := {"v": HeroSave.VERSION, "id": Net.new_uid().substr(0, 12), "name": name.substr(0, 16), "class": class_id,
		"race": race_id, "level": 1, "xp": 0, "gold": 0, "talents": {}, "choices": {}, "equip": {}, "bag": [], "pet": {},
		"threat": 0, "played": 0}
	save(d)
	return d

static func save(d: Dictionary) -> void:
	var clean := HeroSave.sanitize(d)
	if clean.is_empty() or str(clean.get("id", "")) == "":
		return
	DirAccess.make_dir_recursive_absolute(DIR)
	var f := FileAccess.open(DIR + str(clean["id"]).get_file() + ".json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(clean, "  "))

## Прочитать героя: битый или чужой файл даёт {} (игра не падает).
static func load_one(id: String) -> Dictionary:
	var path := DIR + id.get_file() + ".json"
	if not FileAccess.file_exists(path):
		return {}
	var d := HeroSave.sanitize(HeroSave.parse_json(FileAccess.get_file_as_string(path)))
	if not d.is_empty():
		d["id"] = id.get_file()
	return d

static func list() -> Array:
	var out: Array = []
	var dir := DirAccess.open(DIR)
	if dir == null:
		return out
	for fn in dir.get_files():
		if fn.ends_with(".json"):
			var d := load_one(fn.get_basename())
			if not d.is_empty():
				out.append(d)
	out.sort_custom(func(a, b): return int(a["level"]) > int(b["level"]))
	return out

static func remove(id: String) -> void:
	DirAccess.remove_absolute(DIR + id.get_file() + ".json")
