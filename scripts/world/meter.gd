extends Node
## Счётчик урона и лечения (в духе Details / Recount). Считает только сервер: урон и лечение
## и так проходят через deal_damage / heal в spell_system.gd.
##
## Отрезки: «current» — текущий бой (волна), «last» — прошлая волна, «total» — вся партия.
## Режим игры начинает новый отрезок (у осады — на старте каждой волны).
## Клиентам 1 раз в секунду уходят только суммы по героям; разбивка по заклинаниям — по запросу,
## когда игрок навёл курсор на строку.

const SEGMENTS := ["current", "last", "total"]
const SEND_EVERY := 1.0

var world: Node3D
## отрезок -> {"name", "start", "end", "heroes": {hero_id -> строка}}
var segs: Dictionary = {}
var _send_acc := 0.0

## Клиентская копия: отрезок -> {"name", "time", "rows": [[hid, урон, лечение, перелечивание, получено, смерти], …]}
var view: Dictionary = {}
var detail: Dictionary = {}       # последний ответ на запрос разбивки
signal detail_received

func _ready() -> void:
	world = get_parent()
	for s in SEGMENTS:
		segs[s] = _new_seg("Вся партия" if s == "total" else "Подготовка")
		view[s] = {"name": segs[s]["name"], "time": 0.0, "rows": []}

func _new_seg(seg_name: String) -> Dictionary:
	return {"name": seg_name, "start": world.now() if world else 0.0, "end": -1.0, "heroes": {}}

static func _new_row() -> Dictionary:
	return {"dmg": 0.0, "heal": 0.0, "over": 0.0, "taken": 0.0, "deaths": 0, "kicks": 0,
		"by": {"dmg": {}, "heal": {}, "taken": {}, "deaths": {}, "kicks": {}}}

## Сервер: начался новый бой (волна): текущий отрезок становится «прошлым».
func new_segment(seg_name: String) -> void:
	if not Net.is_server():
		return
	var cur: Dictionary = segs["current"]
	cur["end"] = world.now()
	segs["last"] = cur
	segs["current"] = _new_seg(seg_name)

func reset_all() -> void:
	for s in SEGMENTS:
		segs[s] = _new_seg("Вся партия" if s == "total" else segs[s]["name"])

# ---------------------------------------------------------------- запись (сервер)

func _row(seg: Dictionary, hid: int) -> Dictionary:
	if not seg["heroes"].has(hid):
		seg["heroes"][hid] = _new_row()
	return seg["heroes"][hid]

## Ключ разбивки: заклинание, предмет, периодический эффект или тип врага.
static func _key(sid: String, src: Unit) -> String:
	if sid == "mob" and src:
		return "mob:" + src.type_id
	return sid if sid != "" else "other"

func _add(hid: int, field: String, amount: float, key: String, crit: bool, over: float = 0.0) -> void:
	for s in ["current", "total"]:
		var row := _row(segs[s], hid)
		row[field] += amount
		if over > 0.0:
			row["over"] += over
		var by: Dictionary = row["by"][field]
		if not by.has(key):
			by[key] = [0.0, 0, 0, 0.0]     # сумма, попаданий, критов, перелечивание
		var e: Array = by[key]
		e[0] += amount
		e[1] += 1
		e[2] += 1 if crit else 0
		e[3] += over

func on_damage(src: Unit, dst: Unit, amount: float, sid: String, crit: bool) -> void:
	if amount <= 0.0:
		return
	if src and src.kind == "hero":
		_add(src.id, "dmg", amount, _key(sid, src), crit)
	if dst.kind == "hero":
		_add(dst.id, "taken", amount, _key(sid, src), crit)

func on_heal(src: Unit, dst: Unit, amount: float, over: float, sid: String, crit: bool) -> void:
	if src and src.kind == "hero" and (amount > 0.0 or over > 0.0):
		_add(src.id, "heal", amount, _key(sid, src), crit, over)

## Герой сбил каст врага (прерывание).
func on_interrupt(src: Unit, target: Unit = null) -> void:
	if src.kind != "hero":
		return
	for s in ["current", "total"]:
		var row := _row(segs[s], src.id)
		row["kicks"] += 1
		var k := ("mob:" + target.type_id) if target else "other"
		var e: Array = row["by"]["kicks"].get(k, [0.0, 0, 0, 0.0])
		row["by"]["kicks"][k] = [float(e[0]) + 1.0, int(e[1]) + 1, 0, 0.0]

