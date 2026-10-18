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
## Герой-бот на хосте («Добавить бота в команду»): без камеры и ввода, всё решает bot_tick, просьбы идут
## прямо в серверный код от имени героя (world.acting_hero).
var ai := false

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
	if ai:
		set_process_unhandled_input(false)      # бот на хосте: мышь и клавиатура — не его
		bars = [[], []]
		for b in BAR_COUNT:
			bars[b].resize(BAR_SIZE)
			bars[b].fill("")
		return
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
		if pu and pu.alive and hero.unit.is_enemy_of(pu):
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
		var lid: int = world.economy.pick_loot(camera, pos)
		if lid != 0:
			world.economy.send("request_pickup", [lid])
			return
	var id := pick_unit(pos)
	if id == 0:
		return
	target_id = id
	var u: Unit = world.get_unit(id)
	if not is_left and u and u.kind == "hero" and id != hero.hero_id and not hero.unit.is_enemy_of(u):
		world.hud.hero_menu(id, pos)      # ПКМ по союзнику: «Обмен»
		return
	if not is_left and u and hero.unit.is_enemy_of(u):
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
	if ai:
		_ai_process(delta)
		return
	_build_tick(delta)
	var typing: bool = world.hud.is_typing()
	# клавиша движения, назначенная на ячейку панели или окно (Q, E…), героя не двигает — иначе сбивает произнесение
	var w := Input.is_action_pressed("move_forward") and not typing and not Keys.movement_taken("move_forward")
	var s := Input.is_action_pressed("move_back") and not typing and not Keys.movement_taken("move_back")
	var a := Input.is_action_pressed("turn_left") and not typing and not Keys.movement_taken("turn_left")
	var d := Input.is_action_pressed("turn_right") and not typing and not Keys.movement_taken("turn_right")
	var q := Input.is_action_pressed("strafe_left") and not typing and not Keys.movement_taken("strafe_left")
	var e := Input.is_action_pressed("strafe_right") and not typing and not Keys.movement_taken("strafe_right")
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

	# Движение прерывает произнесение (кроме баффов с cast_move — Благосклонность предков).
	if cast_spell != "" and hero.is_moving() and not _cancel_sent and not _cast_move_buff():
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
		if (u.kind == "castle" and not hero.unit.is_enemy_of(u)) or not u.alive:
			continue        # свою базу не выбрать; вражескую (Арена) — можно, её бьют заклинаниями и автоатакой
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
		if not hero.unit.is_enemy_of(u) or not u.alive:
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
			if arr[i] == null or not (GameData.SPELLS.has(str(arr[i])) or GameData.ItemData.TRINKET_SLOTS.has(str(arr[i]).trim_prefix("use:")) or (str(arr[i]).begins_with("item:") and not GameData.item(str(arr[i]).trim_prefix("item:")).is_empty())):
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
			if bars[b][i] != "" and not str(bars[b][i]).begins_with("item:") and not str(bars[b][i]).begins_with("use:") and not known.has(bars[b][i]):
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
	if sid.begins_with("use:"):
		# используемый аксессуар из ячейки снаряжения
		var use := GameData.ItemData.use_of(str(hero.equip.get(sid.trim_prefix("use:"), "")))
		if not hero.unit.alive:
			return
		if use == "":
			hud.error("Нет аксессуара с используемым эффектом")
			return
		if now() < float(hero.use_ready.get(use, 0.0)):
			hud.error("Ещё не готово")
			return
		world.economy.send("request_use_slot", [sid.trim_prefix("use:")])
		return
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
	if now() < gcd_until and not GameData.SPELLS[sid].get("no_gcd", false):
		return
	if hero.unit.mana < GameData.eff_mana(hero.unit, sid):
		hud.error("Недостаточно маны")
		return
	var max_range := GameData.eff_range(hero.unit, sid)
	match sp["target"]:
		"enemy":
			var t: Unit = world.get_unit(target_id)
			if t == null or not t.alive or not hero.unit.is_enemy_of(t):
				target_next_enemy()
				t = world.get_unit(target_id)
				if t == null or not hero.unit.is_enemy_of(t):
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
		"any":
			# Покаяние, Шок небес: союзник под курсором в рамке группы или выбранный союзник — лечение,
			# враг в цели — урон, иначе — лечение себя
			var hov: Unit = world.get_unit(world.hud.hover_unit_id)
			var cur: Unit = world.get_unit(target_id)
			var t: Unit = hero.unit
			if _is_ally(hov):
				t = hov
			elif cur and cur.alive and (hero.unit.is_enemy_of(cur) or _is_ally(cur)):
				t = cur
			if _dist_to(t) > max_range + t.radius:
				hud.error("Цель слишком далеко")
				return
			if hero.unit.is_enemy_of(t):
				_face(t.pos)
			_send_server("request_cast", [sid, t.id, Vector3.ZERO, 0.0])
		"self":
			_send_server("request_cast", [sid, hero.hero_id, Vector3.ZERO, 0.0])
		"ground", "wall":
			aim_spell = sid

