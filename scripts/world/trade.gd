extends Node
## Обмен предметами между героями (как в WoW): ПКМ по союзнику или его рамке → «Обмен».
## Каждый кладёт до 6 вещей из сумки и золото; обмен проходит, когда подтвердили оба.
## Любое изменение предложения сбрасывает оба подтверждения. Всё решает хост: он проверяет дистанцию,
## наличие вещей и золота, место в сумках и проводит обмен целиком или никак.

const MAX_ITEMS := 6
const TRADE_RANGE := 10.0          # начать обмен и подтвердить его — не дальше
const BREAK_RANGE := 16.0          # разошлись дальше — обмен отменяется

var world: Node3D
## Сервер: обмен на двоих. hero_id -> {"partner", "slots": [индексы сумки], "items": [[id, n]], "gold", "ok"}
var _side: Dictionary = {}
## Клиент: что сейчас в окне обмена (последнее состояние от сервера); пусто — окна нет.
var state: Dictionary = {}

func _ready() -> void:
	world = get_parent()

func send(method: String, args: Array) -> void:
	if Net.is_server():
		callv(method, args)
	else:
		match args.size():
			0: rpc_id(1, method)
			1: rpc_id(1, method, args[0])
			2: rpc_id(1, method, args[0], args[1])

func _sender_hero() -> Node:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	return world.heroes.get(Net.hero_id_of_peer(sender), null)

func _dist(a, b) -> float:
	return Vector2(a.unit.pos.x - b.unit.pos.x, a.unit.pos.z - b.unit.pos.z).length()

func _log(text: String) -> void:
	if Net.cli.has("tradelog") or Net.cli.has("tradetest"):
		print("TRADE ", text)

## Лежит ли вещь из ячейки сумки в окне обмена (её нельзя продать или выбросить).
func is_offered(hero, idx: int) -> bool:
	return _side.has(hero.hero_id) and _side[hero.hero_id]["slots"].has(idx)

# ---------------------------------------------------------------- запросы

@rpc("any_peer", "reliable")
func request_open(target_id: int) -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	var other = world.heroes.get(target_id, null)
	if hero == null or other == null or other == hero:
		return
	if other.ai:
		return _say(hero, "С ботом обмениваться нельзя")
	if _side.has(hero.hero_id):
		return _say(hero, "Вы уже обмениваетесь")
	if _side.has(other.hero_id):
		return _say(hero, "%s уже обменивается с другим героем" % other.player_name)
	if not hero.unit.alive or not other.unit.alive:
		return _say(hero, "Обмен невозможен")
	if _dist(hero, other) > TRADE_RANGE:
		return _say(hero, "Подойдите ближе (не дальше %d м)" % int(TRADE_RANGE))
	for h in [hero, other]:
		var p = other if h == hero else hero
		_side[h.hero_id] = {"partner": p.hero_id, "slots": [], "items": [], "gold": 0, "ok": false}
	_log("open %d <-> %d" % [hero.hero_id, other.hero_id])
	_push(hero.hero_id)

## Предложение: индексы ячеек сумки (до 6) и золото. Заменяет прежнее и сбрасывает подтверждения.
@rpc("any_peer", "reliable")
func request_offer(slots: Array, gold: int) -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero == null or not _side.has(hero.hero_id):
		return
	var clean: Array = []
	var items: Array = []
	for v in slots:
		if not (v is int or v is float):
			continue
		var idx := int(v)
		if idx < 0 or idx >= hero.bag.size() or hero.bag[idx] == null or clean.has(idx) or clean.size() >= MAX_ITEMS:
			continue
		clean.append(idx)
		items.append([hero.bag[idx]["id"], int(hero.bag[idx]["n"])])
	var s: Dictionary = _side[hero.hero_id]
	s["slots"] = clean
	s["items"] = items
	s["gold"] = clampi(gold, 0, hero.gold)
	s["ok"] = false
	_side[s["partner"]]["ok"] = false
	_push(hero.hero_id)

@rpc("any_peer", "reliable")
func request_accept() -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero == null or not _side.has(hero.hero_id):
		return
	_side[hero.hero_id]["ok"] = true
	var pid: int = _side[hero.hero_id]["partner"]
	if _side[pid]["ok"]:
		_execute(hero.hero_id, pid)
	else:
		_push(hero.hero_id)

