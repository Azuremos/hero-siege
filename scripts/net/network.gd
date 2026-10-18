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
## Герои-боты («Добавить бота в команду», --teams=): записи игроков с такими «номерами соединения».
## Настоящих соединений с ними нет — ими управляет хост (PlayerController в режиме ИИ).
const BOT_PEER_BASE := 2100000000

func is_bot_peer(pid: int) -> bool:
	return pid >= BOT_PEER_BASE

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
## Продолженная осада (сессия 07): данные сохранения, которые хост загрузил в лобби. {} — обычная партия.
var pending_siege: Dictionary = {}

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
	# вход через аутентификацию: пока клиент, вошедший посреди партии, грузит мир, RPC до него не доходят
	var sm := multiplayer as SceneMultiplayer
	sm.auth_callback = _auth_received
	sm.auth_timeout = 90.0
	sm.peer_authenticating.connect(_on_peer_authenticating)

# ---------------------------------------------------------------- вход: аутентификация (сессия 07)
## Клиент шлёт hello с данными игрока. В лобби хост сразу пускает (дальше — как раньше, _register_player).
## В идущей партии хост решает (вернувшийся по uid или поздний вход), отдаёт игроков и настройки байтами
## аутентификации; клиент грузит мир, отвечает loaded — и только тогда обе стороны завершают вход.
var joining_mid := false

func _on_peer_authenticating(id: int) -> void:
	if not is_server() and id == 1:
		var info := local_info.duplicate()
		info["version"] = game_version()
		(multiplayer as SceneMultiplayer).send_auth(1, var_to_bytes({"t": "hello", "info": info}))

func _auth_send(id: int, msg: Dictionary) -> void:
	(multiplayer as SceneMultiplayer).send_auth(id, var_to_bytes(msg))

func _auth_received(id: int, data: PackedByteArray) -> void:
	var msg: Variant = bytes_to_var(data)
	if not msg is Dictionary:
		return
	var sm := multiplayer as SceneMultiplayer
	var t := str(msg.get("t", ""))
	if is_server():
		match t:
			"hello":
				if not in_game:
					_auth_send(id, {"t": "lobby"})
					sm.complete_auth(id)
					return
				var info: Variant = msg.get("info", {})
				if not info is Dictionary or str(info.get("version", "")) != game_version():
					_auth_send(id, {"t": "refused", "reason": "У хоста версия %s, у вас другая.\nСкачайте ту же версию игры, что у хоста." % game_version()})
					_kick_later(id)
					return
				var rec := _make_rec(info)
				var w := get_tree().current_scene
				if w == null or not w.has_method("server_join") or not w.server_join(id, rec):
					_auth_send(id, {"t": "refused", "reason": "Отряд полон или хост не пускает в идущую партию."})
					_kick_later(id)
					return
				_sync_players.rpc(players)
				_auth_send(id, {"t": "start", "players": players, "settings": settings})
			"loaded":
				sm.complete_auth(id)
	elif id == 1:
		match t:
			"lobby":
				sm.complete_auth(1)
			"start":
				players = msg["players"]
				settings = msg["settings"]
				in_game = true
				joining_mid = true
				profile_set("unclean", true)
				game_starting.emit()
				get_tree().change_scene_to_file.call_deferred("res://scenes/world.tscn")
			"refused":
				leave.call_deferred()
				connection_failed.emit(str(msg.get("reason", "Хост не пустил в партию.")))

## Клиент, вошедший посреди партии: мир загружен — завершить вход.
func finish_mid_join() -> void:
	_auth_send(1, {"t": "loaded"})
	(multiplayer as SceneMultiplayer).complete_auth(1)

func _make_rec(info: Dictionary) -> Dictionary:
	var rec := {
		"name": str(info.get("name", "Герой")).substr(0, 16),
		"class": str(info.get("class", "mage")) if GameData.CLASSES.has(info.get("class", "")) else "mage",
		"race": str(info.get("race", "human")) if GameData.RACES.has(info.get("race", "")) else "human",
		"version": str(info.get("version", "")).substr(0, 24),
		"uid": str(info.get("uid", "")).substr(0, 40),
	}
	if info.get("character", null) is Dictionary:
		rec["character"] = info["character"]       # сохранённый герой «Похода» (хост проверит HeroSave.sanitize)
	return rec

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
	"res://scripts/world/spell_system.gd", "res://scripts/world/world.gd", "res://scripts/modes/lines_mode.gd"]
var _fp := ""

func net_fingerprint() -> String:
	if _fp == "":
		var parts: Array = []
		for p in NET_SCRIPTS:
			var s: Script = load(p)
			var cfg = s.get_rpc_config()
			# имена — обычными строками: StringName сортируется по-разному в разных сборках (exe и редактор)
			var names: Array = (cfg.keys() if cfg is Dictionary else []).map(func(n): return str(n))
			names.sort()
			parts.append(p.get_file() + ":" + ",".join(names))
		_fp = ("|".join(parts)).md5_text().substr(0, 6)
		if cli.has("fpdebug"):
			print("FP ", "|".join(parts))
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
	if str(settings.get("mode", "siege")) == "lines":
		players[1]["team"] = 0
	players_changed.emit()
	return OK