func on_death(dst: Unit, src: Unit) -> void:
	if dst.kind != "hero":
		return
	for s in ["current", "total"]:
		var row := _row(segs[s], dst.id)
		row["deaths"] += 1
		var k := src.display_name if src else "?"
		row["by"]["deaths"][k] = [float(row["by"]["deaths"].get(k, [0.0])[0]) + 1.0, 1, 0, 0.0]

# ---------------------------------------------------------------- сеть

func server_tick(delta: float) -> void:
	_send_acc += delta
	if _send_acc < SEND_EVERY:
		return
	_send_acc = 0.0
	var packed: Dictionary = {}
	var t: float = world.now()
	for s in SEGMENTS:
		var seg: Dictionary = segs[s]
		var rows: Array = []
		for hid in seg["heroes"]:
			var r: Dictionary = seg["heroes"][hid]
			rows.append([hid, roundf(r["dmg"]), roundf(r["heal"]), roundf(r["over"]), roundf(r["taken"]), r["deaths"], r["kicks"]])
		var dur: float = (float(seg["end"]) if float(seg["end"]) > 0.0 else t) - float(seg["start"])
		packed[s] = [seg["name"], maxf(1.0, dur), rows]
	ev_meter.rpc(packed)

@rpc("authority", "call_local", "unreliable_ordered")
func ev_meter(packed: Dictionary) -> void:
	for s in packed:
		var p: Array = packed[s]
		view[s] = {"name": p[0], "time": p[1], "rows": p[2]}

## Клиент просит разбивку: отрезок, герой, режим (dmg | heal | taken | deaths).
@rpc("any_peer", "reliable")
func request_detail(seg: String, hid: int, field: String) -> void:
	if not Net.is_server() or not segs.has(seg) or not field in ["dmg", "heal", "taken", "deaths", "kicks"]:
		return
	var by: Dictionary = segs[seg]["heroes"].get(hid, _new_row())["by"][field]
	var list: Array = []
	for k in by:
		list.append([k, by[k][0], by[k][1], by[k][2], by[k][3]])
	list.sort_custom(func(a, b): return a[1] > b[1])
	var peer := multiplayer.get_remote_sender_id()
	if peer == 0 or peer == multiplayer.get_unique_id():
		ev_detail(seg, hid, field, list.slice(0, 12))
	else:
		ev_detail.rpc_id(peer, seg, hid, field, list.slice(0, 12))

@rpc("authority", "reliable")
func ev_detail(seg: String, hid: int, field: String, list: Array) -> void:
	detail = {"seg": seg, "hid": hid, "field": field, "list": list}
	detail_received.emit()

@rpc("any_peer", "reliable")
func request_reset() -> void:
	if Net.is_server():
		reset_all()

func send(method: String, args: Array) -> void:
	if Net.is_server():
		callv(method, args)
	else:
		callv("rpc_id", [1, method] + args)

## Название строки разбивки для людей.
static func key_name(k: String) -> String:
	if k == "auto":
		return "Автоатака"
	if k == "other":
		return "Прочее"
	if k.begins_with("mob:"):
		var mid := k.trim_prefix("mob:")
		return GameData.MOBS[mid]["name"] if GameData.MOBS.has(mid) else mid
	if k.begins_with("affix:"):
		return "Аффикс: " + str(GameData.AFFIXES.get(k.trim_prefix("affix:"), {}).get("name", k))
	if k.begins_with("mab:"):
		return GameData.MOB_ABILITIES.get(k.trim_prefix("mab:"), {}).get("name", k)
	if k.begins_with("item:"):
		var it := GameData.item(k.trim_prefix("item:"))
		return it.get("name", k)
	if GameData.SPELLS.has(k):
		return GameData.SPELLS[k]["name"]
	if GameData.AUTO_SPELLS.has(k):
		return GameData.AUTO_SPELLS[k]["name"]
	if GameData.BUFF_INFO.has(k):
		return GameData.BUFF_INFO[k]["name"]
	return k
