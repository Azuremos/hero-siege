extends Node
## Управление своим героем в стиле World of Warcraft:
##  ПКМ (зажать) — поворот камеры и героя, ЛКМ (зажать) — обзор камерой,
##  ЛКМ+ПКМ — бег вперёд, WASD/QE — движение, колесо — приближение,
##  ЛКМ по существу — выбрать цель, ПКМ по врагу — автоатака, Tab — следующий враг,
##  1–8 — заклинания, F1–F6 — выбор союзника, Esc — отмена.

const MOUSE_SENS := 0.006
const DRAG_THRESHOLD := 4.0

var hero: CharacterBody3D
var world: Node3D

var cam_yaw := 0.0
var cam_pitch := -0.32
var zoom := 11.0
var rig: Node3D
var spring: SpringArm3D
var camera: Camera3D

var move_forward := 0.0
var move_strafe := 0.0
var turn_input := 0.0
var steering := false
var _jump_queued := false

var _lmb := false
var _rmb := false
var _press_pos := Vector2.ZERO
var _dragged := false

# цель и заклинания
var target_id := 0
var cd_until: Dictionary = {}
var gcd_until := 0.0
var cast_spell := ""
var cast_start := 0.0
var cast_duration := 0.0
var _cancel_sent := false

# прицеливание по земле
var aim_spell := ""
var _reticle: MeshInstance3D
var _wall_preview: MeshInstance3D

func _ready() -> void:
	hero = get_parent()
	world = hero.world
	cam_yaw = hero.rotation.y
	rig = Node3D.new()
	rig.top_level = true
	add_child(rig)
	spring = SpringArm3D.new()
	spring.collision_mask = 1
	spring.margin = 0.3
	var sph := SphereShape3D.new()
	sph.radius = 0.3
	spring.shape = sph
	spring.spring_length = zoom
	rig.add_child(spring)
	camera = Camera3D.new()
	camera.fov = 65.0
	camera.far = 420.0
	spring.add_child(camera)
	camera.current = true
	spring.add_excluded_object(hero.get_rid())
	load_bar()

	_reticle = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(2, 2)
	_reticle.mesh = pm
	_reticle.top_level = true
	_reticle.visible = false
	_reticle.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_reticle)
	_wall_preview = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1, 2.2, 1.4)
	_wall_preview.mesh = bm
	_wall_preview.top_level = true
	_wall_preview.visible = false
	_wall_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_wall_preview)

func now() -> float:
	return world.now()

# ---------------------------------------------------------------- ввод

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			zoom = maxf(2.5, zoom * 0.88)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			zoom = minf(30.0, zoom * 1.12)
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			_mouse_button(mb)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _lmb or _rmb:
			if not _dragged and mm.position.distance_to(_press_pos) > DRAG_THRESHOLD:
				_dragged = true
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			if _dragged:
				cam_yaw -= mm.relative.x * MOUSE_SENS
				cam_pitch = clampf(cam_pitch - mm.relative.y * MOUSE_SENS, -1.4, 0.55)
	elif event is InputEventKey and event.pressed and not event.echo:
		_key(event as InputEventKey)

func _mouse_button(mb: InputEventMouseButton) -> void:
	var is_left := mb.button_index == MOUSE_BUTTON_LEFT
	if mb.pressed:
		if aim_spell != "":
			if is_left:
				if GameData.SPELLS[aim_spell]["target"] == "wall":
					# стена: начало — здесь, конец — там, где отпустим кнопку
					var gp = ground_point(mb.position)
					if gp != null and _dist_to_point(gp) <= GameData.eff_range(hero.unit, aim_spell):
						_wall_start = gp
					else:
						world.hud.error("Слишком далеко")
				else:
					_confirm_aim(mb.position)
			else:
				cancel_aim()
			get_viewport().set_input_as_handled()
			return
		if not _lmb and not _rmb:
			_press_pos = mb.position
			_dragged = false
		if is_left:
			_lmb = true
		else:
			_rmb = true
	else:
		if is_left and _wall_start != null and aim_spell != "":
			_confirm_wall(mb.position)
			get_viewport().set_input_as_handled()
			return
		var was_drag := _dragged
		if is_left:
			if not _lmb:
				return
			_lmb = false
		else:
			if not _rmb:
				return
			_rmb = false
		if not _lmb and not _rmb:
			if was_drag:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				Input.warp_mouse(_press_pos)
			else:
				_click(mb.position, is_left)
			_dragged = false

