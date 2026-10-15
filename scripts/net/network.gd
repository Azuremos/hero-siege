extends Node
## Сеть: хост/подключение через ENet (работает по LAN и через Radmin VPN),
## список игроков в лобби и запуск игры.

signal players_changed
signal connection_failed(reason: String)
signal game_starting
signal disconnected(reason: String)

const PORT := 7777

## Порт сетевой игры. --port= меняет его для тестов (чтобы не мешать запущенной копии игры).
func port() -> int:
	return int(cli.get("port", PORT))
const MAX_PLAYERS := 6

## peer_id -> {name, class, race, version, hero_id}
var players: Dictionary = {}
## Последнее сообщение для лобби хоста (например, кто зашёл с другой версией).
var lobby_notice := ""
var local_info: Dictionary = {"name": "Герой", "class": "mage", "race": "human"}
var in_game := false
var solo := false
## Параметры командной строки (для тестов: --solo --class=mage --bot --quit-after=60)
var cli: Dictionary = {}
## Настройки партии (выбирает хост): число волн, направления, длительность передышки (сек.).
var settings: Dictionary = {"waves": 20, "lanes": 4, "break": 60}

## Личность игрока: стабильный id (UUID) в user://profile.cfg. peer_id — только транспорт, ключ состояния — uid.
## Там же — адрес последнего хоста и флаг «партия оборвалась» (кнопка «Переподключиться»).
const PROFILE_PATH := "user://profile.cfg"
var uid := ""

func _load_profile() -> void:
	var cfg := ConfigFile.new()
	cfg.load(PROFILE_PATH)
	uid = str(cfg.get_value("player", "uid", ""))
	if uid.length() < 8:
		uid = new_uid()
		cfg.set_value("player", "uid", uid)
		cfg.save(PROFILE_PATH)

static func new_uid() -> String:
	var c := Crypto.new()
	return c.generate_random_bytes(16).hex_encode()

func profile_get(key: String, def: Variant) -> Variant:
	var cfg := ConfigFile.new()
	cfg.load(PROFILE_PATH)
	return cfg.get_value("player", key, def)

func profile_set(key: String, value: Variant) -> void:
	if cli.has("playerid"):
		return      # тестовые запуски не трогают профиль
	var cfg := ConfigFile.new()
	cfg.load(PROFILE_PATH)
	cfg.set_value("player", key, value)
	cfg.save(PROFILE_PATH)

func _ready() -> void:
	_load_profile()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_ok)
	multiplayer.connection_failed.connect(_on_connected_fail)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func is_server() -> bool:
	return multiplayer.has_multiplayer_peer() and multiplayer.is_server()

func my_id() -> int:
	return multiplayer.get_unique_id()

## Версия игры — одна на всё: application/config/version в project.godot (совпадает с тегом релиза).
## Играть вместе можно только на одинаковой версии.
func game_version() -> String:
	if cli.has("fakeversion"):
		return str(cli["fakeversion"])
	return str(ProjectSettings.get_setting("application/config/version", "?")) + "+" + net_fingerprint()

## Отпечаток сетевого кода: хэш списка RPC всех сетевых скриптов. Между релизами версия одна
## («0.7-dev»), а набор RPC меняется — разные сборки нумеруют вызовы по-разному, и движение
## уходит не туда. Отпечаток не даёт подключиться с несовместимой сборкой.
const NET_SCRIPTS := ["res://scripts/net/network.gd", "res://scripts/world/economy.gd", "res://scripts/world/hero.gd",
	"res://scripts/world/marks.gd", "res://scripts/world/meter.gd", "res://scripts/world/mob_manager.gd",
	"res://scripts/world/spell_system.gd", "res://scripts/world/world.gd"]
var _fp := ""

func net_fingerprint() -> String:
	if _fp == "":
		var parts: Array = []
		for p in NET_SCRIPTS:
			var s: Script = load(p)
			var cfg = s.get_rpc_config()
			var names: Array = cfg.keys() if cfg is Dictionary else []
			names.sort()
			parts.append(p.get_file() + ":" + ",".join(names))
		_fp = ("|".join(parts)).md5_text().substr(0, 6)
	return _fp

## Адреса этого компьютера — подсказка для хоста (Radmin VPN выдаёт 26.x.x.x).
func local_addresses() -> Array:
	var out: Array = []
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254"):
			out.append(a)
	out.sort_custom(func(x, y): return x.begins_with("26.") and not y.begins_with("26."))
	return out