## Кому уйдёт лечение: рамка группы под курсором → выбранная цель → союзник под курсором в мире
## (питомец, другой герой; не сам герой — камера за спиной, курсор почти всегда на нём) → себе.
## Раньше «под курсором в мире» шло первым и перехватывало выбранную цель — лечение молча уходило на себя.
func _ally_target() -> Unit:
	var u: Unit = world.get_unit(world.hud.hover_unit_id)
	if _is_ally(u):
		return u
	u = world.get_unit(target_id)
	if _is_ally(u):
		return u
	var under: Unit = world.get_unit(pick_unit(get_viewport().get_mouse_position()))
	if _is_ally(under) and under != hero.unit:
		return under
	return hero.unit

## Союзник для лечения и щитов: герой или питомец охотника (сервер принимает обоих).
func _is_ally(u: Unit) -> bool:
	return u != null and u.alive and hero.unit.is_ally_of(u) and (u.kind == "hero" or u.kind == "pet")

func _cast_move_buff() -> bool:
	for b in hero.net_buffs:
		if GameData.BUFF_INFO.get(b[0], {}).get("cast_move", false):
			return true
	return false

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
	if cast_spell != "" and not ok and not ai:
		world.hud.error("Прервано")
	cast_spell = ""
	_cancel_sent = false

func on_feedback(sid: String, err: String, cd: float, gcd: float) -> void:
	if err != "":
		if not ai:
			world.hud.error(err)
		return
	if cd > 0.0:
		cd_until[sid] = now() + cd
	elif cd < 0.0:
		cd_until.erase(sid)        # сервер сбросил перезарядку (прок)
	if gcd > 0.0:
		gcd_until = now() + gcd

func _send_server(method: String, args: Array) -> void:
	if ai:
		world.acting_hero = hero
		world.spells.callv(method, args)
		world.acting_hero = null
		return
	world.spells.send_to_server(method, args)

## Просьба к экономике (у бота на хосте — сразу в серверный код от имени героя).
func _eco(method: String, args: Array) -> void:
	if ai:
		world.acting_hero = hero
		world.economy.callv(method, args)
		world.acting_hero = null
		return
	world.economy.send(method, args)

# ---------------------------------------------------------------- бот для автотестов (--bot)

var _bot_t := 0.0
var _bot_ally := 0

func bot_active() -> bool:
	return ai or Net.cli.has("bot")