func _click(pos: Vector2, is_left: bool) -> void:
	# Alt+ЛКМ — пинг: по врагу «бить сюда», по земле — метка на 4 с
	if is_left and Input.is_key_pressed(KEY_ALT):
		var pid := pick_unit(pos)
		var pu: Unit = world.get_unit(pid)
		if pu and pu.alive and pu.team == Unit.Team.ENEMIES:
			world.marks.send("request_ping", [pu.pos, pid])
		else:
			var gp = ground_point(pos)
			if gp != null:
				world.marks.send("request_ping", [gp, 0])
		return
	if not is_left:
		var vid: String = world.economy.pick_vendor(camera, pos)
		if vid != "":
			if _dist_to_point(world.economy.vendor_pos[vid]) <= world.economy.VENDOR_RANGE:
				world.hud.open_shop(vid)
			else:
				world.hud.error("Подойдите ближе к торговцу")
			return
	var id := pick_unit(pos)
	if id == 0:
		return
	target_id = id
	var u: Unit = world.get_unit(id)
	if not is_left and u and u.team == Unit.Team.ENEMIES:
		_send_server("request_auto", [id])

func _key(k: InputEventKey) -> void:
	var code := k.physical_keycode
	var action: String = Keys.action_for_event(k)
	if action.begins_with("bar"):
		var parts := action.trim_prefix("bar").split("_")
		try_cast_slot(int(parts[0]) - 1, int(parts[1]))
	elif action == "talents":
		world.hud.toggle_talents()
	elif action == "character":
		world.hud.toggle_character()
	elif action == "meter":
		world.hud.toggle_meter()
	elif action.begins_with("mark_"):
		if target_id != 0:
			world.marks.send("request_mark", [target_id, int(action.trim_prefix("mark_"))])
	elif action == "spellbook":
		world.hud.toggle_spellbook()
	elif code >= KEY_F1 and code <= KEY_F6:
		var ids: Array = world.hud.party_order()
		var idx := code - KEY_F1
		if idx < ids.size():
			target_id = ids[idx]
	elif code == KEY_TAB:
		target_next_enemy()
	elif code == KEY_ESCAPE:
		if world.hud.close_windows():
			pass
		elif aim_spell != "":
			cancel_aim()
		elif cast_spell != "":
			_send_server("request_cancel", [])
		elif target_id != 0:
			target_id = 0
		else:
			world.hud.toggle_menu()
	elif code == KEY_SPACE:
		_jump_queued = true
	elif code == KEY_H:
		world.hud.toggle_help()

func consume_jump() -> bool:
	var j := _jump_queued
	_jump_queued = false
	return j

func _process(delta: float) -> void:
	var typing: bool = world.hud.is_typing()
	var w := Input.is_action_pressed("move_forward") and not typing
	var s := Input.is_action_pressed("move_back") and not typing
	var a := Input.is_action_pressed("turn_left") and not typing
	var d := Input.is_action_pressed("turn_right") and not typing
	var q := Input.is_action_pressed("strafe_left") and not typing
	var e := Input.is_action_pressed("strafe_right") and not typing
	move_forward = (1.0 if w else 0.0) - (1.0 if s else 0.0)
	if _lmb and _rmb:
		move_forward = 1.0
	move_strafe = (1.0 if e else 0.0) - (1.0 if q else 0.0)
	steering = _rmb
	turn_input = 0.0
	if _rmb:
		move_strafe += (1.0 if d else 0.0) - (1.0 if a else 0.0)
	else:
		turn_input = (1.0 if a else 0.0) - (1.0 if d else 0.0)
	move_strafe = clampf(move_strafe, -1.0, 1.0)
	if bot_active():
		bot_tick(delta)

	# Камера следует за героем, если её не крутят мышью.
	if not _lmb and not _rmb:
		if turn_input != 0.0:
			cam_yaw = hero.rotation.y + turn_input * hero.TURN_SPEED * delta
		elif hero.is_moving():
			cam_yaw = lerp_angle(cam_yaw, hero.rotation.y, 1.0 - exp(-2.5 * delta))
	var head: float = 2.0 * hero.model.scale.y
	rig.global_position = hero.global_position + Vector3(0, head, 0)
	rig.rotation = Vector3(cam_pitch, cam_yaw, 0)
	spring.spring_length = lerpf(spring.spring_length, zoom, 1.0 - exp(-12.0 * delta))

	# Движение прерывает произнесение.
	if cast_spell != "" and hero.is_moving() and not _cancel_sent:
		_cancel_sent = true
		_send_server("request_cancel", [])

	var tu: Unit = world.get_unit(target_id)
	if tu and not tu.alive and tu.kind == "mob":
		target_id = 0
	_update_aim()