func join_game(address: String) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address.strip_edges(), port())
	profile_set("last_host", address.strip_edges())
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
	if in_game:
		return      # в партии запись игрока остаётся: его герой ждёт возвращения (world._on_peer_left)
	if players.has(id):
		players.erase(id)
		players_changed.emit()
		if is_server():
			_sync_players.rpc(players)

func _on_connected_ok() -> void:
	if joining_mid:
		return      # вошёл посреди партии: данные уже переданы при аутентификации
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
	var rec := _make_rec(info)
	if in_game:
		return      # в идущую партию входят через аутентификацию (_auth_received)
	# лобби продолженной осады: игрок с тем же uid занимает место своего героя
	for pid in players.keys():
		if pid < 0 and str(players[pid].get("uid", "")) == rec["uid"] and rec["uid"] != "":
			rec["class"] = players[pid]["class"]
			rec["race"] = players[pid]["race"]
			players.erase(pid)
	if str(settings.get("mode", "siege")) == "lines":
		rec["team"] = 0 if team_size(0) <= team_size(1) else 1      # «Линии»: новичок — в меньшую команду
	players[id] = rec
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
	if str(settings.get("mode", "siege")) == "lines":
		fill_teams()
		if int(settings.get("teams_n", 0)) > 0:
			fill_bots(int(settings["teams_n"]))      # пустые места в командах — боты
	if str(settings.get("mode", "")) == "pvptest":
		# --pvptest=<класс>: вражеский герой-бот этого класса (команда 1), свой герой — команда 0
		for pid in players:
			players[pid]["team"] = 0
		if add_bot(1):
			for pid in players:
				if is_bot_peer(pid):
					var pc := str(cli.get("pvptest", "warrior"))
					players[pid]["class"] = pc if GameData.CLASSES.has(pc) else "warrior"
					players[pid]["race"] = GameData.ClassData.fix_race(players[pid]["class"], "human")
					players[pid]["name"] = "Соперник"
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
	profile_set("unclean", not solo)      # партия идёт: если оборвётся — в меню будет «Переподключиться»
	players = p
	settings = s
	in_game = true
	game_starting.emit()
	get_tree().change_scene_to_file.call_deferred("res://scenes/world.tscn")

func back_to_menu(reason: String = "") -> void:
	pending_siege = {}
	if reason == "":
		profile_set("unclean", false)      # вышел сам — переподключаться некуда
	leave()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
	if reason != "":
		await get_tree().process_frame
		disconnected.emit(reason)

# ---------------------------------------------------------------- команды и боты («Война линий»)

const LinesData := preload("res://scripts/data/lines_data.gd")

func team_size(team: int) -> int:
	var n := 0
	for pid in players:
		if pid > 0 and int(players[pid].get("team", -1)) == team:
			n += 1
	return n

## Игрокам без команды — меньшая команда (до 3 человек на сторону).
func fill_teams() -> void:
	var ids := players.keys()
	ids.sort()
	for pid in ids:
		if pid > 0 and not players[pid].has("team"):
			players[pid]["team"] = 0 if team_size(0) <= team_size(1) else 1

## Хост: поставить игрока в команду (места по 3 на сторону).
func set_team(pid: int, team: int) -> bool:
	if not players.has(pid) or (int(players[pid].get("team", -1)) != team and team_size(team) >= LinesData.MAX_LANES):
		return false
	players[pid]["team"] = team
	_lobby_changed()
	return true

## Хост: «Случайные команды» — перемешать всех (вместе с ботами) и раздать поровну.
func shuffle_teams() -> void:
	var ids: Array = players.keys().filter(func(k): return k > 0)
	ids.shuffle()
	for i in ids.size():
		players[ids[i]]["team"] = i % 2
	_lobby_changed()

## Хост: добавить бота в команду. false — команда полна или в отряде нет мест.
func add_bot(team: int) -> bool:
	var count: int = players.keys().filter(func(k): return k > 0).size()
	if count >= MAX_PLAYERS or team_size(team) >= LinesData.MAX_LANES:
		return false
	var i := 0
	while players.has(BOT_PEER_BASE + i):
		i += 1
	var cls: String = LinesData.BOT_CLASSES[(i * 2 + team) % LinesData.BOT_CLASSES.size()]
	players[BOT_PEER_BASE + i] = {"name": LinesData.BOT_NAMES[i % LinesData.BOT_NAMES.size()], "class": cls,
		"race": GameData.ClassData.fix_race(cls, "human"), "version": game_version(), "uid": "", "team": team, "bot": true}
	_lobby_changed()
	return true

func remove_bot(pid: int) -> void:
	if is_bot_peer(pid) and players.erase(pid):
		_lobby_changed()

## Тест (--teams=2v2): добить обе команды ботами до n человек.
func fill_bots(n: int) -> void:
	fill_teams()
	for team in 2:
		while team_size(team) < mini(n, LinesData.MAX_LANES) and add_bot(team):
			pass

func _lobby_changed() -> void:
	players_changed.emit()
	if is_server() and not solo:
		_sync_players.rpc(players)

func hero_id_of_peer(peer: int) -> int:
	return int(players.get(peer, {}).get("hero_id", 0))

func peer_of_hero(hero_id: int) -> int:
	for pid in players:
		if int(players[pid].get("hero_id", 0)) == hero_id:
			return pid
	return 0