func bot_tick(delta: float) -> void:
	var post: Vector3 = world.mode.bot_post_for(hero) if world.mode.has_method("bot_post_for") else world.mode.bot_post()
	var lines_post: Variant = _bot_lines(delta)
	if lines_post == null:
		lines_post = _bot_arena(delta)
	if lines_post != null:
		post = lines_post
	elif Net.cli.has("post") and not ai:
		var f: PackedFloat64Array = Net.cli["post"].split_floats(",")
		post = Vector3(f[0], 0, f[1])
	var to := post - hero.global_position
	var stop := 2.5
	# бойцы ближнего боя подходят к цели (недалеко от поста)
	var melee_range := float(GameData.CLASSES[hero.class_id]["auto"]["range"])
	# у гибридов (шаман) к цели подходят только ветки ближнего боя (melee_trees)
	var cls: Dictionary = GameData.CLASSES[hero.class_id]
	var melee_ok: bool = not cls.has("melee_trees") or cls["melee_trees"].has(_bot_main_tree())
	var mt: Unit = world.get_unit(target_id)
	if melee_range <= 5.0 and melee_ok and mt and mt.alive and Vector2(mt.pos.x - post.x, mt.pos.z - post.z).length() < 22.0:
		to = mt.pos - hero.global_position
		stop = melee_range - 0.8 + mt.radius
	to.y = 0
	if to.length() > stop and cast_spell == "":
		hero.rotation.y = atan2(-to.x, -to.z)
		cam_yaw = hero.rotation.y
		move_forward = 1.0
	else:
		move_forward = 0.0
	# простое правило: стоишь в телеграфе или у мины — выйди; гребень волны рядом — прыгай
	var hp2 := Vector2(hero.global_position.x, hero.global_position.z)
	var esc: Vector2 = world.mobs.escape_dir(hp2, 1.2)
	if esc != Vector2.ZERO and hero.unit.alive:
		hero.rotation.y = atan2(-esc.x, -esc.y)
		cam_yaw = hero.rotation.y
		move_forward = 1.0
	if world.mobs.wave_near(hp2):
		_jump_queued = true
	# бой героев: мало здоровья — выпить зелье, а без зелья и лечения — отойти от врага-героя
	var foe_h = _bot_enemy_hero(30.0)
	if foe_h and hero.unit.alive and hero.unit.hp_frac() < 0.35:
		if not _bot_potion() and hero.unit.hp_frac() < 0.25 and not _bot_can_heal():
			var away: Vector3 = hero.global_position - foe_h.unit.pos
			away.y = 0.0
			if away.length() > 0.1 and away.length() < 14.0:
				hero.rotation.y = atan2(-away.x, -away.z)
				cam_yaw = hero.rotation.y
				move_forward = 1.0
	if lines_post != null and (_shop_phase > 0 or _arena_phase > 0):
		return      # «Линии»: идёт за покупками — не колдует, иначе лекарь не дойдёт до базы
	_bot_t -= delta
	if _bot_t <= 0.0 and hero.unit.alive and _bot_try_interrupt():
		_bot_t = 0.25
		return
	if _bot_t > 0.0 or cast_spell != "" or not hero.unit.alive:
		return
	_bot_t = 0.25
	_bot_learn_talents()
	if now() < gcd_until:
		return
	# цель
	var tu: Unit = world.get_unit(target_id)
	# объекты боссов (гробница, филактерии, порталы) — первая цель
	var first: Unit = null
	for u: Unit in world.units.values():
		if u.alive and hero.unit.is_enemy_of(u) and GameData.MOBS.get(u.type_id, {}).get("kill_first", false) and _dist_to(u) < 32.0 				and (first == null or _dist_to(u) < _dist_to(first)):
			first = u
	if first and (tu == null or not GameData.MOBS.get(tu.type_id, {}).get("kill_first", false)):
		target_id = first.id
		tu = first
	# бой героев: вражеский герой в 25 м — главная цель (мобы подождут)
	var eh = _bot_enemy_hero(25.0)
	if eh and first == null and (tu == null or tu.kind != "hero" or not tu.alive):
		target_id = eh.hero_id
		tu = eh.unit
	if tu == null or not tu.alive or not hero.unit.is_enemy_of(tu) or _dist_to(tu) > 32.0 or not _target_ok(tu):
		target_id = 0
		var best := 1e9
		for u: Unit in world.units.values():
			if hero.unit.is_enemy_of(u) and u.alive and _dist_to(u) < minf(best, 32.0) and _target_ok(u):
				best = _dist_to(u)
				target_id = u.id
		tu = world.get_unit(target_id)
	# самый раненый союзник
	var weakest: Unit = null
	for h in world.heroes.values():
		if h.unit.alive and hero.unit.is_ally_of(h.unit) and (weakest == null or h.unit.hp_frac() < weakest.hp_frac()):
			weakest = h.unit
	var near_enemies := 0
	for u: Unit in world.units.values():
		if hero.unit.is_enemy_of(u) and u.alive and _dist_to(u) < 8.0:
			near_enemies += 2 if u.kind == "hero" else 1      # вражеский герой опаснее моба — защитные заклинания раньше
	# используемые аксессуары — в бою, как только готовы (лечащие — когда ранен)
	if tu and tu.alive and _dist_to(tu) < 30.0:
		for ts in GameData.ItemData.TRINKET_SLOTS:
			var use := GameData.ItemData.use_of(str(hero.equip.get(ts, "")))
			if use == "" or now() < float(hero.use_ready.get(use, 0.0)):
				continue
			if GameData.ItemData.ITEM_PROCS[use].has("heal_pct") and hero.unit.hp_frac() > 0.5:
				continue
			hero.use_ready[use] = now() + 1.0       # не слать повторно, пока сервер не ответит
			_eco("request_use_slot", [ts])
	# питомцы охотников тоже союзники: лекарь подлечивает раненого зверя
	for pu: Unit in world.mobs.pet_units():
		if pu.alive and hero.unit.is_ally_of(pu) and _dist_to(pu) < 30.0 and pu.hp_frac() < 0.6 and (weakest == null or pu.hp_frac() < weakest.hp_frac()):
			weakest = pu
	if hero.class_id == "hunter" and not ai and _bot_hunter_pet():
		return
	for sid in _bot_priority():
		var sp: Dictionary = GameData.SPELLS[sid]
		if hero.unit.level < GameData.spell_level(sid):
			continue
		if sp.get("delivery", "") in ["pet_call", "pet_revive"] or (sp.has("pet_fx") and sp.get("effects", []).is_empty()):
			continue      # питомцем бот занимается отдельно (_bot_hunter_pet)
		if now() < float(cd_until.get(sid, 0.0)) or hero.unit.mana < GameData.eff_mana(hero.unit, sid):
			continue
		if sp.get("delivery", "") == "totem":
			if _bot_totem_ok(sp, tu, weakest):
				_send_server("request_cast", [sid, hero.hero_id, Vector3.ZERO, 0.0])
				_bot_totem_until[sp["totem"]["element"]] = now() + float(sp["totem"]["life"]) * 0.9
				return
			continue
		if sp.get("delivery", "") == "trap":
			# ловушку — под ноги навстречу врагу, когда он в 20 м
			if tu and _dist_to(tu) < 20.0:
				var tp: Vector3 = tu.pos if _dist_to(tu) <= GameData.eff_range(hero.unit, sid) else hero.global_position + (tu.pos - hero.global_position).normalized() * 4.0
				_send_server("request_cast", [sid, 0, tp, 0.0])
				return
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
					var dot := _dot_of(sp)
					if not dot.is_empty():
						var dk := "%d:%s" % [tu.id, dot["key"]]
						if now() < float(_dot_until.get(dk, 0.0)):
							continue      # уже висит — не обновлять раньше времени
						_dot_until[dk] = now() + float(dot["dur"]) * 0.85
					_face(tu.pos)
					_send_server("request_cast", [sid, tu.id, Vector3.ZERO, 0.0])
					return
			"any":
				# лечение раненому союзнику важнее, иначе — урон по цели
				if weakest and weakest.hp_frac() < 0.7 and _dist_to(weakest) <= float(sp["range"]):
					_send_server("request_cast", [sid, weakest.id, Vector3.ZERO, 0.0])
					return
				if tu and _dist_to(tu) <= float(sp["range"]) + tu.radius:
					_face(tu.pos)
					_send_server("request_cast", [sid, tu.id, Vector3.ZERO, 0.0])
					return
			"ground", "wall":
				if sp.has("ally_fx") and not sp.has("enemy_fx"):
					# зона лечения (Целительный ливень) — под раненого союзника
					if weakest and weakest.hp_frac() < 0.85 and _dist_to(weakest) <= float(sp["range"]) - 2.0:
						_send_server("request_cast", [sid, 0, weakest.pos, 0.0])
						return
					continue
				if tu and _dist_to(tu) <= float(sp["range"]) - 2.0:
					var p := tu.pos
					if sp["target"] == "wall":
						p = hero.global_position.lerp(tu.pos, 0.5)
						if _dist_to_point(p) < 6.0:
							continue
					_face(p)
					_send_server("request_cast", [sid, 0, p, _wall_yaw(p)])
					return