# ---------------------------------------------------------------- выбор целей

## Ищет существо под курсором (без физики — проекция на экран, дёшево).
func pick_unit(screen_pos: Vector2) -> int:
	var best := 0
	var best_score := 1e9
	var vp_h := get_viewport().get_visible_rect().size.y
	var tan_half := tan(deg_to_rad(camera.fov) * 0.5)
	for u: Unit in world.units.values():
		if u.kind == "castle" or not u.alive:
			continue
		var h := 1.2 * (u.radius / 0.6)
		var p := u.pos + Vector3(0, h, 0)
		if camera.is_position_behind(p):
			continue
		var dist := camera.global_position.distance_to(p)
		var r_px := clampf((u.radius * 1.8 + 0.4) / (dist * tan_half) * vp_h * 0.5, 12.0, 140.0)
		var d := camera.unproject_position(p).distance_to(screen_pos)
		if d < r_px and d / r_px < best_score:
			best_score = d / r_px
			best = u.id
	return best

func target_next_enemy() -> void:
	var fwd := -hero.global_transform.basis.z
	var cands: Array = []
	for u: Unit in world.units.values():
		if u.team != Unit.Team.ENEMIES or not u.alive:
			continue
		var to := u.pos - hero.global_position
		var dist := to.length()
		if dist > 40.0:
			continue
		var facing := fwd.dot(to.normalized())
		if facing < 0.2:
			continue
		cands.append([dist, u.id])
	if cands.is_empty():
		return
	cands.sort_custom(func(x, y): return x[0] < y[0])
	var idx := 0
	for i in cands.size():
		if cands[i][1] == target_id:
			idx = (i + 1) % cands.size()
	target_id = cands[idx][1]

func ground_point(screen_pos: Vector2) -> Variant:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if dir.y >= -0.001:
		return null
	var t := -from.y / dir.y
	return from + dir * t

# ---------------------------------------------------------------- заклинания

func spell_ids() -> Array:
	return hero.spell_list()

func try_cast_slot(b: int, slot: int) -> void:
	if b < bars.size() and slot < bars[b].size() and bars[b][slot] != "":
		try_cast(bars[b][slot])

# ---------------------------------------------------------------- две панели заклинаний (раскладка сохраняется для каждого класса)

const BAR_PATH := "user://action_bars.cfg"
const BAR_SIZE := 12
const BAR_COUNT := 2
var bars: Array = []          # [панель][ячейка] -> id заклинания или ""
var _seen: Array = []         # заклинания, которые уже предлагались (новые сами встают на свободное место)

## Совместимость: первая панель.
var bar: Array:
	get:
		return bars[0]

func load_bar() -> void:
	bars = []
	_seen = []
	var cfg := ConfigFile.new()
	if Net.cli.is_empty() and cfg.load(BAR_PATH) == OK:
		var saved = cfg.get_value("bars2", hero.class_id, null)
		if saved is Array and saved.size() == BAR_COUNT:
			bars = saved
		else:
			var old = cfg.get_value("bars", hero.class_id, [])
			if old is Array and old.size() == BAR_SIZE:
				bars = [old, []]
		_seen = cfg.get_value("seen", hero.class_id, [])
	if bars.is_empty():
		bars = [[], []]
	for b in BAR_COUNT:
		var arr: Array = bars[b] if b < bars.size() else []
		arr.resize(BAR_SIZE)
		for i in BAR_SIZE:
			if arr[i] == null or not (GameData.SPELLS.has(str(arr[i])) or (str(arr[i]).begins_with("item:") and not GameData.item(str(arr[i]).trim_prefix("item:")).is_empty())):
				arr[i] = ""
		if b < bars.size():
			bars[b] = arr
		else:
			bars.append(arr)
	sync_bar()

func save_bar() -> void:
	if not Net.cli.is_empty():
		return   # тестовые запуски не трогают раскладку игрока
	var cfg := ConfigFile.new()
	cfg.load(BAR_PATH)
	cfg.set_value("bars2", hero.class_id, bars)
	cfg.set_value("seen", hero.class_id, _seen)
	cfg.save(BAR_PATH)