func host_game(is_solo: bool = false) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	# Одиночной игре порт не нужен: любой свободный и только на этом компьютере —
	# можно играть, даже если 7777 занят другой копией игры, и брандмауэр не спрашивает.
	if is_solo:
		peer.set_bind_ip("127.0.0.1")
	var err := peer.create_server(0 if is_solo else port(), 1 if is_solo else MAX_PLAYERS)
	if err != OK:
		return err
	peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
	multiplayer.multiplayer_peer = peer
	solo = is_solo
	players.clear()
	lobby_notice = ""
	players[1] = local_info.duplicate()
	players[1]["version"] = game_version()
	players_changed.emit()
	return OK

func join_game(address: String) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address.strip_edges(), port())
	if err != OK:
		return err
	peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
	multiplayer.multiplayer_peer = peer
	solo = false
	return OK

func leave() -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	players.clear()
	in_game = false

# ---------------------------------------------------------------- лобби

func _on_peer_connected(_id: int) -> void:
	pass  # клиент сам пришлёт register_player

func _on_peer_disconnected(id: int) -> void:
	if players.has(id):
		players.erase(id)
		players_changed.emit()
		if is_server():
			_sync_players.rpc(players)

func _on_connected_ok() -> void:
	var info := local_info.duplicate()
	info["version"] = game_version()
	_register_player.rpc_id(1, info)

func _on_connected_fail() -> void:
	leave()
	connection_failed.emit("Не удалось подключиться. Проверьте IP и что хост запустил игру.")

func _on_server_disconnected() -> void:
	leave()
	disconnected.emit("Хост закрыл игру.")

@rpc("any_peer", "reliable")
func _register_player(info: Dictionary) -> void:
	if not is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if in_game:
		# Поздний вход пока не поддерживается — вежливо отключаем.
		multiplayer.multiplayer_peer.disconnect_peer(id)
		return
	var pname := str(info.get("name", "Герой")).substr(0, 16)
	# Версии до v0.5 свою версию не присылают.
	var version := str(info.get("version", "")).substr(0, 24)
	if version != game_version():
		var theirs := version if version != "" else "старая (до 0.5)"
		lobby_notice = "%s пытался подключиться с версией %s — нужна %s." % [pname, theirs, game_version()]
		print("VERSION REJECT: ", lobby_notice)
		players_changed.emit()
		_version_mismatch.rpc_id(id, game_version())
		_kick_later(id)
		return
	players[id] = {
		"name": pname,
		"class": str(info.get("class", "mage")) if GameData.CLASSES.has(info.get("class", "")) else "mage",
		"race": str(info.get("race", "human")) if GameData.RACES.has(info.get("race", "")) else "human",
		"version": version,
	}
	players_changed.emit()
	_sync_players.rpc(players)

## Отключает игрока чуть позже, чтобы до него успело дойти сообщение о причине.
func _kick_later(id: int) -> void:
	await get_tree().create_timer(1.0).timeout
	if is_server() and multiplayer.get_peers().has(id):
		multiplayer.multiplayer_peer.disconnect_peer(id)

## Хост сообщает клиенту, что версии не совпадают.
## Имя выбрано так, чтобы по алфавиту стоять после остальных RPC этого узла: если номера RPC
## зависят от порядка имён, у существующих они не сдвинутся, и старый клиент дойдёт до проверки версии.
@rpc("authority", "reliable")
func _version_mismatch(host_version: String) -> void:
	var reason := "У хоста версия %s, у вас %s.\nСкачайте ту же версию игры, что у хоста." % [host_version, game_version()]
	leave.call_deferred()
	connection_failed.emit(reason)

@rpc("authority", "reliable")
func _sync_players(p: Dictionary) -> void:
	players = p
	players_changed.emit()

## Только хост: раздаёт номера героев и запускает игру у всех.
func start_game() -> void:
	if not is_server():
		return
	var ids := players.keys()
	ids.sort()
	var hero_id := 1
	for pid in ids:
		players[pid]["hero_id"] = hero_id
		hero_id += 1
	_start_game.rpc(players, settings)
	_start_game(players, settings)

@rpc("authority", "reliable")
func _start_game(p: Dictionary, s: Dictionary) -> void:
	players = p
	settings = s
	in_game = true
	game_starting.emit()
	get_tree().change_scene_to_file.call_deferred("res://scenes/world.tscn")

func back_to_menu(reason: String = "") -> void:
	leave()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
	if reason != "":
		await get_tree().process_frame
		disconnected.emit(reason)

func hero_id_of_peer(peer: int) -> int:
	return int(players.get(peer, {}).get("hero_id", 0))

func peer_of_hero(hero_id: int) -> int:
	for pid in players:
		if int(players[pid].get("hero_id", 0)) == hero_id:
			return pid
	return 0