## Периодический урон заклинания (первый dot в эффектах) или {}.
var _dot_until: Dictionary = {}      # "id цели:ключ" -> до какого времени не обновлять

func _dot_of(sp: Dictionary) -> Dictionary:
	for e in sp.get("effects", []):
		if e["type"] == "dot":
			return e
	return {}

## Бот-охотник: призвать или воскресить питомца, подлечить его, режим — агрессивный, вид — по ветке
## (Стрельба — волк, Повелитель зверей — медведь, Выживание — кошка; --botpet=wolf|bear|cat). true — действие отправлено.
var _bot_pet_setup := false

func _bot_hunter_pet() -> bool:
	var st: Dictionary = world.mobs.my_pet
	if not _bot_pet_setup:
		_bot_pet_setup = true
		var tree: int = int(Net.cli["bottree"]) if Net.cli.has("bottree") else 0
		var kind: String = "pet_" + str(Net.cli.get("botpet", ["wolf", "bear", "cat"][clampi(tree, 0, 2)]))
		world.mobs.send_pet("kind:" + kind)
		world.mobs.send_pet("aggressive")
		return true
	var pu: Unit = world.mobs.pet_of(hero.hero_id)
	var want := ""
	if pu == null:
		want = "revive_pet" if st.get("dead", false) else "call_pet"
	elif pu.hp_frac() < 0.5:
		want = "mend_pet"
	if want == "" or hero.unit.level < GameData.spell_level(want) or now() < float(cd_until.get(want, 0.0)) \
			or hero.unit.mana < GameData.eff_mana(hero.unit, want):
		return false
	_send_server("request_cast", [want, hero.hero_id, Vector3.ZERO, 0.0])
	if want == "call_pet" or want == "revive_pet":
		cd_until[want] = now() + 3.0       # не слать повторно, пока идёт призыв
	return true

## Бот-шаман: тотем ставится, если тотема этой стихии нет (бот помнит, сколько стоит свой) и он нужен:
## бьющий — враг в его радиусе, лечащий — союзник ранен, остальные — враг в 30 м.
var _bot_totem_until: Dictionary = {}

func _bot_totem_ok(sp: Dictionary, tu: Unit, weakest: Unit) -> bool:
	if now() < float(_bot_totem_until.get(sp["totem"]["element"], 0.0)) or tu == null:
		return false
	if sp.has("enemy_fx"):
		return _dist_to(tu) <= float(sp["radius"])
	var heals: bool = sp["ally_fx"].any(func(e): return e["type"] == "heal")
	if heals:
		return weakest != null and weakest.hp_frac() < 0.9 and _dist_to(tu) < 30.0
	return _dist_to(tu) < 30.0

## Бот изучает таланты: сначала «своя» ветка, потом остальные.
const BOT_TREE := {"mage": 2, "paladin": 0, "priest": 1}
var _bot_learn_wait := 0.0

func _bot_main_tree() -> int:
	return int(Net.cli["bottree"]) if Net.cli.has("bottree") and not ai else BOT_TREE.get(hero.class_id, 0)

