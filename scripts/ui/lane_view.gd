extends PanelContainer
## Обзор линий («Война линий»): мини-карта с видом сверху — вторая камера (ортографическая) над картой.
## ЛКМ — перетащить камеру, колесо — приблизить / отдалить (до всей карты), ◀ ▶ — линии своей команды и соперника
## (камера следит за самым продвинувшимся врагом линии), «–» — свернуть. Поверх — отметки героев, баз и врагов.
## Картинка обновляется через кадр и в малом разрешении, чтобы не тратить видеокарту.

const VIEW := Vector2i(360, 250)
const VIEW_BIG := Vector2i(600, 420)
const ZOOM_MIN := 10.0
const ZOOM_MAX := 300.0
const GOLD := Color(0.95, 0.78, 0.35)

var world: Node3D
var _vp: SubViewport
var _cam: Camera3D
var _box: SubViewportContainer
var _marks: Control
var _title: Label
var _collapse: Button
var _route := -1                 # за какой линией следит камера (-1 — свободная камера)
var _center := Vector2.ZERO      # куда смотрит камера (XZ)
var _zoom := 90.0
var _drag := false
var _frame := 0
var _big := false
var _move := false             # окно перетаскивают за заголовок

func setup(w: Node3D) -> void:
	world = w
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.05, 0.05, 0.07, 0.9)
	st.border_color = Color(0.55, 0.45, 0.25)
	st.set_border_width_all(2)
	st.set_corner_radius_all(6)
	st.set_content_margin_all(5)
	add_theme_stylebox_override("panel", st)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 3)
	v.add_child(head)
	var prev := _btn("◀", "Предыдущая линия")
	prev.pressed.connect(func(): _cycle(-1))
	head.add_child(prev)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 13)
	_title.add_theme_color_override("font_color", GOLD)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.mouse_filter = Control.MOUSE_FILTER_STOP
	_title.mouse_default_cursor_shape = Control.CURSOR_MOVE
	_title.tooltip_text = "Перетащите за заголовок, чтобы передвинуть окно"
	_title.gui_input.connect(_on_title_input)
	head.add_child(_title)
	var nxt := _btn("▶", "Следующая линия")
	nxt.pressed.connect(func(): _cycle(1))
	head.add_child(nxt)
	var mine := _btn("Моя", "Камера — на мою линию")
	mine.pressed.connect(func(): _follow(_my_route()))
	head.add_child(mine)
	var foe := _btn("Соперник", "Камера — на линию соперника напротив")
	foe.pressed.connect(func(): _follow(_foe_route()))
	head.add_child(foe)
	var all := _btn("Карта", "Вся карта")
	all.pressed.connect(func():
		_route = -1
		_center = Vector2.ZERO
		_zoom = ZOOM_MAX * 0.95)
	head.add_child(all)
	var size_b := _btn("⤢", "Крупнее / мельче")
	size_b.pressed.connect(func(): set_big(not _big))
	head.add_child(size_b)
	_collapse = _btn("–", "Свернуть / развернуть обзор")
	_collapse.pressed.connect(func(): set_collapsed(_box.visible))
	head.add_child(_collapse)
	_box = SubViewportContainer.new()
	_box.stretch = true
	_box.custom_minimum_size = Vector2(VIEW)
	_box.mouse_filter = Control.MOUSE_FILTER_STOP
	_box.gui_input.connect(_on_input)
	_box.tooltip_text = "Перетащите мышью, колесо — масштаб"
	v.add_child(_box)
	_vp = SubViewport.new()      # размер задаёт контейнер (stretch)
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_vp.positional_shadow_atlas_size = 0
	_vp.msaa_3d = Viewport.MSAA_DISABLED
	_box.add_child(_vp)
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.near = 1.0
	_cam.far = 400.0
	_cam.rotation_degrees = Vector3(-90, 0, 0)
	_vp.add_child(_cam)
	_cam.current = true
	_marks = Control.new()
	_marks.set_anchors_preset(Control.PRESET_FULL_RECT)
	_marks.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marks.draw.connect(_draw_marks)
	_box.add_child(_marks)
	_follow.call_deferred(_foe_route())