func _find(sid: String) -> Vector2i:
	for b in BAR_COUNT:
		var i: int = bars[b].find(sid)
		if i >= 0:
			return Vector2i(b, i)
	return Vector2i(-1, -1)

## Убирает забытые заклинания (сброс талантов) и ставит новые в свободные ячейки.
func sync_bar() -> void:
	var known := spell_ids()
	for b in BAR_COUNT:
		for i in BAR_SIZE:
			if bars[b][i] != "" and not str(bars[b][i]).begins_with("item:") and not known.has(bars[b][i]):
				bars[b][i] = ""
	for sid in known:
		if _seen.has(sid):
			continue
		_seen.append(sid)
		if _find(sid).x >= 0:
			continue
		for b in BAR_COUNT:
			var free: int = bars[b].find("")
			if free >= 0:
				bars[b][free] = sid
				break
	save_bar()

func swap_slots(b1: int, a: int, b2: int, b: int) -> void:
	var tmp = bars[b1][a]
	bars[b1][a] = bars[b2][b]
	bars[b2][b] = tmp
	save_bar()

func place_spell(sid: String, b: int, slot: int) -> void:
	var old := _find(sid)
	if old.x >= 0:
		bars[old.x][old.y] = bars[b][slot]
	bars[b][slot] = sid
	save_bar()

func clear_slot(b: int, slot: int) -> void:
	bars[b][slot] = ""
	save_bar()
var potion_until := 0.0

func try_cast(sid: String) -> void:
	var hud = world.hud
	if sid.begins_with("item:"):
		# предмет на панели: выпить зелье (первая стопка в сумке)
		if not hero.unit.alive:
			return
		if now() < potion_until:
			hud.error("Зелья ещё не готовы")
			return
		if hero.bag_count(sid.trim_prefix("item:")) <= 0:
			hud.error("Нет в сумке")
			return
		world.economy.send("request_use_id", [sid.trim_prefix("item:")])
		return
	var sp: Dictionary = GameData.SPELLS[sid]
	if not hero.unit.alive:
		return
	if hero.unit.level < GameData.spell_level(sid):
		hud.error("Откроется на %d уровне" % GameData.spell_level(sid))
		return
	if hero.net_stun_left > 0.0:
		hud.error("Вы оглушены")
		return
	if cast_spell != "":
		hud.error("Вы уже произносите заклинание")
		return
	if now() < float(cd_until.get(sid, 0.0)):
		hud.error("Заклинание ещё не готово")
		return
	if now() < gcd_until:
		return
	if hero.unit.mana < GameData.eff_mana(hero.unit, sid):
		hud.error("Недостаточно маны")
		return
	var max_range := GameData.eff_range(hero.unit, sid)
	match sp["target"]:
		"enemy":
			var t: Unit = world.get_unit(target_id)
			if t == null or not t.alive or t.team != Unit.Team.ENEMIES:
				target_next_enemy()
				t = world.get_unit(target_id)
				if t == null or t.team != Unit.Team.ENEMIES:
					hud.error("Нет цели")
					return
			if _dist_to(t) > max_range + t.radius:
				hud.error("Цель слишком далеко")
				return
			_face(t.pos)
			_send_server("request_cast", [sid, t.id, Vector3.ZERO, 0.0])
		"ally":
			var t := _ally_target()
			if _dist_to(t) > max_range + 1.0:
				hud.error("Цель слишком далеко")
				return
			_send_server("request_cast", [sid, t.id, Vector3.ZERO, 0.0])
		"self":
			_send_server("request_cast", [sid, hero.hero_id, Vector3.ZERO, 0.0])
		"ground", "wall":
			aim_spell = sid

func _ally_target() -> Unit:
	var hover_id: int = world.hud.hover_unit_id
	if hover_id == 0:
		var mp := get_viewport().get_mouse_position()
		var under := pick_unit(mp)
		var uu: Unit = world.get_unit(under)
		if uu and uu.kind == "hero" and uu.alive:
			hover_id = under
	var u: Unit = world.get_unit(hover_id)
	if u and u.kind == "hero" and u.alive:
		return u
	u = world.get_unit(target_id)
	if u and u.kind == "hero" and u.alive:
		return u
	return hero.unit