func _bot_learn_talents() -> void:
	if not _build().is_empty():      # бот с заготовкой (--buildspec) учит её, а не свою ветку
		_build_tick(0.25)
		return
	if now() < _bot_learn_wait:
		return
	var main: int = _bot_main_tree()
	_bot_choose_book(main)
	if hero.talent_points_free() <= 0:
		return
	var trees: Array = GameData.talent_trees(hero.class_id)
	var order: Array = [main]
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
## Бот выбирает в книге вариант своей ветки: столбец ряда = ветка талантов (у мага тайная/огонь/лёд).
## С --choices выбор задаёт тест, бот его не трогает.
func _bot_choose_book(tree: int) -> void:
	if Net.cli.has("choices") or not GameData.BOOKS.has(hero.class_id):
		return
	var rows: Array = GameData.BOOKS[hero.class_id]["rows"]
	for i in rows.size():
		var opts: Array = rows[i]["options"]
		var want: String = opts[clampi(tree, 0, opts.size() - 1)]
		if hero.unit.level >= int(rows[i]["level"]) and GameData.book_choice(hero.class_id, i, hero.choices) != want:
			_bot_learn_wait = now() + 3.0   # в бою сервер откажет — повторим позже
			_send_server("request_choose", [i, want])
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
	# прерывания бот бережёт для вражеских кастов (_bot_try_interrupt), в ротации их нет
	list = list.filter(func(s): return not GameData.SPELLS[s].get("effects", []).any(func(e): return e["type"] == "interrupt"))
	list.sort_custom(func(a, b): return _bot_rank(a) > _bot_rank(b))
	return list

func _bot_rank(sid: String) -> float:
	var sp: Dictionary = GameData.SPELLS[sid]
	var cd := float(sp.get("cd", 0.0))
	if cd <= 0.0 and _dot_of(sp) != {}:
		return 1050.0      # свои периодические эффекты (Слово Тьмы: Боль) — держать на цели
	if cd > 0.0:
		return 1000.0 + cd
	if sp["delivery"] == "totem":
		return 600.0       # тотемы без перезарядки — раньше заполнителя (их сдерживает таймер стихии в _bot_totem_ok)
	var aoe: bool = sp["target"] == "ground" or sp["delivery"] == "self_aoe" or sp["delivery"] == "party"
	return 500.0 if aoe else 100.0 + float(sp.get("cast", 0.0))

## Бот сбивает опасный каст рядом, если прерывание готово; ради этого бросает свой каст.
func _bot_try_interrupt() -> bool:
	for isid in spell_ids():
		var isp: Dictionary = GameData.SPELLS[isid]
		if not isp.get("effects", []).any(func(e): return e["type"] == "interrupt"):
			continue
		if hero.unit.level < GameData.spell_level(isid) or now() < float(cd_until.get(isid, 0.0)) or hero.unit.mana < GameData.eff_mana(hero.unit, isid):
			return false
		for cid in world.mobs.casts:
			var cu: Unit = world.get_unit(cid)
			if cu and cu.alive and cu.kind != "hero" and hero.unit.is_enemy_of(cu) and world.mobs.casts[cid]["interrupt"] and _dist_to(cu) <= float(isp["range"]) + cu.radius:
				if cast_spell != "":
					_send_server("request_cancel", [])
					return true
				_face(cu.pos)
				_send_server("request_cast", [isid, cid, Vector3.ZERO, 0.0])
				return true
		# бой героев: сбить произнесение вражеского героя
		for eh in world.enemy_heroes(hero.unit):
			if eh.casting and eh.unit.alive and _dist_to(eh.unit) <= float(isp["range"]) + eh.unit.radius:
				_face(eh.unit.pos)
				_send_server("request_cast", [isid, eh.hero_id, Vector3.ZERO, 0.0])
				return true
		return false
	return false

## Ближайший живой вражеский герой не дальше r (только в режимах с боем героев).
func _bot_enemy_hero(r: float):
	var best = null
	var bd := r
	for eh in world.enemy_heroes(hero.unit):
		if eh.unit.alive and not eh.offline and _dist_to(eh.unit) < bd:
			bd = _dist_to(eh.unit)
			best = eh
	return best

## Выпить зелье лечения из сумки (лучшее, что есть), если зелья готовы. true — выпил.
func _bot_potion() -> bool:
	if now() < potion_until:
		return false
	for pid in ["potion_heal_4", "potion_heal_3", "potion_heal_2", "potion_heal_1"]:
		if hero.bag_count(pid) > 0:
			potion_until = now() + 2.0      # до ответа сервера не слать повторно
			_eco("request_use_id", [pid])
			return true
	return false

## Есть ли у героя заклинание лечения союзника (лекарь сам себя вылечит, а не убегает).
func _bot_can_heal() -> bool:
	for sid in spell_ids():
		var sp: Dictionary = GameData.SPELLS[sid]
		if sp["target"] == "ally" and sp.get("effects", []).any(func(e): return e["type"] == "heal") and now() >= float(cd_until.get(sid, 0.0)):
			return true
	return false