@rpc("any_peer", "reliable")
func request_cancel() -> void:
	if not Net.is_server():
		return
	var hero = _sender_hero()
	if hero and _side.has(hero.hero_id):
		_close(hero.hero_id, "%s отменил обмен" % hero.player_name)

# ---------------------------------------------------------------- сервер

func server_tick(_t: float) -> void:
	for hid in _side.keys():
		if not _side.has(hid):
			continue
		var h = world.heroes.get(hid, null)
		var p = world.heroes.get(_side[hid]["partner"], null)
		if h == null or p == null:
			_close(hid, "Обмен отменён")
		elif not h.unit.alive or not p.unit.alive:
			_close(hid, "Обмен отменён: герой погиб")
		elif _dist(h, p) > BREAK_RANGE:
			_close(hid, "Обмен отменён: вы слишком далеко друг от друга")

## Проверить всё ещё раз и провести обмен целиком. Не вышло — сумки и золото как были.
func _execute(a_id: int, b_id: int) -> void:
	var a = world.heroes[a_id]
	var b = world.heroes[b_id]
	if _dist(a, b) > TRADE_RANGE:
		return _fail(a_id, "Подойдите ближе, чтобы завершить обмен")
	for h in [a, b]:
		var s: Dictionary = _side[h.hero_id]
		if int(s["gold"]) > h.gold:
			return _fail(a_id, "У %s не хватает золота" % h.player_name)
		for k in s["slots"].size():
			var cur = h.bag[s["slots"][k]]
			if cur == null or cur["id"] != s["items"][k][0] or int(cur["n"]) != int(s["items"][k][1]):
				return _fail(a_id, "Вещи в обмене изменились — проверьте и подтвердите снова")
	var bag_a: Array = a.bag.duplicate(true)
	var bag_b: Array = b.bag.duplicate(true)
	for h in [a, b]:
		for idx in _side[h.hero_id]["slots"]:
			h.bag[idx] = null
	var ok := true
	for pair in [[a, b], [b, a]]:
		for it in _side[pair[0].hero_id]["items"]:
			if not pair[1].bag_add(it[0], int(it[1])):
				ok = false
	if not ok:
		a.bag = bag_a
		b.bag = bag_b
		return _fail(a_id, "Не хватает места в сумке")
	var ga: int = _side[a_id]["gold"]
	var gb: int = _side[b_id]["gold"]
	a.gold += gb - ga
	b.gold += ga - gb
	_log("done %d gave %s +%d gold; %d gave %s +%d gold" % [a_id, _side[a_id]["items"], ga, b_id, _side[b_id]["items"], gb])
	world.economy._sync(a)
	world.economy._sync(b)
	for h in [a, b]:
		world.economy._sound(h, "coins")
	_close(a_id, "Обмен состоялся", true)

func _fail(hid: int, text: String) -> void:
	_log("fail: " + text)
	for k in [hid, _side[hid]["partner"]]:
		_side[k]["ok"] = false
		_say(world.heroes[k], text)
	_push(hid)

func _close(hid: int, text: String, success: bool = false) -> void:
	if not _side.has(hid):
		return
	var pid: int = _side[hid]["partner"]
	_side.erase(hid)
	_side.erase(pid)
	_log("close: " + text)
	for k in [hid, pid]:
		var h = world.heroes.get(k, null)
		if h == null:
			continue
		if h.peer_id == multiplayer.get_unique_id():
			ev_closed(text, success)
		else:
			ev_closed.rpc_id(h.peer_id, text, success)

## Обоим участникам — состояние окна (у каждого «моё» слева).
func _push(hid: int) -> void:
	var pid: int = _side[hid]["partner"]
	for k in [hid, pid]:
		var me: Dictionary = _side[k]
		var them: Dictionary = _side[me["partner"]]
		var st := {"partner": me["partner"], "slots": me["slots"], "mine": me["items"], "my_gold": me["gold"], "my_ok": me["ok"],
			"theirs": them["items"], "their_gold": them["gold"], "their_ok": them["ok"]}
		var h = world.heroes[k]
		if h.peer_id == multiplayer.get_unique_id():
			ev_state(st)
		else:
			ev_state.rpc_id(h.peer_id, st)