func _dist_to(u: Unit) -> float:
	return Vector2(u.pos.x - hero.global_position.x, u.pos.z - hero.global_position.z).length()

func _face(p: Vector3) -> void:
	if hero.is_moving():
		return
	var to := p - hero.global_position
	if Vector2(to.x, to.z).length() > 0.1:
		hero.rotation.y = atan2(-to.x, -to.z)

func cancel_aim() -> void:
	aim_spell = ""
	_wall_start = null
	_reticle.visible = false
	_wall_preview.visible = false

func _update_aim() -> void:
	if aim_spell == "":
		return
	var sp: Dictionary = GameData.SPELLS[aim_spell]
	var gp = ground_point(get_viewport().get_mouse_position())
	if gp == null:
		_reticle.visible = false
		_wall_preview.visible = false
		return
	var p: Vector3 = gp
	var in_range := _dist_to_point(p) <= GameData.eff_range(hero.unit, aim_spell)
	var col: Color = GameData.SCHOOLS[sp["school"]]["color"]
	if not in_range:
		col = Color(1, 0.25, 0.2)
	if sp["target"] == "ground":
		var r: float = float(sp.get("radius", 5.0)) + hero.unit.mod("radius_add", aim_spell, sp["school"])
		_reticle.visible = true
		_reticle.global_position = p + Vector3(0, 0.06, 0)
		_reticle.scale = Vector3(r, 1, r)
		_reticle.material_override = Vfx.ring_material(col, 0.25)
		_wall_preview.visible = false
	else:
		var max_len: float = _wall_max(aim_spell)
		_wall_preview.visible = true
		_reticle.visible = false
		if _wall_start == null:
			# ещё не начали рисовать — показываем стену по умолчанию (поперёк взгляда)
			_wall_preview.global_position = p + Vector3(0, 1.1, 0)
			_wall_preview.rotation = Vector3(0, _wall_yaw(p), 0)
			_wall_preview.scale = Vector3(max_len, 0.3, 0.6)
		else:
			var seg := _wall_segment(_wall_start, p, aim_spell)
			var a: Vector3 = seg[0]
			var b: Vector3 = seg[1]
			col = GameData.SCHOOLS[sp["school"]]["color"]
			_wall_preview.global_position = (a + b) * 0.5 + Vector3(0, 1.1, 0)
			_wall_preview.rotation = Vector3(0, seg[2], 0)
			_wall_preview.scale = Vector3(maxf(a.distance_to(b), 0.6), 1, 1)
		_wall_preview.material_override = Vfx.preview_material(col)

func _dist_to_point(p: Vector3) -> float:
	return Vector2(p.x - hero.global_position.x, p.z - hero.global_position.z).length()

var _wall_start = null   # Vector3 — точка, где зажали кнопку

func _wall_max(sid: String) -> float:
	var sp: Dictionary = GameData.SPELLS[sid]
	return float(sp["length"]) + hero.unit.mod("length_add", sid, sp["school"])

## Отрезок стены от a к b, обрезанный по максимальной длине: [a, b, yaw].
func _wall_segment(a: Vector3, b: Vector3, sid: String) -> Array:
	var d := Vector3(b.x - a.x, 0, b.z - a.z)
	var max_len := _wall_max(sid)
	if d.length() > max_len:
		d = d.normalized() * max_len
	var yaw := atan2(-d.z, d.x) if d.length() > 0.01 else _wall_yaw(a)
	return [Vector3(a.x, 0, a.z), Vector3(a.x + d.x, 0, a.z + d.z), yaw]

func _confirm_wall(screen_pos: Vector2) -> void:
	var sid := aim_spell
	var a: Vector3 = _wall_start
	var gp = ground_point(screen_pos)
	cancel_aim()
	var b: Vector3 = gp if gp != null else a
	if Vector2(b.x - a.x, b.z - a.z).length() < 1.5:
		# просто клик — стена максимальной длины поперёк взгляда
		_face(a)
		_send_server("request_cast", [sid, 0, a, _wall_yaw(a), 0.0])
		return
	var seg := _wall_segment(a, b, sid)
	var center: Vector3 = (seg[0] + seg[1]) * 0.5
	_face(center)
	_send_server("request_cast", [sid, 0, center, seg[2], (seg[0] as Vector3).distance_to(seg[1])])