## Книга заклинаний: выбранное заклинание встаёт в ячейку снятого.
func replace_spell(old: String, new_sid: String) -> void:
	var at := _find(old)
	if at.x >= 0 and _find(new_sid).x < 0:
		bars[at.x][at.y] = new_sid
	if not _seen.has(new_sid):
		_seen.append(new_sid)
	save_bar()

# ---------------------------------------------------------------- герой-бот на хосте и бот «Войны линий»

## Бот на хосте: без камеры и ввода — только решения бота; движение прерывает произнесение, как у игрока.
func _ai_process(delta: float) -> void:
	move_strafe = 0.0
	turn_input = 0.0
	steering = false
	bot_tick(delta)
	if cast_spell != "" and hero.is_moving() and not _cancel_sent and not _cast_move_buff():
		_cancel_sent = true
		_send_server("request_cancel", [])
	var tu: Unit = world.get_unit(target_id)
	if tu and not tu.alive and tu.kind == "mob":
		target_id = 0

## «Линии»: бот бьёт только врагов своей линии (соседние коридоры — за лесополосой).
func _target_ok(u: Unit) -> bool:
	var lm := world.mode as LinesMode
	if lm == null:
		return true
	return lm.on_my_lane(hero, u.pos)

## «Линии»: раз в BOT_SHOP_EVERY сек. (или когда золота много) бот идёт на базу: у Вербовщика тратит
## долю золота BOT_SEND_SHARE на отправки, у кузнеца — остальное на вещи получше, затем надевает их.
## Возвращает точку, куда идти (или null — держать линию).
var _shop_phase := 0
var _shop_t := 20.0
var _shop_wait := 0.0
var _equip_t := 0.0
var _equip_tried: Dictionary = {}
var _send_local: Dictionary = {}     # отправка -> до какого времени не пробовать (снимок перезарядок приходит позже)

func _bot_lines(delta: float) -> Variant:
	var lm := world.mode as LinesMode
	if lm == null or lm.is_over() or not hero.unit.alive:
		return null
	_shop_t -= delta
	_equip_t -= delta
	if _equip_t <= 0.0:
		_equip_t = 1.5
		_bot_equip_upgrades()
	var L := GameData.LinesData
	var rec: Vector3 = world.economy.vendor_pos.get("recruiter#%d" % hero.team, Vector3.ZERO)
	var smith: Vector3 = world.economy.vendor_pos.get("smith#%d" % hero.team, Vector3.ZERO)
	match _shop_phase:
		0:
			if (_shop_t <= 0.0 and hero.gold >= 60) or hero.gold >= 600:
				_shop_phase = 1
			else:
				return null
		1:
			if _dist_to_point(rec) > 5.0:
				return _detour(rec)
			_bot_buy_sends(int(hero.gold * L.BOT_SEND_SHARE))
			_shop_phase = 2
			return rec
		2:
			if _dist_to_point(smith) > 5.0:
				return _detour(smith)
			_bot_buy_gear(hero.gold)
			_shop_phase = 3
			_shop_wait = 1.5
			return smith
		3:
			_shop_wait -= delta
			if _shop_wait > 0.0:
				return smith
			_bot_equip_upgrades()
			_shop_phase = 0
			_shop_t = L.BOT_SHOP_EVERY
			return null
	return null

func _bot_buy_sends(budget: int) -> void:
	var lm := world.mode as LinesMode
	var SD := GameData.SendData
	for k in 4:
		var opts: Array = []
		for sid in SD.SENDS:
			var s: Dictionary = SD.SENDS[sid]
			if lm.minute() >= float(s["minute"]) and lm.cd_left_view(hero, sid) <= 0.0 and now() >= float(_send_local.get(sid, 0.0)) \
					and int(s["price"]) <= budget:
				opts.append(sid)
		if opts.is_empty():
			return
		opts.sort_custom(func(a, b): return [int(SD.SENDS[a]["tier"]), int(SD.SENDS[a]["price"])] > [int(SD.SENDS[b]["tier"]), int(SD.SENDS[b]["price"])])
		var sid: String = opts[randi() % mini(3, opts.size())]
		budget -= int(SD.SENDS[sid]["price"])
		_send_local[sid] = now() + float(SD.SENDS[sid]["cd"]) + 1.0
		if ai:
			world.acting_hero = hero
			lm.request_send(sid, -1, "")
			world.acting_hero = null
		else:
			lm.send(sid, -1, "")

## Арена: раз в BOT_SHOP_EVERY сек. (или когда золота много, или после смерти) бот идёт на базу —
## у Книжника тратит долю BOT_TOME_SHARE на томики, у кузнеца — на вещи, у Мастера сборки собирает что может,
## у алхимика берёт зелья лечения; в дуэли и во время похода не отвлекается. null — фармить (пост режима).
var _arena_phase := 0
var _arena_t := 45.0
const ARENA_ROUTE := ["bookseller", "smith", "crafter", "alchemist"]