func _say(hero, text: String) -> void:
	world.economy._say(hero, text)

# ---------------------------------------------------------------- клиент

@rpc("authority", "reliable")
func ev_state(st: Dictionary) -> void:
	state = st
	world.hud.on_trade_state(st)
	_test_react()

@rpc("authority", "reliable")
func ev_closed(text: String, success: bool) -> void:
	state = {}
	world.hud.on_trade_closed(text, success)
	if Net.cli.has("tradetest"):
		print("TRADE closed me=%d: %s" % [Net.my_id(), text])
		if success and world.local_hero:
			print("TRADE bag me=%d gold=%d items=%s" % [Net.my_id(), world.local_hero.gold,
				world.local_hero.bag.filter(func(s): return s != null).map(func(s): return s["id"])])

## Клиент: положить ячейку сумки в обмен / убрать её оттуда.
func toggle_slot(idx: int) -> void:
	if state.is_empty():
		return
	var slots: Array = state["slots"].duplicate()
	if slots.has(idx):
		slots.erase(idx)
	elif slots.size() < MAX_ITEMS:
		slots.append(idx)
	else:
		world.hud.error("В обмен можно положить не больше %d вещей" % MAX_ITEMS)
		return
	send("request_offer", [slots, int(state["my_gold"])])

func set_gold(g: int) -> void:
	if not state.is_empty():
		send("request_offer", [state["slots"], g])

# ---------------------------------------------------------------- --tradetest

## Тест обмена (оба процесса с --tradetest --gold=N): хост на 12-й секунде предлагает обмен первому союзнику;
## каждый кладёт первую вещь из сумки и золото (хост 7, клиент 3), затем подтверждает. Выброс и подбор — на 6–14-й секунде.
var _test_t := 0.0

func _process(delta: float) -> void:
	if not Net.cli.has("tradetest") or world.local_hero == null:
		return
	var prev := _test_t
	_test_t += delta
	var lh = world.local_hero
	if prev < 6.0 and _test_t >= 6.0:
		var idx: int = lh.bag.find_custom(func(s): return s != null and not GameData.ItemData.is_gear_id(s["id"]))
		if idx >= 0:
			print("TRADE test drop me=%d item=%s" % [Net.my_id(), lh.bag[idx]["id"]])
			world.economy.send("request_drop", [idx])
	if prev < 7.0 and _test_t >= 7.0:
		_test_pick("own drop, must be refused")
	if prev < 12.5 and _test_t >= 12.5:
		_test_pick("after lock")
	if Net.is_server() and prev < 14.0 and _test_t >= 14.0:
		for h in world.heroes.values():
			if h != lh:
				print("TRADE test open with %d (dist %.1f)" % [h.hero_id, _dist(lh, h)])
				send("request_open", [h.hero_id])
				break

func _test_pick(what: String) -> void:
	var best := 0
	var best_d := 1e9
	for lid in world.economy._loot_nodes:
		var n: Node3D = world.economy._loot_nodes[lid]
		var d: float = n.global_position.distance_to(world.local_hero.global_position) if is_instance_valid(n) else 1e9
		if d < best_d:
			best_d = d
			best = int(lid)
	print("TRADE test pickup (%s) me=%d loot=%d" % [what, Net.my_id(), best])
	if best != 0:
		world.economy.send("request_pickup", [best])

func _test_react() -> void:
	if not Net.cli.has("tradetest") or state.is_empty() or world.local_hero == null:
		return
	var lh = world.local_hero
	if state["slots"].is_empty():
		var idx: int = lh.bag.find_custom(func(s): return s != null and GameData.ItemData.is_gear_id(s["id"]))
		if idx >= 0:
			var g := 7 if Net.is_server() else 3
			print("TRADE test offer me=%d item=%s gold=%d" % [Net.my_id(), lh.bag[idx]["id"], g])
			send.call_deferred("request_offer", [[idx], g])      # не изнутри чужого RPC: иначе хост примет себя за отправителя
		return
	if not state["theirs"].is_empty() and not state["my_ok"] and not (Net.cli.has("tradehold") and Net.is_server()):
		print("TRADE test accept me=%d" % Net.my_id())
		send.call_deferred("request_accept", [])