## Стена ставится поперёк направления от героя к точке.
func _wall_yaw(p: Vector3) -> float:
	var to := p - hero.global_position
	if Vector2(to.x, to.z).length() < 0.5:
		return hero.rotation.y
	return atan2(-to.x, -to.z)

func _confirm_aim(screen_pos: Vector2) -> void:
	var sid := aim_spell
	var sp: Dictionary = GameData.SPELLS[sid]
	var gp = ground_point(screen_pos)
	cancel_aim()
	if gp == null:
		return
	var p: Vector3 = gp
	if _dist_to_point(p) > GameData.eff_range(hero.unit, sid):
		world.hud.error("Слишком далеко")
		return
	_face(p)
	_send_server("request_cast", [sid, 0, p, _wall_yaw(p)])

# ---------------------------------------------------------------- события от сервера

var cast_channel := false
func on_cast_started(sid: String, duration: float, channel: bool = false) -> void:
	cast_channel = channel
	cast_spell = sid
	cast_start = now()
	cast_duration = duration
	_cancel_sent = false

func on_cast_ended(ok: bool) -> void:
	if cast_spell != "" and not ok:
		world.hud.error("Прервано")
	cast_spell = ""
	_cancel_sent = false

func on_feedback(sid: String, err: String, cd: float, gcd: float) -> void:
	if err != "":
		world.hud.error(err)
		return
	if cd > 0.0:
		cd_until[sid] = now() + cd
	if gcd > 0.0:
		gcd_until = now() + gcd

func _send_server(method: String, args: Array) -> void:
	world.spells.send_to_server(method, args)

# ---------------------------------------------------------------- бот для автотестов (--bot)

var _bot_t := 0.0
var _bot_ally := 0

func bot_active() -> bool:
	return Net.cli.has("bot")

func bot_tick(delta: float) -> void:
	var post := Vector3(0, 0, 26)
	if Net.cli.has("post"):
		var f: PackedFloat64Array = Net.cli["post"].split_floats(",")
		post = Vector3(f[0], 0, f[1])
	var to := post - hero.global_position
	var stop := 2.5
	# бойцы ближнего боя подходят к цели (недалеко от поста)
	var melee_range := float(GameData.CLASSES[hero.class_id]["auto"]["range"])
	var mt: Unit = world.get_unit(target_id)
	if melee_range <= 5.0 and mt and mt.alive and Vector2(mt.pos.x - post.x, mt.pos.z - post.z).length() < 22.0:
		to = mt.pos - hero.global_position
		stop = melee_range - 0.8 + mt.radius
	to.y = 0
	if to.length() > stop and cast_spell == "":
		hero.rotation.y = atan2(-to.x, -to.z)
		cam_yaw = hero.rotation.y
		move_forward = 1.0
	else:
		move_forward = 0.0
	_bot_t -= delta
	if _bot_t > 0.0 or cast_spell != "" or not hero.unit.alive:
		return
	_bot_t = 0.25
	_bot_learn_talents()
	if now() < gcd_until:
		return
	# цель
	var tu: Unit = world.get_unit(target_id)
	if tu == null or not tu.alive or tu.team != Unit.Team.ENEMIES or _dist_to(tu) > 32.0:
		target_id = 0
		var best := 1e9
		for u: Unit in world.units.values():
			if u.team == Unit.Team.ENEMIES and u.alive and _dist_to(u) < minf(best, 32.0):
				best = _dist_to(u)
				target_id = u.id
		tu = world.get_unit(target_id)
	# самый раненый союзник
	var weakest: Unit = null
	for h in world.heroes.values():
		if h.unit.alive and (weakest == null or h.unit.hp_frac() < weakest.hp_frac()):
			weakest = h.unit
	var near_enemies := 0
	for u: Unit in world.units.values():
		if u.team == Unit.Team.ENEMIES and u.alive and _dist_to(u) < 8.0:
			near_enemies += 1
	for sid in _bot_priority():
		var sp: Dictionary = GameData.SPELLS[sid]
		if hero.unit.level < GameData.spell_level(sid):
			continue
		if now() < float(cd_until.get(sid, 0.0)) or hero.unit.mana < GameData.eff_mana(hero.unit, sid):
			continue
		# условия, которые сервер всё равно отклонит: Рывок вплотную, Казнь по здоровой цели
		if sp.has("min_range") and (tu == null or _dist_to(tu) < float(sp["min_range"])):
			continue
		if sp.has("execute") and (tu == null or (tu.hp_frac() > float(sp["execute"]) and GameData.active_proc(hero.unit, sid).is_empty())):
			continue
		var long_buff := _long_buff_key(sp)
		if long_buff != "":
			if not hero._has_buff(long_buff):
				_send_server("request_cast", [sid, hero.hero_id, Vector3.ZERO, 0.0])
				return
			continue
		if sid == "prayer_of_healing":
			if weakest and weakest.hp_frac() < 0.75:
				_send_server("request_cast", [sid, hero.hero_id, Vector3.ZERO, 0.0])
				return
			continue
		match sp["target"]:
			"ally":
				var need := 0.5 if sid == "lay_on_hands" else 0.85
				if sid == "lay_on_hands":
					need = 0.25
				if weakest and weakest.hp_frac() < need and not (sp.has("target_lockout") and weakest.has_buff(sp["target_lockout"]["key"])):
					_bot_ally = weakest.id
					_send_server("request_cast", [sid, weakest.id, Vector3.ZERO, 0.0])
					return
			"self":
				if sid == "divine_shield":
					if hero.unit.hp_frac() < 0.3:
						_send_server("request_cast", [sid, hero.hero_id, Vector3.ZERO, 0.0])
						return
				elif near_enemies >= 2:
					_send_server("request_cast", [sid, hero.hero_id, Vector3.ZERO, 0.0])
					return
			"enemy":
				if tu and _dist_to(tu) <= float(sp["range"]) + tu.radius:
					_face(tu.pos)
					_send_server("request_cast", [sid, tu.id, Vector3.ZERO, 0.0])
					return
			"ground", "wall":
				if tu and _dist_to(tu) <= float(sp["range"]) - 2.0:
					var p := tu.pos
					if sp["target"] == "wall":
						p = hero.global_position.lerp(tu.pos, 0.5)
						if _dist_to_point(p) < 6.0:
							continue
					_face(p)
					_send_server("request_cast", [sid, 0, p, _wall_yaw(p)])
					return

