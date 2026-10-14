extends Node
## Рейдовые метки и пинги — главный способ договориться без голосовой связи.
## Метки: 8 штук, как в WoW (1 звезда … 8 череп), одна метка — на одном существе, при смерти снимается.
## Ставит любой игрок; хост может оставить это только себе (Net.settings["marks_host_only"]).
## Пинг: Alt+ЛКМ по земле — маркер на 4 с с именем и звуком; по врагу — «бить сюда». Не чаще раза в секунду.
## Всё решает сервер: клиент просит (request_*), сервер рассылает (ev_*).

const MARKS := [
	{"id": "star", "name": "Звезда", "color": Color(1.0, 0.85, 0.2)},
	{"id": "circle", "name": "Круг", "color": Color(1.0, 0.55, 0.1)},
	{"id": "diamond", "name": "Ромб", "color": Color(0.72, 0.36, 1.0)},
	{"id": "triangle", "name": "Треугольник", "color": Color(0.23, 0.84, 0.35)},
	{"id": "moon", "name": "Луна", "color": Color(0.8, 0.88, 1.0)},
	{"id": "square", "name": "Квадрат", "color": Color(0.2, 0.5, 1.0)},
	{"id": "cross", "name": "Крест", "color": Color(0.9, 0.15, 0.15)},
	{"id": "skull", "name": "Череп", "color": Color(0.95, 0.95, 0.95)},
]
const PING_TIME := 4.0
const PING_COOLDOWN := 1.0

var world: Node3D
## Номер метки (1..8) -> id существа. Сервер — истина, клиенты — копия.
var marks: Dictionary = {}
var _ping_ready: Dictionary = {}     # peer -> время, когда можно пинговать снова
var _pings: Array = []               # клиент: [{node, until, unit}]

func _ready() -> void:
	world = get_parent()

static func texture(idx: int) -> Texture2D:
	return load("res://assets/icons/marks/%s.svg" % MARKS[idx - 1]["id"]) as Texture2D

## Номер метки на существе (0 — нет).
func mark_of(uid: int) -> int:
	for idx in marks:
		if int(marks[idx]) == uid:
			return int(idx)
	return 0

func send(method: String, args: Array) -> void:
	if Net.is_server():
		callv(method, args)
	else:
		callv("rpc_id", [1, method] + args)

func _sender() -> int:
	var p := multiplayer.get_remote_sender_id()
	return p if p != 0 else multiplayer.get_unique_id()

# ---------------------------------------------------------------- метки (сервер)

## idx 1..8; idx 0 — снять метку с существа. Та же метка на том же существе — снимается.
@rpc("any_peer", "reliable")
func request_mark(uid: int, idx: int) -> void:
	if not Net.is_server():
		return
	if bool(Net.settings.get("marks_host_only", false)) and _sender() != 1:
		return
	var u: Unit = world.get_unit(uid)
	if u == null or not u.alive or idx < 0 or idx > MARKS.size():
		return
	var had := mark_of(uid)
	if had != 0:
		marks.erase(had)
	if idx != 0 and idx != had:
		marks[idx] = uid
	ev_marks.rpc(marks)

func on_unit_died(uid: int) -> void:
	if Net.is_server() and mark_of(uid) != 0:
		marks.erase(mark_of(uid))
		ev_marks.rpc(marks)

@rpc("authority", "call_local", "reliable")
func ev_marks(m: Dictionary) -> void:
	marks = m

# ---------------------------------------------------------------- пинги

@rpc("any_peer", "reliable")
func request_ping(pos: Vector3, uid: int) -> void:
	if not Net.is_server():
		return
	var peer := _sender()
	var t: float = world.now()
	if t < float(_ping_ready.get(peer, 0.0)):
		return
	_ping_ready[peer] = t + PING_COOLDOWN
	var who := "?"
	var col := Color(1, 0.85, 0.4)
	for h in world.heroes.values():
		if h.peer_id == peer:
			who = h.player_name
			col = GameData.CLASSES[h.class_id]["color"]
	var u: Unit = world.get_unit(uid)
	if u and (not u.alive or u.team != Unit.Team.ENEMIES):
		uid = 0
	ev_ping.rpc(pos, uid, who, col)

@rpc("authority", "call_local", "reliable")
func ev_ping(pos: Vector3, uid: int, who: String, col: Color) -> void:
	Sfx.play("ping")
	var root := Node3D.new()
	world.vfx_root.add_child(root)
	root.global_position = pos
	var tag := Label3D.new()
	tag.text = ("⚔ Бить сюда!\n%s" % who) if uid != 0 else who
	tag.modulate = col.lightened(0.3)
	tag.outline_modulate = Color(0, 0, 0, 0.9)
	tag.outline_size = 10
	tag.font_size = 30
	tag.pixel_size = 0.0014
	tag.fixed_size = true          # одинаково читается вблизи и вдали
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.no_depth_test = true
	tag.position.y = 3.6 if uid != 0 else 1.6
	root.add_child(tag)
	if uid == 0:
		var ring := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(2, 2)
		ring.mesh = pm
		ring.material_override = Vfx.ring_material(col, 0.0, false, 1.0)
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ring.position.y = 0.06
		root.add_child(ring)
		root.set_meta("ring", ring)
		var beam := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.06
		cyl.bottom_radius = 0.06
		cyl.height = 3.0
		beam.mesh = cyl
		var bm := StandardMaterial3D.new()
		bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		bm.albedo_color = Color(col.r, col.g, col.b, 0.6)
		bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		beam.material_override = bm
		beam.position.y = 1.5
		root.add_child(beam)
	_pings.append({"node": root, "until": world.now() + PING_TIME, "unit": uid, "t0": world.now()})

func _process(_delta: float) -> void:
	if _pings.is_empty():
		return
	var t: float = world.now()
	var i := 0
	while i < _pings.size():
		var p: Dictionary = _pings[i]
		var node: Node3D = p["node"]
		if t >= float(p["until"]) or not is_instance_valid(node):
			if is_instance_valid(node):
				node.queue_free()
			_pings.remove_at(i)
			continue
		var uid: int = p["unit"]
		if uid != 0:
			var u: Unit = world.get_unit(uid)
			if u == null or not u.alive:
				p["until"] = 0.0
			else:
				var at := u.pos
				if u.node and is_instance_valid(u.node):
					at = u.node.global_position
				node.global_position = at
		elif node.has_meta("ring"):
			var k: float = fmod(t - float(p["t0"]), 1.0)
			var r := 0.6 + 2.4 * k
			(node.get_meta("ring") as Node3D).scale = Vector3(r, 1, r)
		i += 1