func _bot_arena(delta: float) -> Variant:
	var am := world.mode as ArenaMode
	if am == null or am.is_over() or not hero.unit.alive or hero.unit.duel != 0:
		return null
	var A := preload("res://scripts/data/arena_data.gd")
	_arena_t -= delta
	_equip_t -= delta
	if _equip_t <= 0.0:
		_equip_t = 1.5
		_bot_equip_upgrades()
	if _arena_phase == 0:
		if (_arena_t <= 0.0 and hero.gold >= A.tome_price(am.tome_count(hero))) or hero.gold >= 1500:
			_arena_phase = 1
		else:
			return null
	var kind: String = ARENA_ROUTE[_arena_phase - 1]
	var vid := "%s#%d" % [kind, hero.team]
	var vp: Vector3 = world.economy.vendor_pos.get(vid, hero.global_position)
	if _dist_to_point(vp) > 5.0:
		return vp
	match kind:
		"bookseller":
			var budget := int(hero.gold * A.BOT_TOME_SHARE)
			var n := 0
			while n < 6:
				var price := A.tome_price(am.tome_count(hero) + n)
				if price > budget:
					break
				budget -= price
				_eco("request_buy", [vid, _bot_tome_pick(am.tome_count(hero) + n)])
				n += 1
		"smith":
			_bot_buy_gear(hero.gold)
		"crafter":
			_bot_craft(vid)
		"alchemist":
			var pot := "potion_heal_1"
			for pid in ["potion_heal_2", "potion_heal_3", "potion_heal_4"]:
				if hero.unit.level >= int(GameData.ItemData.CONSUMABLES[pid]["level"]):
					pot = pid
			for k in maxi(0, 3 - hero.bag_count(pot)):
				if hero.gold >= GameData.shop_price(pot) + 50:
					_eco("request_buy", [vid, pot])
	_arena_phase += 1
	if _arena_phase > ARENA_ROUTE.size():
		_arena_phase = 0
		_arena_t = A.BOT_SHOP_EVERY
		_bot_equip_upgrades()
	return vp

## Какой томик брать: главная характеристика роли, каждый третий — выносливость.
func _bot_tome_pick(n: int) -> String:
	if n % 3 == 2:
		return "tome_sta"
	var caster: bool = hero.class_id in ["mage", "priest"] or (hero.class_id in ["shaman", "paladin"] and _bot_main_tree() != 1)
	if caster:
		return "tome_int"
	return "tome_agi" if hero.class_id == "hunter" else "tome_str"

## Собрать всё, на что хватает компонентов и золота (рецепты по порядку, по одной сборке за поход на рецепт).
func _bot_craft(vid: String) -> void:
	var R := GameData.Recipes
	var gold: int = hero.gold
	var used := {}
	for rid in R.ORDER:
		var bag: Array = []
		for i in hero.bag.size():
			if hero.bag[i] != null and not used.has(i):
				bag.append([i, GameData.item(hero.bag[i]["id"])])
		var fill: Array = R.auto_fill(rid, bag)
		if fill.has(-1):
			continue
		var items: Array = fill.map(func(i): return GameData.item(hero.bag[int(i)]["id"]))
		if R.check(rid, items, hero.bag_count(R.SCROLL)) != "":
			continue
		var price: int = world.economy.craft_price(rid, items)
		if price > gold * 0.5:
			continue
		# сливать имеет смысл только то, что не хуже надетого
		if rid == "merge" or rid == "scroll":
			if _item_value(hero.bag[int(fill[0])]["id"]) < _slot_value(items[0]["slot"]) * 0.8:
				continue
		gold -= price
		for i in fill:
			used[int(i)] = true
		_eco("request_craft", [rid, fill])
	if Net.cli.has("craftlog"):
		print("BOTCRAFT %s у %s: золото %d" % [hero.player_name, vid, hero.gold])

## Ценность вещи для героя: характеристики с весами по роли (заклинатель — интеллект и сила заклинаний,
## боец — сила, ловкость и сила атаки), выносливость и броня — всем.
func _item_value(id) -> float:
	if id == null or str(id) == "":
		return 0.0
	var it := GameData.item(str(id))
	if it.is_empty() or it.get("kind", "") != "gear":
		return 0.0
	var caster: bool = hero.class_id in ["mage", "priest"] or (hero.class_id in ["shaman", "paladin"] and _bot_main_tree() == 0) \
		or (hero.class_id == "shaman" and _bot_main_tree() == 2)
	var w := {"sta": 1.0, "armor": 120.0, "crit": 120.0, "block": 40.0}
	if caster:
		w.merge({"int": 1.3, "sp": 1.3, "spi": 0.6})
	else:
		w.merge({"str": 1.3, "agi": 1.1, "ap": 1.1})
	var v := 0.0
	for k in it.get("stats", {}):
		v += float(it["stats"][k]) * float(w.get(k, 0.15))
	return v

func _slot_value(slot: String) -> float:
	if slot == "trinket":
		return minf(_item_value(hero.equip.get("trinket1", "")), _item_value(hero.equip.get("trinket2", "")))
	return _item_value(hero.equip.get(slot, ""))