## Бот изучает таланты: сначала «своя» ветка, потом остальные.
const BOT_TREE := {"mage": 2, "paladin": 0, "priest": 1}
var _bot_learn_wait := 0.0

func _bot_learn_talents() -> void:
	if hero.talent_points_free() <= 0 or now() < _bot_learn_wait:
		return
	var trees: Array = GameData.talent_trees(hero.class_id)
	var order: Array = [int(Net.cli["bottree"]) if Net.cli.has("bottree") else BOT_TREE.get(hero.class_id, 0)]
	for i in trees.size():
		if not order.has(i):
			order.append(i)
	for ti in order:
		var list: Array = trees[ti]["talents"].duplicate()
		list.sort_custom(func(a, b): return a["row"] * 10 + a["col"] < b["row"] * 10 + b["col"])
		for tl in list:
			if GameData.can_learn(hero.class_id, hero.talents, hero.unit.level, tl["id"]) == "":
				_bot_learn_wait = now() + 0.5
				_send_server("request_learn", [tl["id"]])
				return
## Ключ долгого баффа (благословения, стойкость) — бот поддерживает их на себе.
func _long_buff_key(sp: Dictionary) -> String:
	for e in sp.get("effects", []):
		if e["type"] == "buff" and float(e["dur"]) >= 60.0:
			return e["key"]
	return ""
## Порядок, в котором бот пробует заклинания, — как ротация живого игрока:
## сначала с перезарядкой (большие → контроль → площадь → ротация), затем без перезарядки:
## массовые раньше одиночных. Так бот не спамит первым заклинанием панели.
func _bot_priority() -> Array:
	var list: Array = spell_ids().duplicate()
	if Net.cli.has("botspells"):
		var only: PackedStringArray = Net.cli["botspells"].split(",")
		list = list.filter(func(s): return only.has(s))
	list.sort_custom(func(a, b): return _bot_rank(a) > _bot_rank(b))
	return list

func _bot_rank(sid: String) -> float:
	var sp: Dictionary = GameData.SPELLS[sid]
	var cd := float(sp.get("cd", 0.0))
	if cd > 0.0:
		return 1000.0 + cd
	var aoe: bool = sp["target"] == "ground" or sp["delivery"] == "self_aoe" or sp["delivery"] == "party"
	return 500.0 if aoe else 100.0 + float(sp.get("cast", 0.0))
