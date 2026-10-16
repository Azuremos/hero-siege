class_name Collection
extends RefCounted
## Коллекция сетов и легендарок (сессия 07б). В «Походе» копится между партиями (user://collection.cfg),
## в обычной осаде видно, что собрано за партию (session — до выхода из игры).
## Ключи: «set:<id сета>:<ячейка>», «leg:<id легендарки>».

const PATH := "user://collection.cfg"
static var session: Dictionary = {}

## Ключ коллекции для вещи ("" — вещь не из сета и не легендарка).
static func key_of(id: String) -> String:
	var it := GameData.item(id)
	var sid := str(it.get("set_id", ""))
	if GameData.SetData.SETS.has(sid):
		var slot: String = it["slot"]
		return "set:%s:%s" % [sid, slot]
	var lid := str(it.get("unique_id", ""))
	if GameData.SetData.LEGENDARIES.has(lid):
		return "leg:" + lid
	return ""

## Вещь попала в сумку: отметить в коллекции; persist — записать в файл (режим с сохранением).
static func record(id: String, persist: bool) -> void:
	var k := key_of(id)
	if k == "":
		return
	session[k] = true
	if persist and Net.cli.is_empty():
		var cfg := ConfigFile.new()
		cfg.load(PATH)
		cfg.set_value("got", k, true)
		cfg.save(PATH)

static func has(k: String) -> bool:
	if session.has(k):
		return true
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return false
	return bool(cfg.get_value("got", k, false))