func _btn(text: String, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.add_theme_font_size_override("font_size", 12)
	b.focus_mode = Control.FOCUS_NONE
	return b

## Крупное окно: картинка 600×420 (та же камера, масштаб в метрах не меняется).
func set_big(on: bool) -> void:
	_big = on
	_box.custom_minimum_size = Vector2(VIEW_BIG if on else VIEW)
	reset_size()

## Перетаскивание окна за заголовок; положение запоминается вместе с раскладкой интерфейса.
func _on_title_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_move = (ev as InputEventMouseButton).pressed
		if not _move and world.hud:
			world.hud._layout_pos["lanes"] = position
			world.hud._save_layout()
		accept_event()
	elif ev is InputEventMouseMotion and _move:
		var vp := get_viewport().get_visible_rect().size
		position = (position + (ev as InputEventMouseMotion).relative).clamp(Vector2.ZERO, vp - size)
		accept_event()

func set_collapsed(on: bool) -> void:
	_box.visible = not on
	_collapse.text = "+" if on else "–"
	reset_size()

func _lm() -> LinesMode:
	return world.mode as LinesMode

func _my_route() -> int:
	var lm := _lm()
	var lh = world.local_hero
	if lm == null or lh == null:
		return 0
	return lh.team * 3 + mini(int(lm.slot.get(lh.hero_id, 0)), lm.lane_count - 1)

func _foe_route() -> int:
	var r := _my_route()
	return (1 - r / 3) * 3 + r % 3

func _follow(route: int) -> void:
	_route = route
	_zoom = clampf(_zoom, 55.0, 120.0)

## ◀ ▶: по всем активным линиям — сначала свои, потом соперника.
func _cycle(dir: int) -> void:
	var lm := _lm()
	if lm == null:
		return
	var routes: Array = []
	var my_team: int = world.local_hero.team if world.local_hero else 0
	for t in [my_team, 1 - my_team]:
		for li in lm.lane_count:
			routes.append(t * 3 + li)
	var i := routes.find(_route)
	_follow(routes[posmod(i + dir, routes.size())] if i >= 0 else routes[0])

func _route_name(route: int) -> String:
	var lm := _lm()
	var L := GameData.LinesData
	var team := route / 3
	var li := route % 3
	var who := ""
	for h in world.heroes.values():
		if h.team == team and int(lm.slot.get(h.hero_id, -1)) == li:
			who = h.player_name
	var mine: bool = world.local_hero != null and world.local_hero.team == team
	return "%s: линия %d%s" % ["Мы" if mine else L.TEAMS[team]["name"], li + 1, (" — " + who) if who != "" else ""]

func _on_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_drag = mb.pressed
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom = maxf(ZOOM_MIN, _zoom * 0.85)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom = minf(ZOOM_MAX, _zoom * 1.18)
		accept_event()
	elif ev is InputEventMouseMotion and _drag:
		# перетаскивание: камера свободная, сдвиг — в метрах по масштабу
		_route = -1
		var k := _zoom / float(_vp.size.y)
		_center -= (ev as InputEventMouseMotion).relative * k
		accept_event()

## Куда смотреть на линии: самый продвинувшийся к базе враг этой линии, иначе середина линии.
func _route_focus(route: int) -> Vector2:
	var lm := _lm()
	var lane: PackedVector2Array = lm.lanes[route]
	var base: Unit = lm.bases[route / 3]
	var bp := Vector2(base.pos.x, base.pos.z)
	var best := lane[lane.size() / 2]
	var best_d := 1e9
	for u: Unit in world.mobs.alive_units():
		var p := Vector2(u.pos.x, u.pos.z)
		if lm.lane_dist(route, p) > 10.0:
			continue
		var d := p.distance_to(bp)
		if d < best_d:
			best_d = d
			best = p
	return best

func _process(_delta: float) -> void:
	if not visible or not _box.visible or _lm() == null:
		return
	_frame += 1
	if _frame % 2 != 0:
		return
	if _route >= 0:
		_title.text = _route_name(_route)
		_center = _center.lerp(_route_focus(_route), 0.25)
	else:
		_title.text = "Обзор: свободная камера"
	_center = _center.clamp(Vector2(-95, -140), Vector2(95, 140))
	_cam.size = _zoom
	_cam.position = Vector3(_center.x, 150.0, _center.y)
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	_marks.queue_redraw()

## Отметки поверх картинки: враги — красные точки, герои — цвет класса и имя, базы — цвет команды.
func _draw_marks() -> void:
	var lm := _lm()
	if lm == null:
		return
	var to_view := func(p: Vector3) -> Vector2:
		return _cam.unproject_position(p) * (_marks.size / Vector2(_vp.size))
	for u: Unit in world.mobs.alive_units():
		var sp: Vector2 = to_view.call(u.pos)
		if Rect2(Vector2.ZERO, _marks.size).has_point(sp):
			var boss: bool = GameData.MOBS.get(u.type_id, {}).get("boss", false)
			_marks.draw_circle(sp, 4.0 if boss else (2.6 if u.elite > 0 else 1.8), Color(1, 0.85, 0.2) if u.elite > 0 or boss else Color(1, 0.25, 0.2))
	for team in 2:
		var b: Unit = lm.bases[team]
		var bs: Vector2 = to_view.call(b.pos)
		_marks.draw_rect(Rect2(bs - Vector2(6, 6), Vector2(12, 12)), GameData.LinesData.TEAMS[team]["color"])
	var font := ThemeDB.fallback_font
	for h in world.heroes.values():
		if h.offline:
			continue
		var hs: Vector2 = to_view.call(h.global_position)
		if not Rect2(Vector2.ZERO, _marks.size).has_point(hs):
			continue
		var col: Color = GameData.CLASSES[h.class_id]["color"]
		_marks.draw_circle(hs, 5.0, Color(0, 0, 0, 0.8))
		_marks.draw_circle(hs, 3.8, col if h.unit.alive else col.darkened(0.6))
		_marks.draw_string_outline(font, hs + Vector2(6, -4), h.player_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, 3, Color(0, 0, 0, 0.9))
		_marks.draw_string(font, hs + Vector2(6, -4), h.player_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)