func _can_wear(it: Dictionary) -> bool:
	return it.get("kind", "") == "gear" and hero.unit.level >= int(it.get("level", 1)) \
		and (it.get("classes", []).is_empty() or it["classes"].has(hero.class_id))

func _bot_buy_gear(budget: int) -> void:
	var vid := "smith#%d" % hero.team
	if not world.economy.vendor_pos.has(vid):
		return
	var cands: Array = []
	for id in world.economy.vendor_items(vid, hero.unit.level):
		var it := GameData.item(id)
		if not _can_wear(it):
			continue
		var gain := _item_value(id) - _slot_value(it["slot"])
		if gain > 0.5:
			cands.append([gain / maxf(1.0, float(GameData.shop_price(id))), id, it["slot"]])
	cands.sort_custom(func(a, b): return a[0] > b[0])
	var bought := {}
	for c in cands:
		var price := GameData.shop_price(c[1])
		if price > budget or bought.has(c[2]):
			continue
		budget -= price
		bought[c[2]] = true
		_eco("request_buy", [vid, c[1]])

## Надеть из сумки вещь получше надетой (по одной за раз — индексы сумки не сдвигаются).
func _bot_equip_upgrades() -> void:
	for i in hero.bag.size():
		var s = hero.bag[i]
		if s == null or _equip_tried.has(s["id"]):
			continue
		var it := GameData.item(s["id"])
		if not _can_wear(it):
			continue
		if _item_value(s["id"]) > _slot_value(it["slot"]) * 1.05 + 0.5:
			_equip_tried[s["id"]] = true
			_eco("request_use", [i])
			return

## Лавки — за замком: если прямой путь идёт сквозь замок, сначала обойти его сбоку.
func _detour(target: Vector3) -> Vector3:
	var lm := world.mode as LinesMode
	if lm == null:
		return target
	var base: Unit = lm.bases[clampi(hero.team, 0, 1)]
	var c := Vector2(base.pos.x, base.pos.z)
	var a := Vector2(hero.global_position.x, hero.global_position.z)
	var b := Vector2(target.x, target.z)
	if Geometry2D.get_closest_point_to_segment(c, a, b).distance_to(c) > 9.0 or a.distance_to(c) < 10.0:
		return target
	var dir := (b - a).normalized()
	var side := Vector2(-dir.y, dir.x)
	if side.dot(a - c) < 0.0:
		side = -side
	var p := c + side * 13.0
	return Vector3(p.x, 0, p.y)

# ---------------------------------------------------------------- заготовка талантов
## Заготовка из «Талантов класса» (Settings.builds): таланты учатся сами в порядке плана, как только есть
## свободные очки; выбор в книге ставится, когда открывается ряд (вне боя — сервер в бою откажет, повторим).
## Ряд, который игрок потом сменил сам, заготовка больше не трогает. Тест: --buildspec="tid,tid,…|ряд:id,…".
var _build_cache = null
var _build_wait := 0.0
var _build_rows_done: Dictionary = {}

func _build() -> Dictionary:
	if _build_cache == null:
		_build_cache = {}
		var cid: String = hero.class_id
		if Net.cli.has("buildspec"):
			var parts: PackedStringArray = str(Net.cli["buildspec"]).split("|")
			var ch := {}
			if parts.size() > 1:
				for kv in parts[1].split(",", false):
					ch[int(kv.get_slice(":", 0))] = kv.get_slice(":", 1)
			_build_cache = {"order": Array(parts[0].split(",", false)), "choices": ch}
		elif Settings.selected_build(cid) != "":
			_build_cache = Settings.builds(cid).get(Settings.selected_build(cid), {})
	return _build_cache

func _build_tick(delta: float) -> void:
	var b := _build()
	if b.is_empty() or not hero.unit.alive:
		return
	_build_wait -= delta
	if _build_wait > 0.0:
		return
	_build_wait = 0.4
	# книга: ряд открылся — поставить вариант заготовки (один раз на ряд)
	if GameData.BOOKS.has(hero.class_id):
		var rows: Array = GameData.BOOKS[hero.class_id]["rows"]
		for k in b.get("choices", {}):
			var row := int(k)
			if row < 0 or row >= rows.size() or _build_rows_done.has(row) or hero.unit.level < int(rows[row]["level"]):
				continue
			var want := str(b["choices"][k])
			if GameData.book_choice(hero.class_id, row, hero.choices) == want:
				_build_rows_done[row] = true
				continue
			_build_wait = 3.0           # в бою сервер откажет — попробуем позже
			_send_server("request_choose", [row, want])
			return
	# таланты: первый ранг плана, которого ещё нет
	if hero.talent_points_free() <= 0:
		return
	var seen := {}
	for tid in b.get("order", []):
		seen[tid] = int(seen.get(tid, 0)) + 1
		if int(hero.talents.get(tid, 0)) >= int(seen[tid]):
			continue
		if GameData.can_learn(hero.class_id, hero.talents, hero.unit.level, tid) == "":
			_send_server("request_learn", [tid])
		return       # порядок плана: следующий талант — только после этого
