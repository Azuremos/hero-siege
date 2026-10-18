extends CanvasLayer
## Игровой интерфейс в духе WoW: портрет игрока с баффами, рамки цели и группы,
## две панели заклинаний, полоса произнесения, опыт, состояние осады, всплывающие цифры.
## Рамки можно двигать мышью: меню (Esc) → «Настроить интерфейс». Расположение сохраняется.
## Рамки группы — интерфейс лечения: клик выбирает союзника,
## а наведение курсора + клавиша заклинания лечит его без смены цели.

const GOLD := Color(0.95, 0.78, 0.35)
const PANEL_BG := Color(0.05, 0.05, 0.08, 0.78)
const LAYOUT_PATH := "user://ui_layout.cfg"
const BAR_SLOTS := 12
const SLOT := 58.0
const SLOT_GAP := 6.0
const PORTRAIT_SHADER := preload("res://shaders/portrait.gdshader")
const SWEEP_SHADER := preload("res://shaders/cooldown_sweep.gdshader")
const PROC_SHADER := preload("res://shaders/proc_border.gdshader")
const MeterWindowScript := preload("res://scripts/ui/meter_window.gd")

var world: Node3D
var hover_unit_id := 0
var game_over_shown := false

var _font: Font
var _root: Control
var _overlay: Control
var _frames: Dictionary = {}           # id -> Control (подвижные рамки)
var _frame_titles := {"player": "Мой герой", "target": "Цель", "party": "Группа", "bar1": "Панель 1",
	"bar2": "Панель 2", "cast": "Полоса произнесения", "mode": "Панель режима", "proc": "Сигнал прока", "meter": "Счётчик урона",
	"pet": "Питомец", "petbar": "Панель питомца", "lanes": "Обзор линий"}
var _layout_pos: Dictionary = {}       # id -> Vector2 (сохранённое)
var _opts := {"party_horizontal": false, "bar2_vertical": false, "proc_border": true, "proc_center": true}

var _player: Dictionary
var _target_frame: Dictionary
var _party_box: BoxContainer
var _party_frames: Dictionary = {}     # hero_id -> {...}
var _slots: Array = []                 # {bar, i, sid, slot, cd, cd_l, lock, ...}
var _bar_boxes: Array = []             # [BoxContainer панели 1, панели 2]
var _buff_row: HBoxContainer
var _skip_btn: Button
var _buff_t := 0.0
var _talent_btn: Button
var _book_btn: Button
var _char_btn: Button
var _meter_btn: Button
var _meter_win: Control
var _talent_window: Control
var _spellbook: Control
var _keybinds: Control
var _cast_bar: Dictionary
var _xp_bar: ProgressBar
var _xp_label: Label
var _mode_title: Label
var _mode_bar: ProgressBar
var _mode_bar_label: Label
var _mode_bar2: ProgressBar
var _mode_bar2_label: Label
var _sends: Control           # окно Вербовщика («Война линий»)
var _buyback_btn: Button
var _gold_label: Label
var _announce: Label
var _announce_t := 0.0
var _error: Label
var _error_t := 0.0
var _death_label: Label
var _menu: PanelContainer
var _help: PanelContainer
var _target_ring: MeshInstance3D
var _target_arrow: MeshInstance3D
var _hover_ring: MeshInstance3D
var _vendor_hint: Label
var _char_window: Control
var _shop: Control
var _numbers: Array = []               # {pos, text, color, age, size, drift}
var _drag_from := Vector2i(-1, -1)     # (панель, ячейка), откуда тащат заклинание

func setup(w: Node3D) -> void:
	world = w
	layer = 5
	# Элементы HUD (в том числе окна, создаваемые позже) не берут фокус клавиатуры:
	# иначе Пробел (ui_accept) «нажимает» последнюю кликнутую кнопку вместо прыжка,
	# а Tab (ui_focus_next) переводит фокус вместо выбора цели.
	get_tree().node_added.connect(_on_node_added)
	_font = _make_font()
	var theme := Theme.new()
	theme.default_font = _font
	theme.default_font_size = 15
	SpellIcon.style_tooltips(theme)
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = theme
	add_child(_root)

	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	_root.add_child(_overlay)

	_load_layout()
	_build_player_frame()
	_build_target_frame()
	_build_party()
	_build_bars()
	_build_cast_bar()
	_build_mode_panel()
	_build_proc_alert()
	_build_meter()
	_build_messages()
	_build_boss_bar()
	_build_pet_frames()
	_build_lane_view()
	_build_menu()
	_build_help()

	_target_ring = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(2, 2)
	_target_ring.mesh = pm
	_target_ring.top_level = true
	_target_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_target_ring.visible = false
	world.vfx_root.add_child(_target_ring)
	_target_arrow = MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(0.5, 0.6, 0.12)
	_target_arrow.mesh = prism
	_target_arrow.top_level = true
	_target_arrow.rotation_degrees.z = 180.0
	_target_arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_target_arrow.visible = false
	world.vfx_root.add_child(_target_arrow)
	_hover_ring = MeshInstance3D.new()
	var hpm := PlaneMesh.new()
	hpm.size = Vector2(2, 2)
	_hover_ring.mesh = hpm
	_hover_ring.top_level = true
	_hover_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_hover_ring.material_override = Vfx.ring_material(Color(1, 1, 0.8, 0.6), 0.0, false, 1.0)
	_hover_ring.visible = false
	world.vfx_root.add_child(_hover_ring)
	_vendor_hint = _label("ПКМ по торговцу — открыть лавку", 18, GOLD)
	_vendor_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_vendor_hint.position = Vector2(-150, -300)
	_vendor_hint.visible = false
	_root.add_child(_vendor_hint)
	rebuild_party()
	Keys.changed.connect(rebuild_action_bar)
	get_viewport().size_changed.connect(_apply_layout)
	_apply_layout.call_deferred()

func _on_node_added(n: Node) -> void:
	if n is Control and not (n is LineEdit or n is TextEdit) and is_ancestor_of(n):
		(n as Control).focus_mode = Control.FOCUS_NONE

func _make_font() -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Segoe UI", "Arial", "Tahoma"])
	f.font_weight = 600
	return f

# ---------------------------------------------------------------- общие элементы

func _panel_style(border: Color = Color(0.55, 0.45, 0.25), bg: Color = PANEL_BG) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(2)
	s.set_corner_radius_all(5)
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	return s

func _bar(col: Color, h: int) -> ProgressBar:
	var b := ProgressBar.new()
	b.custom_minimum_size = Vector2(0, h)
	b.show_percentage = false
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.12, 0.12, 0.12, 0.9)
	bg.set_corner_radius_all(3)
	var fg := StyleBoxFlat.new()
	fg.bg_color = col
	fg.set_corner_radius_all(3)
	b.add_theme_stylebox_override("background", bg)
	b.add_theme_stylebox_override("fill", fg)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return b

func _bar_color(b: ProgressBar, col: Color) -> void:
	(b.get_theme_stylebox("fill") as StyleBoxFlat).bg_color = col

func _label(text: String, size: int = 15, col: Color = Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 4)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

## Подвижная рамка: обычный Control в корне интерфейса.
func _frame(id: String, node: Control) -> Control:
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(node)
	_frames[id] = node
	return node

## Полосы здоровья/маны с подписями.
func _hp_mp(v: VBoxContainer, hp_h: int, mp_h: int) -> Dictionary:
	var hp := _bar(Color(0.2, 0.75, 0.25), hp_h)
	v.add_child(hp)
	var hp_l := _label("", 13)
	hp_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_l.set_anchors_preset(Control.PRESET_FULL_RECT)
	hp.add_child(hp_l)
	var mp := _bar(Color(0.2, 0.4, 0.95), mp_h)
	v.add_child(mp)
	var mp_l := _label("", 10)
	mp_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mp_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	mp_l.set_anchors_preset(Control.PRESET_FULL_RECT)
	mp.add_child(mp_l)
	return {"hp": hp, "hp_l": hp_l, "mp": mp, "mp_l": mp_l}

# ---------------------------------------------------------------- портрет и рамка игрока

func _build_player_frame() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	_frame("player", root)
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_style())
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(p)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	p.add_child(h)
	# портрет — живая 3D-модель героя в круглой рамке
	var portrait := Control.new()
	portrait.custom_minimum_size = Vector2(84, 84)
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(portrait)
	var ring := Panel.new()
	var rs := StyleBoxFlat.new()
	var lh = world.local_hero
	var cls_col: Color = GameData.CLASSES[lh.class_id]["color"] if lh else GOLD
	rs.bg_color = cls_col.darkened(0.7)
	rs.border_color = GOLD
	rs.set_border_width_all(3)
	rs.set_corner_radius_all(42)
	ring.add_theme_stylebox_override("panel", rs)
	ring.size = Vector2(84, 84)
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait.add_child(ring)
	var tex := TextureRect.new()
	tex.position = Vector2(3, 3)
	tex.size = Vector2(78, 78)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = PORTRAIT_SHADER
	tex.material = mat
	portrait.add_child(tex)
	if lh:
		tex.texture = _make_portrait_viewport(portrait, lh)
	var lvl := PanelContainer.new()
	var ls := _panel_style(GOLD, Color(0.05, 0.04, 0.03, 0.95))
	ls.set_corner_radius_all(10)
	ls.content_margin_left = 5
	ls.content_margin_right = 5
	ls.content_margin_top = 0
	ls.content_margin_bottom = 0
	lvl.add_theme_stylebox_override("panel", ls)
	lvl.position = Vector2(-2, 62)
	lvl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait.add_child(lvl)
	var lvl_l := _label("1", 13, GOLD)
	lvl.add_child(lvl_l)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	v.custom_minimum_size = Vector2(220, 0)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_child(v)
	var name_l := _label("", 16, GOLD)
	v.add_child(name_l)
	_player = _hp_mp(v, 22, 12)
	_player.merge({"name": name_l, "portrait": tex, "level": lvl_l, "panel": p})
	# баффы под портретом
	_buff_row = HBoxContainer.new()
	_buff_row.add_theme_constant_override("separation", 4)
	_buff_row.custom_minimum_size = Vector2(0, 46)
	_buff_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_buff_row)

func _make_portrait_viewport(parent: Control, lh) -> Texture2D:
	var vp := SubViewport.new()
	vp.size = Vector2i(128, 128)
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	parent.add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.85, 0.85, 0.9)
	env.ambient_light_energy = 0.7
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-30, 160, 0)
	light.light_energy = 1.2
	vp.add_child(light)
	var model := ModelFactory.build_hero(lh.class_id, lh.race_id)
	model.rotation.y = PI
	vp.add_child(model)
	var ap := ModelFactory.find_anim(model)
	if ap:
		ap.play("Idle")
	var sy: float = model.scale.y
	var cam := Camera3D.new()
	cam.fov = 30.0
	vp.add_child(cam)
	cam.look_at_from_position(Vector3(0.15, 1.95 * sy, 2.2), Vector3(0, 1.62 * sy, 0))
	cam.current = true
	return vp.get_texture()

func _build_target_frame() -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_style())
	p.custom_minimum_size = Vector2(290, 0)
	_frame("target", p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	p.add_child(v)
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 4)
	v.add_child(name_row)
	var mark_icon := TextureRect.new()
	mark_icon.custom_minimum_size = Vector2(20, 20)
	mark_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mark_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	mark_icon.visible = false
	name_row.add_child(mark_icon)
	var name_l := _label("", 16, GOLD)
	name_row.add_child(name_l)
	_target_frame = _hp_mp(v, 22, 12)
	_target_frame.merge({"name": name_l, "panel": p, "mark": mark_icon})
	# ПКМ по рамке цели — меню рейдовых меток
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
			_open_mark_menu())
	var affix_l := _label("", 12, Color(1.0, 0.75, 0.35))
	affix_l.visible = false
	affix_l.mouse_filter = Control.MOUSE_FILTER_PASS
	v.add_child(affix_l)
	_target_frame["affix"] = affix_l
	_target_frame["ecast"] = _make_enemy_cast_bar(266.0, 16.0, 13)
	v.add_child(_target_frame["ecast"])
	var fx_row := HBoxContainer.new()
	fx_row.add_theme_constant_override("separation", 3)
	v.add_child(fx_row)
	_target_frame["fx"] = fx_row
	_head_fx = HBoxContainer.new()
	_head_fx.add_theme_constant_override("separation", 2)
	_head_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_head_fx)

# ---------------------------------------------------------------- группа

func _build_party() -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_style(Color(0.4, 0.35, 0.25), Color(0, 0, 0, 0.45)))
	_frame("party", p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	p.add_child(v)
	v.add_child(_label("Группа  (F1–F6)", 13, GOLD))
	_party_box = HBoxContainer.new() if _opts["party_horizontal"] else VBoxContainer.new()
	_party_box.add_theme_constant_override("separation", 4)
	v.add_child(_party_box)

func _set_party_horizontal(on: bool) -> void:
	_opts["party_horizontal"] = on
	var parent := _party_box.get_parent()
	_party_box.queue_free()
	_party_box = HBoxContainer.new() if on else VBoxContainer.new()
	_party_box.add_theme_constant_override("separation", 4)
	parent.add_child(_party_box)
	rebuild_party()
	_frames["party"].reset_size()
	_save_layout()

func rebuild_party() -> void:
	for c in _party_box.get_children():
		c.queue_free()
	_party_frames.clear()
	for hid in party_order():
		var h = world.heroes[hid]
		var frame := Panel.new()
		frame.custom_minimum_size = Vector2(210, 44)
		var st := _panel_style(Color(0.25, 0.25, 0.25), Color(0.08, 0.08, 0.1, 0.9))
		st.content_margin_left = 0
		frame.add_theme_stylebox_override("panel", st)
		frame.mouse_filter = Control.MOUSE_FILTER_STOP
		frame.mouse_entered.connect(func(): hover_unit_id = hid)
		frame.mouse_exited.connect(func():
			if hover_unit_id == hid:
				hover_unit_id = 0)
		frame.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				if world.local_hero:
					world.local_hero.controller.target_id = hid
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
				hero_menu(hid))
		_party_box.add_child(frame)
		var hp := _bar(GameData.CLASSES[h.class_id]["color"].darkened(0.15), 28)
		hp.position = Vector2(4, 4)
		hp.size = Vector2(202, 28)
		frame.add_child(hp)
		var mp := _bar(Color(0.2, 0.4, 0.95), 6)
		mp.position = Vector2(4, 34)
		mp.size = Vector2(202, 6)
		frame.add_child(mp)
		var nl := _label(h.player_name, 14, Color.WHITE)
		nl.position = Vector2(10, 7)
		frame.add_child(nl)
		var info := _label("", 12, Color(1, 1, 1, 0.85))
		info.position = Vector2(120, 2)
		info.size = Vector2(80, 20)
		info.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		frame.add_child(info)
		var buffs := HBoxContainer.new()
		buffs.position = Vector2(118, 14)
		buffs.add_theme_constant_override("separation", 2)
		buffs.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(buffs)
		var pet_bar: ProgressBar = null
		if h.class_id == "hunter":
			# питомец охотника — тонкая полоска под рамкой; клик выбирает питомца (лекарю — лечить)
			frame.custom_minimum_size.y = 56
			pet_bar = _bar(Color(0.55, 0.75, 0.3), 9)
			pet_bar.position = Vector2(30, 43)
			pet_bar.size = Vector2(176, 9)
			pet_bar.max_value = 1.0
			pet_bar.mouse_filter = Control.MOUSE_FILTER_STOP
			pet_bar.tooltip_text = "Питомец — ЛКМ: выбрать целью. Наведите и нажмите клавишу лечения — лечение уйдёт питомцу."
			# лечение «по наведению», как у рамок героев
			pet_bar.mouse_entered.connect(func():
				var hp_u: Unit = world.mobs.pet_of(hid)
				if hp_u:
					hover_unit_id = hp_u.id)
			pet_bar.mouse_exited.connect(func():
				var hp_u: Unit = world.mobs.pet_of(hid)
				if hp_u and hover_unit_id == hp_u.id:
					hover_unit_id = 0)
			pet_bar.gui_input.connect(func(ev: InputEvent):
				if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT and world.local_hero:
					var pu: Unit = world.mobs.pet_of(hid)
					if pu:
						world.local_hero.controller.target_id = pu.id
					pet_bar.accept_event())
			frame.add_child(pet_bar)
			var pl := _label("пит.", 9, Color(0.7, 0.85, 0.5))
			pl.position = Vector2(4, 41)
			frame.add_child(pl)
		_party_frames[hid] = {"frame": frame, "style": st, "hp": hp, "mp": mp, "info": info, "buffs": buffs, "name": nl, "pet": pet_bar}

func party_order() -> Array:
	var ids: Array = world.heroes.keys().filter(func(id): return world.mode.party_visible(world.local_hero, world.heroes[id]))
	ids.sort()
	if world.local_hero:
		ids.erase(world.local_hero.hero_id)
		ids.push_front(world.local_hero.hero_id)
	return ids

# ---------------------------------------------------------------- панели заклинаний

## «Часы» перезарядки на ячейке (шейдер cooldown_sweep): progress — доля оставшегося времени.
func _sweep(slot: Control, shade: Color, edge: Color) -> ColorRect:
	var r := ColorRect.new()
	r.position = Vector2(2, 2)
	r.size = Vector2(SLOT - 4, SLOT - 4)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = SWEEP_SHADER
	mat.set_shader_parameter("shade", shade)
	mat.set_shader_parameter("edge", edge)
	mat.set_shader_parameter("progress", 0.0)
	r.material = mat
	slot.add_child(r)
	return r

func _side_btn(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(112, 27)
	b.add_theme_font_size_override("font_size", 12)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b

func _with_key(text: String, action: String) -> String:
	var k := Keys.label(action)
	return text if k == "—" else "%s (%s)" % [text, k]

func _build_bars() -> void:
	# Панель 1: ячейки + кнопки талантов/книги + полоса опыта
	var root1 := VBoxContainer.new()
	root1.add_theme_constant_override("separation", 6)
	_frame("bar1", root1)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	root1.add_child(row)
	var box1 := HBoxContainer.new()
	box1.add_theme_constant_override("separation", int(SLOT_GAP))
	row.add_child(box1)
	var side := GridContainer.new()
	side.columns = 2
	side.add_theme_constant_override("h_separation", 3)
	side.add_theme_constant_override("v_separation", 3)
	row.add_child(side)
	_talent_btn = _side_btn(side, "Таланты", toggle_talents)
	_book_btn = _side_btn(side, "Книга", toggle_spellbook)
	_char_btn = _side_btn(side, "Персонаж", toggle_character)
	_meter_btn = _side_btn(side, "Счётчик", toggle_meter)
	_xp_bar = _bar(Color(0.5, 0.25, 0.8), 16)
	_xp_bar.custom_minimum_size = Vector2(BAR_SLOTS * (SLOT + SLOT_GAP) - SLOT_GAP, 16)
	_xp_bar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	root1.add_child(_xp_bar)
	_xp_label = _label("", 11, Color(0.95, 0.9, 1.0))
	_xp_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_xp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_xp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_xp_bar.add_child(_xp_label)
	# Панель 2: только ячейки, раскладка горизонтальная или вертикальная
	var root2 := Control.new()
	_frame("bar2", root2)
	_bar_boxes = [box1, null]
	_make_bar2_box()
	rebuild_action_bar()

func _make_bar2_box() -> void:
	var holder: Control = _frames["bar2"]
	for c in holder.get_children():
		c.queue_free()
	var box: BoxContainer = VBoxContainer.new() if _opts["bar2_vertical"] else HBoxContainer.new()
	box.add_theme_constant_override("separation", int(SLOT_GAP))
	holder.add_child(box)
	_bar_boxes[1] = box
	var n := float(BAR_SLOTS)
	holder.custom_minimum_size = Vector2(SLOT, n * (SLOT + SLOT_GAP)) if _opts["bar2_vertical"] else Vector2(n * (SLOT + SLOT_GAP), SLOT)
	holder.size = holder.custom_minimum_size

func _set_bar2_vertical(on: bool) -> void:
	_opts["bar2_vertical"] = on
	_make_bar2_box()
	rebuild_action_bar()
	_save_layout()
	_apply_layout()

func rebuild_action_bar() -> void:
	_slots.clear()
	for b in 2:
		var box: BoxContainer = _bar_boxes[b]
		if box == null:
			continue
		for c in box.get_children():
			c.queue_free()
		if world.local_hero == null:
			continue
		for i in BAR_SLOTS:
			_make_slot(box, b, i)
	on_level_changed()

func _make_slot(box: BoxContainer, b: int, i: int) -> void:
	var c = world.local_hero.controller
	var sid: String = c.bars[b][i]
	var slot := Panel.new()
	slot.custom_minimum_size = Vector2(SLOT, SLOT)
	var st := StyleBoxFlat.new()
	st.set_border_width_all(2)
	st.set_corner_radius_all(6)
	st.shadow_color = Color(0, 0, 0, 0.5)
	st.shadow_size = 3
	slot.add_theme_stylebox_override("panel", st)
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.set_drag_forwarding(_slot_drag.bind(b, i, slot), _slot_can_drop, _slot_drop.bind(b, i))
	slot.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and not ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT and c.bars[b][i] != "":
			c.try_cast(c.bars[b][i]))
	box.add_child(slot)
	var entry := {"bar": b, "i": i, "sid": sid, "slot": slot}
	if sid == "":
		st.bg_color = Color(0, 0, 0, 0.45)
		st.border_color = Color(0.3, 0.3, 0.3, 0.8)
	elif sid.begins_with("item:"):
		var iid := sid.trim_prefix("item:")
		st.bg_color = Color(0.1, 0.1, 0.1, 0.8)
		st.border_color = GameData.item_color(iid)
		var icon := SpellIcon.make_item(iid, SLOT - 4)
		icon.position = Vector2(2, 2)
		slot.add_child(icon)
		var cd := _sweep(slot, Color(0, 0, 0, 0.65), Color(0, 0, 0, 0))
		var cnt := _label("", 13, Color.WHITE)
		cnt.position = Vector2(SLOT - 24, SLOT - 20)
		slot.add_child(cnt)
		entry.merge({"cd": cd, "icon": icon, "count": cnt, "item": iid})
	elif sid.begins_with("use:"):
		# используемый аксессуар: кнопка ячейки снаряжения, иконка — надетой вещи
		var tslot := sid.trim_prefix("use:")
		var eid := str(world.local_hero.equip.get(tslot, ""))
		st.bg_color = Color(0.1, 0.1, 0.1, 0.8)
		st.border_color = GameData.item_color(eid) if eid != "" else Color(0.4, 0.4, 0.4)
		var icon: Control = SpellIcon.make_item(eid, SLOT - 4) if eid != "" else _label("Акс.", 13, Color(0.6, 0.6, 0.6))
		icon.position = Vector2(2, 2)
		slot.add_child(icon)
		var cd := _sweep(slot, Color(0, 0, 0, 0.68), Color(1.0, 0.92, 0.55, 0.5))
		var cd_l := _label("", 18, Color(1, 0.95, 0.6))
		cd_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cd_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		cd_l.size = Vector2(SLOT, SLOT)
		slot.add_child(cd_l)
		entry.merge({"cd": cd, "cd_l": cd_l, "use": tslot, "use_id": eid})
	else:
		var sp: Dictionary = GameData.SPELLS[sid]
		var col: Color = GameData.SCHOOLS[sp["school"]]["color"]
		st.bg_color = col.darkened(0.55)
		st.border_color = GOLD if sp.get("talent", false) else col.lightened(0.1)
		var icon := SpellIcon.make(sid, SLOT - 4)
		icon.position = Vector2(2, 2)
		slot.add_child(icon)
		var proc := ColorRect.new()
		proc.size = Vector2(SLOT, SLOT)
		proc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var pmat := ShaderMaterial.new()
		pmat.shader = PROC_SHADER
		proc.material = pmat
		proc.visible = false
		var gcd := _sweep(slot, Color(0, 0, 0, 0.32), Color(1.0, 0.92, 0.55, 0.9))
		var cd := _sweep(slot, Color(0, 0, 0, 0.68), Color(1.0, 0.92, 0.55, 0.5))
		var cd_l := _label("", 18, Color(1, 0.95, 0.6))
		cd_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cd_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		cd_l.size = Vector2(SLOT, SLOT)
		slot.add_child(cd_l)
		var lock := ColorRect.new()
		lock.color = Color(0.02, 0.02, 0.04, 0.78)
		lock.position = Vector2(2, 2)
		lock.size = Vector2(SLOT - 4, SLOT - 4)
		lock.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(lock)
		var lock_l := _label("ур. %d" % GameData.spell_level(sid), 14, Color(0.85, 0.8, 0.7))
		lock_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lock_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lock_l.size = Vector2(SLOT - 4, SLOT - 4)
		lock.add_child(lock_l)
		slot.add_child(proc)
		entry.merge({"cd": cd, "gcd": gcd, "cd_l": cd_l, "icon": icon, "lock": lock, "proc": proc})
	var key := _label(Keys.short_label("bar%d_%d" % [b + 1, i]), 12, Color(1, 1, 1, 0.9))
	key.position = Vector2(5, 1)
	slot.add_child(key)
	_slots.append(entry)

func _slot_drag(_at: Vector2, b: int, i: int, slot: Control) -> Variant:
	var sid: String = world.local_hero.controller.bars[b][i]
	if sid == "":
		return null
	_drag_from = Vector2i(b, i)
	slot.set_drag_preview(SpellIcon.make_item(str(world.local_hero.equip.get(sid.trim_prefix("use:"), "")), 50) if sid.begins_with("use:") else SpellIcon.make(sid, 50))
	return {"type": "spell", "sid": sid, "bar": b, "from": i}

func _slot_can_drop(_at: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.get("type", "") == "spell"

func _slot_drop(_at: Vector2, data: Variant, b: int, i: int) -> void:
	var c = world.local_hero.controller
	if int(data["from"]) >= 0:
		c.swap_slots(int(data["bar"]), int(data["from"]), b, i)
	else:
		c.place_spell(data["sid"], b, i)
	Sfx.play("ui_drop")
	_drag_from = Vector2i(-1, -1)
	rebuild_action_bar()

func _notification(what: int) -> void:
	# заклинание утащили с панели в пустоту — убираем его из ячейки
	if what == NOTIFICATION_DRAG_END and _drag_from.x >= 0:
		if not get_viewport().gui_is_drag_successful() and world and world.local_hero:
			world.local_hero.controller.clear_slot(_drag_from.x, _drag_from.y)
			rebuild_action_bar()
		_drag_from = Vector2i(-1, -1)

## Обновляет замки и подсказки (вызывается при новом уровне).
func on_level_changed() -> void:
	var lh = world.local_hero
	if lh == null:
		return
	for s in _slots:
		if s["sid"] == "":
			s["slot"].tooltip_text = "Пустая ячейка — перетащите сюда заклинание из книги или зелье из сумки"
			continue
		if s.has("item"):
			s["slot"].tooltip_text = GameData.item_tooltip(s["item"])
			continue
		if s.has("use"):
			var ueid2 := str(lh.equip.get(s["use"], ""))
			s["slot"].tooltip_text = GameData.item_tooltip(ueid2) if ueid2 != "" else "Аксессуар не надет"
			continue
		var open: bool = lh.unit.level >= GameData.spell_level(s["sid"])
		s["lock"].visible = not open
		var tip := SpellIcon.tooltip(s["sid"], lh.unit)
		if not open:
			tip = "Откроется на %d уровне\n\n" % GameData.spell_level(s["sid"]) + tip
		s["slot"].tooltip_text = tip
	if _talent_window and _talent_window.visible:
		_talent_window.refresh()

var _talent_count := 0
func on_talents_changed() -> void:
	var n := GameData.talent_points_spent(world.local_hero.talents)
	if n > _talent_count:
		Sfx.play("ui_learn")
	_talent_count = n
	world.local_hero.controller.sync_bar()
	rebuild_action_bar()
	if _talent_window:
		_talent_window.refresh()
	if _spellbook and _spellbook.visible:
		_spellbook.refresh()

# ---------------------------------------------------------------- полоса произнесения и осада

func _build_cast_bar() -> void:
	var cast := PanelContainer.new()
	cast.add_theme_stylebox_override("panel", _panel_style())
	cast.custom_minimum_size = Vector2(340, 0)
	_frame("cast", cast)
	var cb := _bar(GOLD, 18)
	cast.add_child(cb)
	var cl := _label("", 13)
	cl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cl.set_anchors_preset(Control.PRESET_FULL_RECT)
	cb.add_child(cl)
	_cast_bar = {"panel": cast, "bar": cb, "label": cl}

## Сигнал прока в центре экрана, как Spell Activation Overlay в WoW: крупные полупрозрачные иконки
## усиленного заклинания по бокам от героя, пока прок активен. Двигается в режиме настройки интерфейса.
const PROC_ICON := 92.0
const PROC_GAP := 240.0
var _proc_alert: Dictionary = {}
var _proc_seen: Dictionary = {}

func _build_proc_alert() -> void:
	var root := Control.new()
	root.custom_minimum_size = Vector2(PROC_ICON * 2.0 + PROC_GAP, PROC_ICON + 28.0)
	_frame("proc", root)
	var left := Control.new()
	left.size = Vector2(PROC_ICON, PROC_ICON)
	left.pivot_offset = left.size * 0.5
	root.add_child(left)
	var right := Control.new()
	right.position = Vector2(PROC_ICON + PROC_GAP, 0)
	right.size = Vector2(PROC_ICON, PROC_ICON)
	right.pivot_offset = right.size * 0.5
	root.add_child(right)
	var label := _label("", 18, GOLD)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = Vector2(0, PROC_ICON + 2.0)
	label.size = Vector2(root.custom_minimum_size.x, 24)
	root.add_child(label)
	root.visible = false
	_proc_alert = {"root": root, "left": left, "right": right, "label": label, "sid": ""}

func _update_proc_alert(lh, t: float) -> void:
	var known: Array = lh.spell_list()
	var active: Array = []       # [ключ прока, заклинание]
	for b in lh.net_buffs:
		if GameData.PROC_BUFFS.has(b[0]):
			for s in GameData.PROC_BUFFS[b[0]]["spells"]:
				if known.has(s):
					active.append([b[0], s])
					break
	var keys := {}
	for a in active:
		keys[a[0]] = true
		if not _proc_seen.has(a[0]) and _opts["proc_center"]:
			Sfx.play("proc_alert")
	_proc_seen = keys
	var root: Control = _proc_alert["root"]
	var editing := is_editing()
	root.visible = editing or (_opts["proc_center"] and not active.is_empty())
	if not root.visible or known.is_empty():
		_proc_alert["sid"] = ""
		return
	var key: String = active[0][0] if not active.is_empty() else ""
	var sid: String = active[0][1] if not active.is_empty() else known[0]
	if _proc_alert["sid"] != sid:
		_proc_alert["sid"] = sid
		for side in ["left", "right"]:
			var holder: Control = _proc_alert[side]
			for c in holder.get_children():
				c.queue_free()
			holder.add_child(SpellIcon.make(sid, PROC_ICON))
		var title: String = GameData.BUFF_INFO[key]["name"] if GameData.BUFF_INFO.has(key) else "Сигнал прока"
		(_proc_alert["label"] as Label).text = "%s — %s" % [title, GameData.SPELLS[sid]["name"]]
	var p := 0.5 + 0.5 * sin(t * 5.0)
	for side in ["left", "right"]:
		var holder: Control = _proc_alert[side]
		holder.modulate = Color(1.15, 1.05, 0.8, 0.45 + 0.3 * p)
		holder.scale = Vector2.ONE * (1.0 + 0.06 * p)

## Счётчик урона и лечения — подвижная рамка «meter»; видимость запоминается.
var _meter_forced := false

func _build_meter() -> void:
	_meter_win = MeterWindowScript.new()
	_frame("meter", _meter_win)
	_meter_win.setup(world, world.meter)
	_meter_win.visible = bool(Settings.get_ui_opt("meter_visible", true))

## Предпросмотр из главного меню: счётчик показывает пример.
func set_meter_preview(on: bool) -> void:
	_meter_win.preview = on
	_meter_win.visible = true

func toggle_meter() -> void:
	_meter_win.visible = not _meter_win.visible
	Settings.set_ui_opt("meter_visible", _meter_win.visible)
	Sfx.play("ui_open" if _meter_win.visible else "ui_close")

## В режиме настройки интерфейса счётчик виден, даже если игрок его закрыл.
func _update_meter_visibility() -> void:
	if is_editing() and not _meter_win.visible:
		_meter_win.visible = true
		_meter_forced = true
	elif not is_editing() and _meter_forced:
		_meter_forced = false
		_meter_win.visible = bool(Settings.get_ui_opt("meter_visible", true))

## Панель режима: у осады — номер волны, прочность замка, золото и кнопка «Начать волну сейчас».
func _build_mode_panel() -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_style())
	p.custom_minimum_size = Vector2(380, 0)
	_frame("mode", p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	p.add_child(v)
	_mode_title = _label("", 16, GOLD)
	_mode_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_mode_title)
	_mode_bar = _bar(Color(0.3, 0.55, 0.95), 18)
	v.add_child(_mode_bar)
	_mode_bar_label = _label("", 12)
	_mode_bar_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mode_bar_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_mode_bar.add_child(_mode_bar_label)
	# вторая полоса — у режимов «команда на команду» (база соперника)
	_mode_bar2 = _bar(Color(1, 0.4, 0.3), 18)
	_mode_bar2.visible = false
	v.add_child(_mode_bar2)
	_mode_bar2_label = _label("", 12)
	_mode_bar2_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mode_bar2_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_mode_bar2.add_child(_mode_bar2_label)
	_gold_label = _label("", 15, GOLD)
	_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_gold_label)
	_skip_btn = Button.new()
	_skip_btn.visible = false
	_skip_btn.pressed.connect(func(): world.mode.skip())
	v.add_child(_skip_btn)

	var help_hint := _label("H — управление    Esc — меню", 13, Color(1, 1, 1, 0.6))
	help_hint.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	help_hint.position = Vector2(-260, -28)
	_root.add_child(help_hint)

func _build_messages() -> void:
	_announce = _label("", 30, GOLD)
	_announce.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_announce.position = Vector2(-500, 120)
	_announce.size = Vector2(1000, 40)
	_announce.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_announce.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART     # длинные реплики боссов
	_root.add_child(_announce)
	_error = _label("", 18, Color(1, 0.3, 0.25))
	_error.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_error.position = Vector2(-400, 170)
	_error.size = Vector2(800, 30)
	_error.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_error)
	_death_label = _label("", 28, Color(1, 0.5, 0.45))
	_death_label.set_anchors_preset(Control.PRESET_CENTER)
	_death_label.position = Vector2(-400, -60)
	_death_label.size = Vector2(800, 40)
	_death_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_death_label)
	# «Война линий»: выкуп — воскреснуть сразу за золото
	_buyback_btn = Button.new()
	_buyback_btn.visible = false
	_buyback_btn.set_anchors_preset(Control.PRESET_CENTER)
	_buyback_btn.position = Vector2(-110, -10)
	_buyback_btn.custom_minimum_size = Vector2(220, 36)
	_buyback_btn.pressed.connect(func(): world.mode.buyback())
	_root.add_child(_buyback_btn)

func _center_panel(w: float) -> Array:
	var holder := CenterContainer.new()
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(holder)
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_style(GOLD, Color(0.06, 0.05, 0.08, 0.95)))
	p.custom_minimum_size = Vector2(w, 0)
	holder.add_child(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	p.add_child(v)
	return [p, v]

func _build_menu() -> void:
	var r := _center_panel(340)
	_menu = r[0]
	var v: VBoxContainer = r[1]
	var t := _label("Меню", 22, GOLD)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var b1 := Button.new()
	b1.text = "Продолжить"
	b1.pressed.connect(toggle_menu)
	v.add_child(b1)
	var b_ui := Button.new()
	b_ui.text = "Настроить интерфейс (двигать рамки)"
	b_ui.pressed.connect(func():
		toggle_menu()
		set_edit_mode(true))
	v.add_child(b_ui)
	var b_keys := Button.new()
	b_keys.text = "Горячие клавиши"
	b_keys.pressed.connect(func():
		toggle_menu()
		toggle_keybinds())
	v.add_child(b_keys)
	var b2 := Button.new()
	b2.text = "Управление"
	b2.pressed.connect(func(): toggle_menu(); toggle_help())
	v.add_child(b2)
	var b_set := Button.new()
	b_set.text = "Настройки (звук, графика, интерфейс)"
	b_set.pressed.connect(func():
		toggle_menu()
		toggle_settings())
	v.add_child(b_set)
	if Net.is_server() and world.mode is SiegeMode:
		# хост: сохранить недоигранную осаду и продолжить её потом с того же места (главное меню → «Продолжить осаду»)
		var b_save := Button.new()
		b_save.text = "Сохранить осаду и выйти"
		b_save.tooltip_text = "Между волнами — с того же места. Во время волны она начнётся заново."
		b_save.pressed.connect(func():
			var p := SiegeSave.save(world)
			if p == "":
				error("Не удалось сохранить осаду")
				return
			Net.back_to_menu())
		v.add_child(b_save)
	var b3 := Button.new()
	b3.text = "Выйти в главное меню"
	b3.pressed.connect(func(): Net.back_to_menu())
	v.add_child(b3)
	_menu.visible = false

func _build_help() -> void:
	var r := _center_panel(560)
	_help = r[0]
	var v: VBoxContainer = r[1]
	var t := _label("Управление", 22, GOLD)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var text := """W / S — вперёд / назад      A / D — поворот (с ПКМ — шаг вбок)
Q / E — шаг влево / вправо      Пробел — прыжок
ПКМ (зажать) — поворот камеры и героя
ЛКМ (зажать) — осмотреться камерой
ЛКМ + ПКМ — бежать вперёд      Колесо — приближение

ЛКМ по существу — выбрать цель      Tab — ближайший враг
ПКМ по врагу — атаковать
Панель 1: 1–9, 0, −, =      Панель 2: Shift + те же клавиши
(клавиши меняются: Esc → «Горячие клавиши»)
N — таланты      P — книга заклинаний
Заклинания на панелях можно перетаскивать мышью
Рамки интерфейса двигаются: Esc → «Настроить интерфейс»
Заклинания на землю: выберите точку ЛКМ, ПКМ — отмена
Стены: зажмите ЛКМ и протяните мышью — стена встанет по линии

Лечение: клик по рамке группы выбирает союзника.
Наведите курсор на рамку и нажмите клавишу —
заклинание уйдёт на этого союзника (без смены цели).
F1–F6 — выбрать участника группы
Esc — отмена / снять цель / меню"""
	var l := _label(text, 15, Color(0.95, 0.93, 0.88))
	v.add_child(l)
	var b := Button.new()
	b.text = "Закрыть"
	b.pressed.connect(toggle_help)
	v.add_child(b)
	_help.visible = false

# ---------------------------------------------------------------- расположение рамок

func _load_layout() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(LAYOUT_PATH) != OK:
		return
	for id in _frame_titles:
		if cfg.has_section_key("pos", id):
			_layout_pos[id] = cfg.get_value("pos", id)
	# до v0.5 панель режима называлась «siege»
	if not _layout_pos.has("mode") and cfg.has_section_key("pos", "siege"):
		_layout_pos["mode"] = cfg.get_value("pos", "siege")
	for k in _opts:
		_opts[k] = cfg.get_value("opt", k, _opts[k])

func _save_layout() -> void:
	if not Net.cli.is_empty():
		return   # тестовые запуски не трогают раскладку игрока
	var cfg := ConfigFile.new()
	for id in _layout_pos:
		cfg.set_value("pos", id, _layout_pos[id])
	for k in _opts:
		cfg.set_value("opt", k, _opts[k])
	cfg.save(LAYOUT_PATH)

func _default_pos(id: String, size: Vector2, vp: Vector2) -> Vector2:
	var bar1: Control = _frames["bar1"]
	var bar1_y := vp.y - bar1.size.y - 6.0
	match id:
		"player": return Vector2(16, 12)
		"target": return Vector2(360, 12)
		"party": return Vector2(16, 228)
		"mode": return Vector2(vp.x - size.x - 16, 12)
		"bar1": return Vector2((vp.x - size.x) * 0.5 + 80, bar1_y)
		"bar2":
			if _opts["bar2_vertical"]:
				return Vector2(vp.x - size.x - 16, (vp.y - size.y) * 0.5)
			return Vector2((vp.x - BAR_SLOTS * (SLOT + SLOT_GAP)) * 0.5 + 80, bar1_y - size.y - 8)
		"cast": return Vector2((vp.x - size.x) * 0.5, vp.y - 250)
		"proc": return Vector2((vp.x - size.x) * 0.5, vp.y * 0.3)
		"meter": return Vector2(vp.x - size.x - 16, vp.y - size.y - 175)
		"pet": return Vector2(16, 172)
		"lanes": return Vector2(16, vp.y - size.y - 150)
		"petbar": return Vector2((vp.x - size.x) * 0.5 + 80, bar1_y - 2.0 * (SLOT + SLOT_GAP) - size.y - 14.0)
	return Vector2.ZERO

func _apply_layout() -> void:
	var vp := get_viewport().get_visible_rect().size
	for id in _frames:
		var f: Control = _frames[id]
		f.reset_size()
		var pos: Vector2 = _layout_pos.get(id, _default_pos(id, f.size, vp))
		f.position = Vector2(clampf(pos.x, 0, maxf(0, vp.x - f.size.x)), clampf(pos.y, 0, maxf(0, vp.y - f.size.y)))

func reset_layout() -> void:
	_layout_pos.clear()
	_opts["party_horizontal"] = false
	_opts["bar2_vertical"] = false
	_set_party_horizontal(false)
	_set_bar2_vertical(false)
	_save_layout()
	_apply_layout()

# ---------------------------------------------------------------- режим настройки интерфейса

var _edit_layer: Control = null
var _movers: Dictionary = {}
var _drag_frame := ""
var _drag_offset := Vector2.ZERO

func set_edit_mode(on: bool) -> void:
	if _edit_layer:
		_edit_layer.queue_free()
		_edit_layer = null
		_movers.clear()
	if not on:
		_save_layout()
		if world.mode.is_preview():
			Net.back_to_menu.call_deferred()
		return
	_edit_layer = Control.new()
	_edit_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_edit_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_edit_layer)
	for id in _frames:
		var m := Panel.new()
		var st := StyleBoxFlat.new()
		st.bg_color = Color(0.2, 0.45, 0.9, 0.35)
		st.border_color = Color(0.5, 0.75, 1.0, 0.9)
		st.set_border_width_all(2)
		st.set_corner_radius_all(4)
		m.add_theme_stylebox_override("panel", st)
		m.mouse_filter = Control.MOUSE_FILTER_STOP
		m.mouse_default_cursor_shape = Control.CURSOR_MOVE
		m.gui_input.connect(_mover_input.bind(id))
		var l := _label(_frame_titles[id], 14, Color.WHITE)
		l.position = Vector2(6, 2)
		m.add_child(l)
		_edit_layer.add_child(m)
		_movers[id] = m
	# панель с кнопками
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", _panel_style(GOLD, Color(0.05, 0.05, 0.1, 0.95)))
	bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	bar.position = Vector2(-330, 70)
	_edit_layer.add_child(bar)
	var v := VBoxContainer.new()
	bar.add_child(v)
	v.add_child(_label("Настройка интерфейса: перетаскивайте рамки мышью", 16, GOLD))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	v.add_child(h)
	var b_party := Button.new()
	b_party.text = "Группа: горизонтально" if not _opts["party_horizontal"] else "Группа: вертикально"
	b_party.pressed.connect(func():
		_set_party_horizontal(not _opts["party_horizontal"])
		set_edit_mode(true))
	h.add_child(b_party)
	var b_bar2 := Button.new()
	b_bar2.text = "Панель 2: вертикально" if not _opts["bar2_vertical"] else "Панель 2: горизонтально"
	b_bar2.pressed.connect(func():
		_set_bar2_vertical(not _opts["bar2_vertical"])
		set_edit_mode(true))
	h.add_child(b_bar2)
	var b_reset := Button.new()
	b_reset.text = "Сбросить"
	b_reset.pressed.connect(func():
		reset_layout()
		set_edit_mode(true))
	h.add_child(b_reset)
	var b_done := Button.new()
	b_done.text = "Готово — в главное меню" if world.mode.is_preview() else "Готово"
	b_done.pressed.connect(func(): set_edit_mode(false))
	h.add_child(b_done)

func is_editing() -> bool:
	return _edit_layer != null

func _mover_input(ev: InputEvent, id: String) -> void:
	var f: Control = _frames[id]
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		if ev.pressed:
			_drag_frame = id
			_drag_offset = f.get_global_mouse_position() - f.position
		else:
			_drag_frame = ""
			_layout_pos[id] = f.position
			_save_layout()
	elif ev is InputEventMouseMotion and _drag_frame == id:
		var vp := get_viewport().get_visible_rect().size
		var p: Vector2 = f.get_global_mouse_position() - _drag_offset
		f.position = Vector2(clampf(p.x, 0, maxf(0, vp.x - f.size.x)), clampf(p.y, 0, maxf(0, vp.y - f.size.y)))

func _update_movers() -> void:
	for id in _movers:
		var f: Control = _frames[id]
		var m: Panel = _movers[id]
		var sz := f.size
		if sz.x < 40 or sz.y < 20:
			sz = Vector2(maxf(sz.x, 200), maxf(sz.y, 40))
		m.position = f.position
		m.size = sz

# ---------------------------------------------------------------- окна

func toggle_spellbook() -> void:
	if _spellbook == null:
		_spellbook = preload("res://scripts/ui/spellbook.gd").new()
		_spellbook.setup(world)
		_root.add_child(_spellbook)
		_spellbook.visible = false
	_spellbook.visible = not _spellbook.visible
	Sfx.play("book_open" if _spellbook.visible else "book_close")
	if _spellbook.visible:
		_spellbook.refresh()

func toggle_talents() -> void:
	if _talent_window == null:
		_talent_window = preload("res://scripts/ui/talent_window.gd").new()
		_talent_window.setup(world)
		_root.add_child(_talent_window)
		_talent_window.visible = false
	_talent_window.visible = not _talent_window.visible
	Sfx.play("ui_open" if _talent_window.visible else "ui_close")
	if _talent_window.visible:
		_talent_window.refresh()

var _settings_win: Control
func toggle_settings() -> void:
	if _settings_win == null:
		_settings_win = preload("res://scripts/ui/settings_window.gd").new()
		_settings_win.on_ui_changed = reload_layout
		_settings_win.on_keys = func():
			_settings_win.visible = false
			toggle_keybinds()
		_root.add_child(_settings_win)
		_settings_win.visible = false
	_settings_win.visible = not _settings_win.visible

## Перечитать раскладку (после изменений в окне настроек).
func reload_layout() -> void:
	_layout_pos.clear()
	_load_layout()
	var party_h: bool = _opts["party_horizontal"]
	var bar2_v: bool = _opts["bar2_vertical"]
	_set_party_horizontal(party_h)
	_set_bar2_vertical(bar2_v)
	_apply_layout()

func toggle_keybinds() -> void:
	if _keybinds == null:
		_keybinds = preload("res://scripts/ui/keybind_window.gd").new()
		_root.add_child(_keybinds)
		_keybinds.visible = false
	_keybinds.visible = not _keybinds.visible
	Sfx.play("ui_open" if _keybinds.visible else "ui_close")

func toggle_character() -> void:
	if _char_window == null:
		_char_window = preload("res://scripts/ui/character_window.gd").new()
		_char_window.setup(world)
		_root.add_child(_char_window)
		_char_window.visible = false
	_char_window.visible = not _char_window.visible
	Sfx.play("ui_open" if _char_window.visible else "ui_close")
	if _char_window.visible:
		_char_window.refresh()
		_char_window.reset_size()
		var vp := get_viewport().get_visible_rect().size
		# окно не выходит за края экрана
		_char_window.position = Vector2(maxf(10.0, vp.x - _char_window.size.x - 30), clampf((vp.y - _char_window.size.y) * 0.5 - 40, 10.0, maxf(10.0, vp.y - _char_window.size.y - 10)))
		# подсказка с переносом строк уточняет высоту только через кадр — тогда ужимаем окно ещё раз
		await get_tree().process_frame
		await get_tree().process_frame
		if is_instance_valid(_char_window):
			_char_window.reset_size()

func open_shop(vid: String) -> void:
	if world.economy.VENDORS[world.economy.vkind(vid)]["kind"] == "sends":
		open_sends(vid)
		return
	if not world.mode.vendor_allowed(world.local_hero, vid):
		error("Это лавка чужой команды")
		return
	if world.economy.VENDORS[world.economy.vkind(vid)]["kind"] == "craft":
		open_craft(vid)
		return
	if _shop == null:
		_shop = preload("res://scripts/ui/shop_window.gd").new()
		_shop.setup(world)
		_root.add_child(_shop)
	_shop.open(vid)
	_shop.reset_size()
	var vp := get_viewport().get_visible_rect().size
	_shop.position = Vector2(12, (vp.y - _shop.size.y) * 0.5 - 40)   # левее: рядом открыто окно персонажа
	Sfx.play("ui_open")
	if _char_window == null or not _char_window.visible:
		toggle_character()

func shop_open() -> bool:
	return _shop != null and _shop.visible

## Окно «Мастер сборки» (сессия 13): сборка и улучшение вещей.
var _craft: Control

func open_craft(vid: String) -> void:
	if _craft == null:
		_craft = preload("res://scripts/ui/craft_window.gd").new()
		_craft.setup(world)
		_root.add_child(_craft)
	if _shop:
		_shop.visible = false
	_craft.open(vid)
	_craft.reset_size()
	var vp := get_viewport().get_visible_rect().size
	_craft.position = ((vp - _craft.size) * 0.5).floor()
	Sfx.play("ui_open")
	if _char_window and _char_window.visible:
		_char_window.visible = false       # сумка — в самом окне сборки

func craft_open() -> bool:
	return _craft != null and _craft.visible

## Окно Вербовщика («Война линий»): отправка врагов сопернику.
func open_sends(vid: String) -> void:
	if not world.mode.vendor_allowed(world.local_hero, vid):
		error("Это Вербовщик чужой команды")
		return
	if _sends == null:
		_sends = preload("res://scripts/ui/sends_window.gd").new()
		_sends.setup(world)
		_root.add_child(_sends)
	_sends.open(vid)
	_sends.reset_size()
	var vp := get_viewport().get_visible_rect().size
	_sends.position = Vector2(40, (vp.y - _sends.size.y) * 0.5 - 40)
	Sfx.play("ui_open")

# ---------------------------------------------------------------- обмен

var _trade_win: Control
var _hero_menu: PopupMenu
var _hero_menu_id := 0

func trade_open() -> bool:
	return _trade_win != null and _trade_win.visible

## ПКМ по союзнику (в мире, по рамке группы или цели): меню с «Обменом».
func hero_menu(hid: int, _at: Vector2 = Vector2.ZERO) -> void:
	if world.local_hero == null or hid == world.local_hero.hero_id or not world.heroes.has(hid):
		return
	if _hero_menu == null:
		_hero_menu = PopupMenu.new()
		_hero_menu.add_item("Обмен", 1)
		_hero_menu.add_item("Выбрать целью", 2)
		_hero_menu.add_item("Рейдовая метка…", 3)
		_hero_menu.id_pressed.connect(func(mid: int):
			if mid == 1:
				world.trade.send("request_open", [_hero_menu_id])
			elif mid == 2 and world.local_hero:
				world.local_hero.controller.target_id = _hero_menu_id
			elif mid == 3 and world.local_hero:
				world.local_hero.controller.target_id = _hero_menu_id
				_open_mark_menu.call_deferred(true))
		_root.add_child(_hero_menu)
	_hero_menu_id = hid
	_hero_menu.title = world.heroes[hid].player_name
	_hero_menu.position = Vector2i(get_viewport().get_mouse_position())
	_hero_menu.popup()

func on_trade_state(st: Dictionary) -> void:
	if _trade_win == null:
		_trade_win = preload("res://scripts/ui/trade_window.gd").new()
		_trade_win.setup(world)
		_root.add_child(_trade_win)
		_trade_win.visible = false
	var first: bool = not _trade_win.visible
	_trade_win.visible = true
	_trade_win.refresh(st)
	if first:
		_trade_win.reset_size()
		var vp := get_viewport().get_visible_rect().size
		_trade_win.position = Vector2(40, (vp.y - _trade_win.size.y) * 0.5 - 40)
		Sfx.play("ui_open")
		if _char_window == null or not _char_window.visible:
			toggle_character()
	if _char_window and _char_window.visible:
		_char_window.refresh()

func on_trade_closed(text: String, success: bool) -> void:
	if _trade_win:
		_trade_win.visible = false
	if success:
		error_info(text)
	else:
		error(text)
	if _char_window and _char_window.visible:
		_char_window.refresh()

func on_inventory_changed() -> void:
	# иконки кнопок аксессуаров на панели — по надетой вещи
	var lh = world.local_hero
	if lh and lh.controller and _slots.any(func(s): return s.has("use") and str(lh.equip.get(s["use"], "")) != str(s.get("use_id", ""))):
		rebuild_action_bar()
	if _char_window and _char_window.visible:
		_char_window.refresh()
	if _shop and _shop.visible:
		_shop.refresh()
	if _craft and _craft.visible:
		_craft.refresh()

func talents_open() -> bool:
	return _talent_window != null and _talent_window.visible

## Закрыть открытое окно (для Esc). true — если что-то закрыли.
func close_windows() -> bool:
	var closed := false
	if _edit_layer:
		set_edit_mode(false)
		closed = true
	for w in [_talent_window, _spellbook, _keybinds, _char_window, _shop, _sends, _craft, _settings_win, _menu, _help]:
		if w and w.visible:
			w.visible = false
			closed = true
	return closed

# ---------------------------------------------------------------- API

var _last_gold := 0
func toggle_menu() -> void:
	_menu.visible = not _menu.visible
	Sfx.play("ui_open" if _menu.visible else "ui_close")

func toggle_help() -> void:
	_help.visible = not _help.visible

func is_typing() -> bool:
	return _keybinds != null and _keybinds.visible

func announce(text: String, col: Color = GOLD) -> void:
	_announce.text = text
	_announce.add_theme_color_override("font_color", col)
	_announce_t = 4.0

func error(text: String) -> void:
	Sfx.play("ui_error")
	_error.text = text
	_error.add_theme_color_override("font_color", Color(1, 0.3, 0.25))
	_error_t = 1.6

## Сообщение-подсказка (золотое, не ошибка).
func error_info(text: String) -> void:
	_error.text = text
	_error.add_theme_color_override("font_color", GOLD)
	_error_t = 4.0

func show_game_over(victory: bool) -> void:
	game_over_shown = true
	Sfx.play("victory" if victory else "defeat")
	var r := _center_panel(420)
	var v: VBoxContainer = r[1]
	var t := _label("ПОБЕДА!" if victory else "ПОРАЖЕНИЕ", 34, GOLD if victory else Color(1, 0.35, 0.3))
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var d := _label(world.mode.game_over_details(victory), 17)
	d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(d)
	# итоги партии — те же данные, что в счётчике за всю партию
	var total: Dictionary = world.meter.view["total"]
	for m in [[1, "Урон"], [2, "Лечение"]]:
		var rows: Array = total["rows"].filter(func(row_): return float(row_[m[0]]) > 0.0)
		rows.sort_custom(func(a, b): return float(a[m[0]]) > float(b[m[0]]))
		if rows.is_empty():
			continue
		var parts: Array = []
		for row_ in rows.slice(0, 3):
			var hh = world.heroes.get(int(row_[0]), null)
			parts.append("%s %s" % [hh.player_name if hh else "?", MeterWindowScript.fmt(float(row_[m[0]]))])
		var sl := _label("%s: %s" % [m[1], ",  ".join(parts)], 14, Color(0.9, 0.9, 0.85))
		sl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(sl)
	_summary_box = GridContainer.new()
	_summary_box.columns = 6
	_summary_box.add_theme_constant_override("h_separation", 14)
	v.add_child(_summary_box)
	fill_summary()
	var b := Button.new()
	b.text = "В главное меню"
	b.pressed.connect(func(): Net.back_to_menu())
	v.add_child(b)

var _summary_box: GridContainer

## Окно итогов: урон, лечение, убийства, полученные вещи и уровень каждого героя; в «Походе» — уровень угрозы.
func fill_summary() -> void:
	if _summary_box == null or world.summary.is_empty():
		return
	for c in _summary_box.get_children():
		c.queue_free()
	var first: Array = world.summary[0]
	if first.size() > 8 and (first[8] as Dictionary).has("arena"):
		_fill_summary_arena()
		return
	if first.size() > 8 and (first[8] as Dictionary).has("team"):
		_fill_summary_lines()
		return
	_summary_box.columns = 6
	for head in ["Герой", "Урон", "Лечение", "Убито", "Вещей", "Уровень"]:
		_summary_box.add_child(_label(head, 13, GOLD))
	for row in world.summary:
		var col: Color = GameData.CLASSES.get(str(row[1]), {}).get("color", Color.WHITE)
		_summary_box.add_child(_label(str(row[0]), 14, col))
		_summary_box.add_child(_label(MeterWindowScript.fmt(float(row[2])), 14))
		_summary_box.add_child(_label(MeterWindowScript.fmt(float(row[3])), 14))
		_summary_box.add_child(_label(str(row[4]), 14))
		_summary_box.add_child(_label(str(row[5]), 14))
		_summary_box.add_child(_label(str(row[6]), 14))
	if world.summary_campaign:
		var l := _label("Поход: уровень угрозы теперь %d." % (world.summary.map(func(r): return int(r[7])).max()), 15, Color(1, 0.7, 0.4))
		_summary_box.get_parent().add_child(l)
		_summary_box.get_parent().move_child(l, _summary_box.get_index() + 1)

## Итоги «Войны линий»: по командам — урон, лечение, убийства, уровень, золото заработано и потрачено,
## отправлено врагов (кому — в подсказке) и сколько из них прорвалось к базе соперника.
func _fill_summary_lines() -> void:
	var L := GameData.LinesData
	_summary_box.columns = 9
	for head in ["Герой", "Урон", "Лечение", "Убито", "Уровень", "Золото +", "Потрачено", "Отправлено", "Прорвалось"]:
		_summary_box.add_child(_label(head, 13, GOLD))
	var rows: Array = world.summary.duplicate()
	rows.sort_custom(func(a, b): return int(a[8]["team"]) < int(b[8]["team"]))
	for row in rows:
		var ex: Dictionary = row[8]
		var team := clampi(int(ex["team"]), 0, 1)
		var nl := _label("%s%s" % ["★ " if int(ex.get("winner", -1)) == team else "", str(row[0])], 14, L.TEAMS[team]["color"])
		nl.tooltip_text = "%s, %s" % [L.TEAMS[team]["full"], GameData.CLASSES.get(str(row[1]), {}).get("name", "")]
		nl.mouse_filter = Control.MOUSE_FILTER_PASS
		_summary_box.add_child(nl)
		_summary_box.add_child(_label(MeterWindowScript.fmt(float(row[2])), 14))
		_summary_box.add_child(_label(MeterWindowScript.fmt(float(row[3])), 14))
		_summary_box.add_child(_label(str(row[4]), 14))
		_summary_box.add_child(_label(str(row[6]), 14))
		_summary_box.add_child(_label(str(int(ex["gold_in"])), 14, GOLD))
		_summary_box.add_child(_label(str(int(ex["gold_out"])), 14))
		var sl := _label(str(int(ex["sent_n"])), 14)
		var parts: Array = []
		for who in ex["sent"]:
			parts.append("%s — %d" % [who, int(ex["sent"][who])])
		sl.tooltip_text = "Кому: " + (", ".join(parts) if not parts.is_empty() else "никому")
		sl.mouse_filter = Control.MOUSE_FILTER_PASS
		_summary_box.add_child(sl)
		_summary_box.add_child(_label(str(int(ex["leaked"])), 14))

## Итоги Арены: по командам — убийства героев и смерти, урон по героям и по монстрам, лечение, дуэли,
## собранные вещи, томики, уровень, золото.
func _fill_summary_arena() -> void:
	var A := preload("res://scripts/data/arena_data.gd")
	_summary_box.columns = 11
	for head in ["Герой", "Убийства", "Смерти", "Урон по героям", "Урон по монстрам", "Лечение", "Дуэли", "Собрано", "Томики", "Уровень", "Золото +"]:
		_summary_box.add_child(_label(head, 13, GOLD))
	var rows: Array = world.summary.duplicate()
	rows.sort_custom(func(a, b): return int(a[8]["team"]) < int(b[8]["team"]))
	for row in rows:
		var ex: Dictionary = row[8]
		var team := clampi(int(ex["team"]), 0, 1)
		var nl := _label("%s%s" % ["★ " if int(ex.get("winner", -1)) == team else "", str(row[0])], 14, A.TEAMS[team]["color"])
		nl.tooltip_text = "%s, %s" % [A.TEAMS[team]["full"], GameData.CLASSES.get(str(row[1]), {}).get("name", "")]
		nl.mouse_filter = Control.MOUSE_FILTER_PASS
		_summary_box.add_child(nl)
		_summary_box.add_child(_label(str(int(ex["hero_kills"])), 14))
		_summary_box.add_child(_label(str(int(ex["deaths"])), 14))
		_summary_box.add_child(_label(MeterWindowScript.fmt(float(ex["hero_dmg"])), 14))
		_summary_box.add_child(_label(MeterWindowScript.fmt(float(ex["mob_dmg"])), 14))
		_summary_box.add_child(_label(MeterWindowScript.fmt(float(row[3])), 14))
		_summary_box.add_child(_label(str(int(ex["duels"])), 14))
		_summary_box.add_child(_label(str(int(ex["crafted"])), 14))
		_summary_box.add_child(_label(str(int(ex["tomes"])), 14))
		_summary_box.add_child(_label(str(row[6]), 14))
		_summary_box.add_child(_label(str(int(ex["gold_in"])), 14, GOLD))

func floating_number(u: Unit, amount: float, kind: String, school: String, crit: bool, on_me: bool) -> void:
	var text := str(int(round(amount)))
	var col: Color = GameData.SCHOOLS.get(school, GameData.SCHOOLS["physical"])["color"]
	match kind:
		"heal":
			if amount < 1.0:
				return
			text = "+" + text
			col = Color(0.4, 1.0, 0.4)
		"absorb":
			text = "Поглощено"
			col = Color(1, 1, 0.7)
		"block":
			text = "Блок (%s)" % text
			col = Color(0.85, 0.85, 0.95)
		"immune":
			text = "Невосприимчив"
			col = Color(1, 1, 0.7)
		"saved":
			text = "Спасён Оберегающим духом!"
			col = Color(1, 0.95, 0.6)
		"mana_burn":
			text = "-%s маны" % text
			col = Color(0.55, 0.45, 1.0)
		_:
			if on_me:
				col = Color(1, 0.25, 0.2)
				text = "-" + text
				Sfx.play("hurt", -2.0)
			elif school == "physical":
				Sfx.play_at("hit_bone", u.pos + Vector3(0, 1.2, 0))
	if crit:
		text += "!"
	var base := u.pos
	if u.node and is_instance_valid(u.node):
		base = u.node.global_position
	_numbers.append({"pos": base + Vector3(randf_range(-0.8, 0.8), 3.1 * (u.radius / 0.6 if u.kind == "mob" else 1.0), 0),
		"text": text, "color": col, "age": 0.0, "size": 30 if crit else 22, "drift": randf_range(-20, 20)})
	if _numbers.size() > 60:
		_numbers.pop_front()

## Короткая надпись над существом («Прервано!»).
func float_text(u: Unit, text: String, col: Color) -> void:
	var base := u.pos
	if u.node and is_instance_valid(u.node):
		base = u.node.global_position
	_numbers.append({"pos": base + Vector3(0, 3.6 * (u.radius / 0.6 if u.kind == "mob" else 1.0), 0),
		"text": text, "color": col, "age": 0.0, "size": 28, "drift": 0.0})

# ---------------------------------------------------------------- обновление

func _process(delta: float) -> void:
	var lh = world.local_hero
	if lh == null:
		return
	var c = lh.controller
	var t: float = world.now()

	_update_boss_bar()
	_update_pet(lh)
	# игрок
	_fill_frame(_player, lh.unit, "%s  •  %s" % [lh.player_name, GameData.CLASSES[lh.class_id]["name"]], lh.net_absorb)
	_player["level"].text = str(lh.unit.level)
	_player["portrait"].modulate = Color.WHITE if lh.alive_visual else Color(0.35, 0.35, 0.35)
	# цель
	var tu: Unit = world.get_unit(c.target_id)
	_target_frame["panel"].visible = tu != null or is_editing()
	if tu:
		var title := tu.display_name
		if tu.elite > 0:
			title = ("★ Чемпион: " if tu.elite == 2 else "★ ") + title
		if tu.kind == "mob" or lh.unit.is_enemy_of(tu):
			title += "  •  ур. %d" % tu.level
			if tu.sent_by != 0 and world.heroes.has(tu.sent_by):
				title += "  •  от игрока %s" % world.heroes[tu.sent_by].player_name      # «Линии»: отправленный враг
			_bar_color(_target_frame["hp"], Color(0.8, 0.15, 0.12))
		else:
			title += "  •  %d ур." % tu.level
			_bar_color(_target_frame["hp"], Color(0.2, 0.75, 0.25))
		var absorb := 0.0
		if tu.kind == "hero":
			absorb = world.heroes[tu.id].net_absorb
		_fill_frame(_target_frame, tu, title, absorb)
		# элитный: имя золотом, ниже — аффиксы
		(_target_frame["name"] as Label).add_theme_color_override("font_color", Color(1.0, 0.82, 0.25) if tu.elite > 0 else GOLD)
		var al: Label = _target_frame["affix"]
		al.visible = not tu.affixes.is_empty()
		al.text = ", ".join(tu.affixes.map(func(a): return GameData.AFFIXES[a]["name"]))
		al.tooltip_text = "
".join(tu.affixes.map(func(a): return "%s — %s" % [GameData.AFFIXES[a]["name"], GameData.AFFIXES[a]["desc"]]))
		_target_ring.visible = tu.alive
		var p := tu.pos
		if tu.node and is_instance_valid(tu.node):
			p = tu.node.global_position
		_target_ring.global_position = p + Vector3(0, 0.05, 0)
		var r := (tu.radius * 1.8 + 0.6) * (1.0 + 0.06 * sin(t * 6.0))
		_target_ring.scale = Vector3(r, 1, r)
		_target_ring.material_override = _ring_mat(world.local_hero != null and world.local_hero.unit.is_enemy_of(tu))
		_target_arrow.visible = tu.alive
		var head := 2.9 * (tu.radius / 0.6 if tu.kind == "mob" else 1.15)
		_target_arrow.global_position = p + Vector3(0, head + 0.25 * sin(t * 4.0), 0)
		_target_arrow.rotation.y = t * 2.0
		_target_arrow.material_override = _arrow_mat(world.local_hero != null and world.local_hero.unit.is_enemy_of(tu))
	else:
		_target_ring.visible = false
		_target_arrow.visible = false
	_update_target_effects(lh, c, tu, t)
	_update_marks(c, tu)
	_update_enemy_casts(tu, t)
	_update_elite_tags()
	# подсветка существа под курсором
	var hov: int = c.pick_unit(get_viewport().get_mouse_position()) if not c._dragged else 0
	if hover_unit_id != 0:
		hov = hover_unit_id     # курсор над рамкой группы — кольцо под этим союзником в мире
	var hu: Unit = world.get_unit(hov)
	_hover_ring.visible = hu != null and hov != c.target_id and hu.alive
	if _hover_ring.visible:
		var hp3 := hu.pos
		if hu.node and is_instance_valid(hu.node):
			hp3 = hu.node.global_position
		_hover_ring.global_position = hp3 + Vector3(0, 0.04, 0)
		var hr := hu.radius * 1.6 + 0.4
		_hover_ring.scale = Vector3(hr, 1, hr)
	# подсказка у торговца
	var near_v: String = world.economy.nearest_vendor(lh.global_position)
	_vendor_hint.visible = near_v != "" and not shop_open() and not (_sends != null and _sends.visible) and not (_craft != null and _craft.visible)
	# окно лавки закрывается, если отошли от её торговца (рядом могут стоять двое: кузнец и Мастер сборки)
	if _shop and _shop.visible and not world.economy.vendor_near(_shop.vendor, lh.global_position):
		_shop.visible = false
	if _sends and _sends.visible and not world.economy.vendor_near(_sends.vendor, lh.global_position):
		_sends.visible = false
	if _craft and _craft.visible and not world.economy.vendor_near(_craft.vendor, lh.global_position):
		_craft.visible = false

	# группа
	for hid in _party_frames:
		var f: Dictionary = _party_frames[hid]
		var h = world.heroes.get(hid, null)
		if h == null:
			continue
		var u: Unit = h.unit
		f["hp"].max_value = u.max_hp
		f["hp"].value = u.hp if h.alive_visual else 0.0
		f["mp"].max_value = maxf(1.0, u.max_mana)
		f["mp"].value = u.mana
		_bar_color(f["mp"], res_color(u.resource))
		(f["frame"] as Control).modulate = Color(0.55, 0.55, 0.55) if h.offline else Color.WHITE
		if h.offline:
			f["info"].text = "отключён"
		elif not h.alive_visual:
			f["info"].text = "Мёртв %d" % int(ceil(h.net_respawn_left))
		elif u.hp < u.max_hp - 0.5:
			f["info"].text = "-%d" % int(u.max_hp - u.hp)
		else:
			f["info"].text = ""
		var selected: bool = c.target_id == hid
		var hovered: bool = hover_unit_id == hid
		# выбранный союзник — яркая золотая обводка со свечением; под курсором — тоньше и голубая:
		# видно, кому уйдёт лечение «по наведению»
		var fst: StyleBoxFlat = f["style"]
		fst.border_color = GOLD if selected else (Color(0.45, 0.8, 1.0) if hovered else Color(0.25, 0.25, 0.25))
		fst.set_border_width_all(3 if selected else 2)
		fst.shadow_color = Color(1.0, 0.8, 0.3, 0.55) if selected else (Color(0.45, 0.8, 1.0, 0.35) if hovered else Color(0, 0, 0, 0))
		fst.shadow_size = 6 if selected else (4 if hovered else 0)
		_update_buff_icons(f["buffs"], h.net_buffs)
		if f.get("pet") != null:
			var pu: Unit = world.mobs.pet_of(hid)
			(f["pet"] as ProgressBar).value = pu.hp_frac() if pu else 0.0

	# панели заклинаний
	var procs: Array = []
	for b in lh.net_buffs:
		if GameData.PROC_BUFFS.has(b[0]):
			procs.append_array(GameData.PROC_BUFFS[b[0]]["spells"])
	var pulse := 0.5 + 0.5 * sin(t * 8.0)
	for s in _slots:
		var sid: String = s["sid"]
		if sid == "":
			continue
		if s.has("use"):
			var ueid := str(lh.equip.get(s["use"], ""))
			var use := GameData.ItemData.use_of(ueid)
			var uleft: float = float(lh.use_ready.get(use, 0.0)) - t if use != "" else 0.0
			var ucd: float = float(GameData.ItemData.ITEM_PROCS[use]["cd"]) if use != "" else 1.0
			(s["cd"].material as ShaderMaterial).set_shader_parameter("progress", clampf(uleft / ucd, 0.0, 1.0))
			s["cd_l"].text = str(int(ceil(uleft))) if uleft > 1.6 else ""
			s["slot"].modulate = Color(0.5, 0.5, 0.5) if use == "" else Color.WHITE
			continue
		if s.has("item"):
			var pleft: float = c.potion_until - t
			(s["cd"].material as ShaderMaterial).set_shader_parameter("progress", clampf(pleft / GameData.POTION_CD, 0.0, 1.0))
			var n: int = lh.bag_count(s["item"])
			s["count"].text = str(n)
			s["slot"].modulate = Color(0.5, 0.5, 0.5) if n <= 0 else Color.WHITE
			continue
		# своя перезарядка — тёмные «часы» с секундами; ГКД — светлая тень на всех ячейках, которые он держит
		var cd_left := float(c.cd_until.get(sid, 0.0)) - t
		var gcd_left: float = c.gcd_until - t
		var cd_frac := clampf(cd_left / maxf(GameData.eff_cd(lh.unit, sid), 0.01), 0.0, 1.0) if cd_left > 0.0 else 0.0
		var gcd_frac := clampf(gcd_left / GameData.GCD, 0.0, 1.0) if gcd_left > 0.0 and gcd_left >= cd_left and not GameData.SPELLS[sid].get("no_gcd", false) else 0.0
		(s["cd"].material as ShaderMaterial).set_shader_parameter("progress", cd_frac)
		(s["gcd"].material as ShaderMaterial).set_shader_parameter("progress", gcd_frac)
		s["cd_l"].text = str(int(ceil(cd_left))) if cd_left > 1.6 else ""
		var no_mana: bool = lh.unit.mana < GameData.eff_mana(lh.unit, sid)
		s["proc"].visible = procs.has(sid) and _opts["proc_border"]
		if procs.has(sid):
			# прок: бегущая рамка, а без неё — ячейка светится, как раньше
			s["slot"].modulate = Color(1.0 + 0.2 * pulse, 1.0 + 0.15 * pulse, 0.95) if _opts["proc_border"] else Color(1.0 + 0.6 * pulse, 1.0 + 0.45 * pulse, 0.6)
		else:
			s["slot"].modulate = Color(0.55, 0.6, 1.0) if no_mana else (Color(1.25, 1.25, 1.0) if c.aim_spell == sid else Color.WHITE)

	_update_proc_alert(lh, t)
	_update_meter_visibility()
	_buff_t -= delta
	if _buff_t <= 0.0:
		_buff_t = 0.25
		_update_buff_row(lh.net_buffs)
	var free_pts: int = lh.talent_points_free()
	var tk := Keys.label("talents")
	_talent_btn.text = "Таланты (%s)" % tk if free_pts <= 0 else "Таланты (%s)  +%d" % [tk, free_pts]
	_talent_btn.modulate = Color(1.3, 1.15, 0.6) if free_pts > 0 else Color.WHITE
	var book_new: bool = not preload("res://scripts/ui/spellbook.gd").pending_rows(world.local_hero).is_empty()
	_book_btn.text = _with_key("Книга", "spellbook") + ("  !" if book_new else "")
	_book_btn.modulate = Color(1.3, 1.15, 0.6).lerp(Color.WHITE, 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.008)) if book_new else Color.WHITE
	_char_btn.text = _with_key("Персонаж", "character")
	_meter_btn.text = _with_key("Счётчик", "meter")

	# полоса произнесения
	if c.cast_spell != "":
		_cast_bar["panel"].visible = true
		var prog := clampf((t - c.cast_start) / maxf(c.cast_duration, 0.01), 0.0, 1.0)
		if c.cast_channel:
			prog = 1.0 - prog
		_cast_bar["bar"].value = prog * 100.0
		_cast_bar["label"].text = "%s   %.1f" % [GameData.SPELLS[c.cast_spell]["name"], maxf(0.0, c.cast_duration - (t - c.cast_start))]
	else:
		_cast_bar["panel"].visible = is_editing()

	# опыт, золото, осада
	_xp_bar.max_value = maxf(1.0, lh.xp_next)
	_xp_bar.value = lh.xp
	_xp_label.text = "Уровень %d   —   опыт %d / %d" % [lh.unit.level, lh.xp, lh.xp_next] if lh.unit.level < GameData.MAX_LEVEL else "Максимальный уровень"
	_gold_label.text = "Золото: %d" % lh.gold
	if lh.gold != _last_gold:
		on_inventory_changed()
	if lh.gold > _last_gold:
		Sfx.play("coins")
	_last_gold = lh.gold
	var alive_mobs: int = world.mobs.alive_count() if Net.is_server() else world.mobs.client_alive_count
	var mp: Dictionary = world.mode.hud_panel(alive_mobs)
	_mode_title.text = mp["title"]
	_mode_bar.visible = mp["bar_visible"]
	_mode_bar.max_value = maxf(1.0, mp["bar_max"])
	_mode_bar.value = mp["bar"]
	_mode_bar_label.text = mp["bar_text"]
	if mp.has("bar_color"):
		_bar_color(_mode_bar, mp["bar_color"])
	_mode_bar2.visible = mp.has("bar2")
	if mp.has("bar2"):
		_mode_bar2.max_value = maxf(1.0, mp["bar2_max"])
		_mode_bar2.value = mp["bar2"]
		_mode_bar2_label.text = mp["bar2_text"]
		_bar_color(_mode_bar2, mp["bar2_color"])
	_skip_btn.text = mp["skip_text"]
	_skip_btn.visible = Net.is_server() and mp["can_skip"]

	_death_label.text = "Вы погибли. Воскрешение через %d сек." % int(ceil(lh.net_respawn_left)) if not lh.alive_visual else ""
	var lm_bb := world.mode as LinesMode
	_buyback_btn.visible = lm_bb != null and not lh.alive_visual and lh.net_respawn_left > 1.0 and not lm_bb.is_over()
	if _buyback_btn.visible:
		var bbp: int = GameData.LinesData.buyback_price(lh.unit.level)
		_buyback_btn.text = "Выкуп — %d золота" % bbp
		_buyback_btn.disabled = lh.gold < bbp

	if _announce_t > 0.0:
		_announce_t -= delta
		_announce.modulate.a = clampf(_announce_t, 0.0, 1.0)
	if _error_t > 0.0:
		_error_t -= delta
		_error.modulate.a = clampf(_error_t, 0.0, 1.0)

	if _edit_layer:
		_update_movers()

	for n in _numbers:
		n["age"] += delta
	_numbers = _numbers.filter(func(n): return n["age"] < 1.3)
	_overlay.queue_redraw()

var _ring_mats: Dictionary = {}
func _ring_mat(enemy: bool) -> ShaderMaterial:
	if not _ring_mats.has(enemy):
		var m := Vfx.ring_material(Color(1, 0.25, 0.15) if enemy else Color(0.3, 1, 0.4), 0.12, true, 2.2)
		_ring_mats[enemy] = m
	return _ring_mats[enemy]

var _arrow_mats: Dictionary = {}
func _arrow_mat(enemy: bool) -> StandardMaterial3D:
	if not _arrow_mats.has(enemy):
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(1, 0.3, 0.2) if enemy else Color(0.35, 1, 0.45)
		m.emission_enabled = true
		m.emission = m.albedo_color
		m.emission_energy_multiplier = 2.0
		_arrow_mats[enemy] = m
	return _arrow_mats[enemy]

func _fill_frame(f: Dictionary, u: Unit, title: String, absorb: float) -> void:
	f["name"].text = title
	f["hp"].max_value = u.max_hp
	f["hp"].value = u.hp
	var hp_text := "%d / %d" % [int(u.hp), int(u.max_hp)] if not u.kind in ["mob", "pet"] else "%d%%" % int(u.hp_frac() * 100.0)
	if absorb > 0.0:
		hp_text += "   (щит %d)" % int(absorb)
	f["hp_l"].text = hp_text
	f["mp"].visible = u.max_mana > 0.0
	f["mp"].max_value = maxf(1.0, u.max_mana)
	f["mp"].value = u.mana
	f["mp_l"].text = "%d / %d" % [int(u.mana), int(u.max_mana)]
	if u.resource == "energy":
		f["mp_l"].text += "     " + "●".repeat(u.combo) + "○".repeat(maxi(0, 5 - u.combo))      # приёмы серии разбойника
	_bar_color(f["mp"], res_color(u.resource))

func _update_buff_icons(box: HBoxContainer, buffs: Array) -> void:
	var want: Array = []
	for b in buffs:
		if GameData.BUFF_INFO.has(b[0]) and not want.has(b[0]):
			want.append(b[0])
	var key := ",".join(want)
	if box.get_meta("keys", "") == key:
		return
	box.set_meta("keys", key)
	for c in box.get_children():
		c.queue_free()
	for k in want:
		var cell := Control.new()
		cell.custom_minimum_size = Vector2(16, 16)
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(SpellIcon.make(GameData.BUFF_INFO[k]["icon"], 16))
		if GameData.BUFF_INFO[k].get("debuff", false):
			# дебафф на союзнике — красная окантовка
			var fr := Panel.new()
			var fs := StyleBoxFlat.new()
			fs.bg_color = Color(0, 0, 0, 0)
			fs.border_color = Color(1.0, 0.25, 0.2)
			fs.set_border_width_all(1)
			fr.add_theme_stylebox_override("panel", fs)
			fr.size = Vector2(16, 16)
			fr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			cell.add_child(fr)
		box.add_child(cell)

## Баффы своего героя под портретом: иконка + оставшееся время.
func _update_buff_row(buffs: Array) -> void:
	var list: Array = []
	for b in buffs:
		if GameData.BUFF_INFO.has(b[0]):
			list.append(b)
	var key := ",".join(list.map(func(b): return b[0]))
	if _buff_row.get_meta("keys", "") != key:
		_buff_row.set_meta("keys", key)
		for c in _buff_row.get_children():
			c.queue_free()
		for b in list:
			var cell := VBoxContainer.new()
			cell.add_theme_constant_override("separation", 0)
			cell.mouse_filter = Control.MOUSE_FILTER_PASS
			var icon_box := Control.new()
			icon_box.custom_minimum_size = Vector2(30, 30)
			icon_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon_box.add_child(SpellIcon.make(GameData.BUFF_INFO[b[0]]["icon"], 30))
			cell.add_child(icon_box)
			var tl := _label("", 11, Color(1, 1, 0.85))
			tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			tl.custom_minimum_size = Vector2(30, 14)
			cell.add_child(tl)
			_buff_row.add_child(cell)
	var i := 0
	for c in _buff_row.get_children():
		if c.is_queued_for_deletion() or i >= list.size():
			continue
		var left: float = list[i][1]
		var tl: Label = c.get_child(1)
		if left <= 0.0 or left > 3600.0 or GameData.BUFF_INFO[list[i][0]].get("no_timer", false):     # незаметность — до первого удара
			tl.text = ""
		elif left >= 60.0:
			tl.text = "%dм" % int(ceil(left / 60.0))
		else:
			tl.text = "%dс" % int(ceil(left))
		var binfo: Dictionary = GameData.BUFF_INFO[list[i][0]]
		c.tooltip_text = "%s\n%s" % [binfo["name"], str(binfo.get("desc", "")) if binfo.get("no_timer", false) else "Осталось: %s" % (tl.text if tl.text != "" else "пока внутри")]
		i += 1

## Полоски здоровья над врагами и всплывающие цифры — одним проходом рисования.
func _draw_overlay() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var c = world.local_hero.controller if world.local_hero else null
	for m in world.mobs.mobs.values():
		var u: Unit = m.unit
		var targeted: bool = c != null and c.target_id == u.id
		var boss: bool = m.def.get("boss", false)
		if u.hp >= u.max_hp - 0.5 and not targeted and not boss:
			continue
		var p: Vector3 = m.node.global_position + Vector3(0, 2.5 * float(m.def.get("scale", 1.0)), 0)
		if cam.is_position_behind(p) or cam.global_position.distance_squared_to(p) > 55.0 * 55.0:
			continue
		var sp := cam.unproject_position(p)
		var w := 90.0 if boss else 48.0
		var rect := Rect2(sp - Vector2(w * 0.5, 0), Vector2(w, 6 if not boss else 9))
		_overlay.draw_rect(rect.grow(1), Color(0, 0, 0, 0.8))
		_overlay.draw_rect(Rect2(rect.position, Vector2(w * u.hp_frac(), rect.size.y)), Color(0.85, 0.15, 0.1) if not targeted else Color(1, 0.35, 0.2))
		if boss or targeted:
			_overlay.draw_string_outline(_font, sp + Vector2(-w * 0.5, -6), u.display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 4, Color(0, 0, 0, 0.9))
			_overlay.draw_string(_font, sp + Vector2(-w * 0.5, -6), u.display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 0.85, 0.6))
	for n in _numbers:
		var p: Vector3 = n["pos"]
		if cam.is_position_behind(p):
			continue
		var age: float = n["age"]
		var sp := cam.unproject_position(p) + Vector2(n["drift"] * age, -50.0 * age)
		var col: Color = n["color"]
		col.a = clampf(1.6 - age * 1.3, 0.0, 1.0)
		var size := int(n["size"] * (1.0 + maxf(0.0, 0.25 - age) * 1.5))
		_overlay.draw_string_outline(_font, sp, n["text"], HORIZONTAL_ALIGNMENT_CENTER, -1, size, 5, Color(0, 0, 0, col.a * 0.9))
		_overlay.draw_string(_font, sp, n["text"], HORIZONTAL_ALIGNMENT_CENTER, -1, size, col)

# ---------------------------------------------------------------- эффекты на цели

## Эффекты на враге присылает сервер по просьбе request_watch (только для своей цели и при изменениях).
var _head_fx: HBoxContainer
var _watched_id := -1
var _tfx: Dictionary = {"uid": 0, "list": [], "t": 0.0}

func set_target_effects(uid: int, list: Array) -> void:
	if Net.cli.has("fxlog"):
		print("FX ", uid, " ", list)
	_tfx = {"uid": uid, "list": list, "t": world.now()}

## Эффекты цели с сервера (с тем, кто наложил): враги — мобы и вражеские герои; союзники — из снимка героев.
func _watch_kind(lh, tu: Unit) -> bool:
	return tu.kind == "mob" or ((tu.kind == "hero" or tu.kind == "pet") and lh.unit.is_enemy_of(tu))

func _update_target_effects(lh, c, tu: Unit, t: float) -> void:
	var tid: int = tu.id if tu else 0
	if tid != _watched_id:
		_watched_id = tid
		_tfx = {"uid": 0, "list": [], "t": t}
		world.spells.send_to_server("request_watch", [tid if tu and _watch_kind(lh, tu) else 0])
	var list: Array = []
	if tu and _watch_kind(lh, tu) and int(_tfx["uid"]) == tid:
		var dt: float = t - float(_tfx["t"])
		for e in _tfx["list"]:
			if float(e[1]) - dt > 0.0:
				list.append([e[0], float(e[1]) - dt, int(e[2]), int(e[3])])
	elif tu and tu.kind == "hero" and world.heroes.has(tid):
		for b in world.heroes[tid].net_buffs:
			list.append([b[0], float(b[1]), 0, 0])
	var mine: Array = list.filter(func(e): return e[2] == lh.hero_id)
	var other: Array = list.filter(func(e): return e[2] != lh.hero_id)
	_fill_fx_row(_target_frame["fx"], mine + other, lh.hero_id, true)
	# над головой цели — только свои эффекты, компактно
	var cam := get_viewport().get_camera_3d()
	_head_fx.visible = tu != null and tu.alive and not mine.is_empty() and cam != null
	if _head_fx.visible:
		var p := tu.pos
		if tu.node and is_instance_valid(tu.node):
			p = tu.node.global_position
		var head := 2.9 * (tu.radius / 0.6 if tu.kind == "mob" else 1.15) + 0.9
		var wp := p + Vector3(0, head, 0)
		if cam.is_position_behind(wp):
			_head_fx.visible = false
		else:
			_fill_fx_row(_head_fx, mine, lh.hero_id, false)
			_head_fx.reset_size()
			_head_fx.position = cam.unproject_position(wp) - Vector2(_head_fx.size.x * 0.5, _head_fx.size.y)

## Ряд иконок эффектов: свои крупнее и ярче, чужие мельче; время под иконкой, стаки сверху.
func _fill_fx_row(row: HBoxContainer, list: Array, my_id: int, detailed: bool) -> void:
	var known: Array = list.filter(func(e): return GameData.BUFF_INFO.has(e[0]))
	var key := ",".join(known.map(func(e): return "%s:%d:%d" % [e[0], 1 if e[2] == my_id else 0, e[3]]))
	if row.get_meta("keys", "") != key:
		row.set_meta("keys", key)
		for ch in row.get_children():
			ch.queue_free()
		for e in known:
			var info: Dictionary = GameData.BUFF_INFO[e[0]]
			var own: bool = e[2] == my_id
			var sz := (26.0 if own else 18.0) if detailed else 20.0
			var cell := Control.new()
			cell.custom_minimum_size = Vector2(sz, sz + (12.0 if detailed else 0.0))
			cell.mouse_filter = Control.MOUSE_FILTER_STOP if detailed else Control.MOUSE_FILTER_IGNORE
			var icon := SpellIcon.make(info["icon"], sz)
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon.modulate = Color.WHITE if own else Color(0.8, 0.8, 0.8, 0.8)
			cell.add_child(icon)
			if info.get("debuff", false):
				var frame := Panel.new()
				var st := StyleBoxFlat.new()
				st.bg_color = Color(0, 0, 0, 0)
				st.border_color = Color(1.0, 0.3, 0.2, 0.9) if own else Color(0.7, 0.25, 0.2, 0.7)
				st.set_border_width_all(2 if own else 1)
				frame.add_theme_stylebox_override("panel", st)
				frame.size = Vector2(sz, sz)
				frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
				cell.add_child(frame)
			var stacks := _label("", 11, Color.WHITE)
			stacks.add_theme_color_override("font_outline_color", Color.BLACK)
			stacks.add_theme_constant_override("outline_size", 4)
			stacks.position = Vector2(sz - 16, -3)
			if int(e[3]) > 0:
				stacks.text = "%d/3" % e[3] if e[0] == "chill" else str(e[3])
			cell.add_child(stacks)
			if detailed:
				var tl := _label("", 10, Color(1, 1, 1, 0.9))
				tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				tl.position = Vector2(0, sz)
				tl.size = Vector2(sz, 12)
				cell.add_child(tl)
				cell.set_meta("time", tl)
				cell.tooltip_text = "%s\n%s%s" % [info["name"], info.get("desc", ""), "\nВаш эффект" if own else ""]
			row.add_child(cell)
	# время обновляется каждый кадр без пересборки ряда
	if detailed:
		var i := 0
		for ch in row.get_children():
			if ch.is_queued_for_deletion() or i >= known.size():
				continue
			if ch.has_meta("time"):
				var left: float = known[i][1]
				(ch.get_meta("time") as Label).text = ("%d" % ceil(left)) if left < 600.0 else ""
			i += 1

# ---------------------------------------------------------------- рейдовые метки

var _mark_icons: Array = []        # 8 значков над головами
var _mark_menu: PopupMenu

func _open_mark_menu(marks_only: bool = false) -> void:
	var c = world.local_hero.controller if world.local_hero else null
	if c == null or c.target_id == 0:
		return
	if not marks_only and world.heroes.has(c.target_id) and c.target_id != world.local_hero.hero_id:
		hero_menu(c.target_id)      # в цели союзник — меню с «Обменом»
		return
	if _mark_menu == null:
		_mark_menu = PopupMenu.new()
		for i in world.marks.MARKS.size():
			var tex: Texture2D = world.marks.texture(i + 1)
			_mark_menu.add_icon_item(tex, "%s   (Ctrl+%d)" % [world.marks.MARKS[i]["name"], i + 1], i + 1)
			_mark_menu.set_item_icon_max_width(i, 20)
		_mark_menu.add_separator()
		_mark_menu.add_item("Снять метку", 0)
		_mark_menu.id_pressed.connect(func(idx: int):
			var cc = world.local_hero.controller
			if cc.target_id != 0:
				world.marks.send("request_mark", [cc.target_id, idx]))
		_root.add_child(_mark_menu)
	_mark_menu.position = Vector2i(get_viewport().get_mouse_position())
	_mark_menu.popup()

## Метки над головами всех помеченных существ и значок в рамке цели.
func _update_marks(c, tu: Unit) -> void:
	if _mark_icons.is_empty():
		for i in 8:
			var tr := TextureRect.new()
			tr.texture = world.marks.texture(i + 1)
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.size = Vector2(30, 30)
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			tr.visible = false
			_root.add_child(tr)
			_mark_icons.append(tr)
	var cam := get_viewport().get_camera_3d()
	for i in 8:
		var tr: TextureRect = _mark_icons[i]
		var uid := int(world.marks.marks.get(i + 1, 0))
		var u: Unit = world.get_unit(uid) if uid != 0 else null
		tr.visible = false
		if u == null or not u.alive or cam == null:
			continue
		var p := u.pos
		if u.node and is_instance_valid(u.node):
			p = u.node.global_position
		var head := 2.9 * (u.radius / 0.6 if u.kind == "mob" else 1.15) + 1.5
		var wp := p + Vector3(0, head, 0)
		if cam.is_position_behind(wp) or cam.global_position.distance_to(wp) > 90.0:
			continue
		var sp := cam.unproject_position(wp)
		tr.position = sp - tr.size * 0.5
		tr.visible = true
	var tm: TextureRect = _target_frame["mark"]
	var midx: int = world.marks.mark_of(tu.id) if tu else 0
	tm.visible = midx != 0
	if midx != 0:
		tm.texture = world.marks.texture(midx)

# ---------------------------------------------------------------- касты врагов
## Полоса произнесения врага: жёлтая — можно сбить, серая со щитом — нельзя (как в WoW).
## В рамке цели и компактно над головами ближайших кастующих мобов.

var _head_casts: Array = []

func _make_enemy_cast_bar(w: float, h: float, font: int) -> Control:
	var root := Control.new()
	root.custom_minimum_size = Vector2(w, h)
	root.size = Vector2(w, h)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.visible = false
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.6)
	bg.size = Vector2(w, h)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)
	var fill := ColorRect.new()
	fill.size = Vector2(0, h)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(fill)
	var l := _label("", font, Color.WHITE)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size = Vector2(w, h)
	root.add_child(l)
	root.set_meta("fill", fill)
	root.set_meta("label", l)
	root.set_meta("w", w)
	return root

func _fill_enemy_cast(bar: Control, cdata: Dictionary, t: float, with_time: bool) -> void:
	var ab: Dictionary = GameData.MOB_ABILITIES.get(cdata["ab"], {})
	if cdata.has("sid"):
		ab = GameData.SPELLS.get(cdata["sid"], {})       # каст героя (бой героев)
	var frac := clampf((t - float(cdata["start"])) / maxf(float(cdata["dur"]), 0.01), 0.0, 1.0)
	var fill: ColorRect = bar.get_meta("fill")
	var can: bool = cdata["interrupt"]
	fill.color = Color(1.0, 0.78, 0.15, 0.9) if can else Color(0.55, 0.55, 0.6, 0.9)
	fill.size.x = float(bar.get_meta("w")) * frac
	var text: String = ab.get("name", "?")
	if not can:
		text = "🛡 " + text
	if with_time:
		text += "   %.1f" % maxf(0.0, float(cdata["dur"]) - (t - float(cdata["start"])))
	(bar.get_meta("label") as Label).text = text
	bar.visible = true

func _update_enemy_casts(tu: Unit, t: float) -> void:
	var casts: Dictionary = world.mobs.casts
	var tbar: Control = _target_frame["ecast"]
	var lu: Unit = world.local_hero.unit if world.local_hero else null
	if tu and casts.has(tu.id) and (tu.kind != "hero" or (lu and lu.is_enemy_of(tu))):
		_fill_enemy_cast(tbar, casts[tu.id], t, true)
	else:
		tbar.visible = false
	if _head_casts.is_empty():
		for i in 6:
			var b := _make_enemy_cast_bar(120.0, 12.0, 10)
			_root.add_child(b)
			_head_casts.append(b)
	var cam := get_viewport().get_camera_3d()
	var list: Array = []
	if cam:
		for id in casts:
			var u: Unit = world.get_unit(id)
			if u == null or not u.alive or (u.kind == "hero" and (lu == null or not lu.is_enemy_of(u))):
				continue      # над головой — только касты врагов (свои и союзные — на рамках)
			var p := u.pos
			if u.node and is_instance_valid(u.node):
				p = u.node.global_position
			var wp := p + Vector3(0, 2.9 * (u.radius / 0.6) + 0.6, 0)
			var d := cam.global_position.distance_to(wp)
			if d < 50.0 and not cam.is_position_behind(wp):
				list.append([d, id, wp])
	list.sort_custom(func(a, b): return a[0] < b[0])
	for i in _head_casts.size():
		var b: Control = _head_casts[i]
		if i >= list.size():
			b.visible = false
			continue
		_fill_enemy_cast(b, casts[list[i][1]], t, false)
		b.position = cam.unproject_position(list[i][2]) - Vector2(60, 6)

## Подписи над ближайшими элитными: «★ Имя» и аффиксы золотом.
var _elite_tags: Array = []

func _update_elite_tags() -> void:
	if _elite_tags.is_empty():
		for i in 6:
			var l := _label("", 13, Color(1.0, 0.82, 0.25))
			l.add_theme_color_override("font_outline_color", Color.BLACK)
			l.add_theme_constant_override("outline_size", 5)
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			l.size = Vector2(240, 36)
			l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			l.visible = false
			_root.add_child(l)
			_elite_tags.append(l)
	var cam := get_viewport().get_camera_3d()
	var list: Array = []
	if cam:
		for u: Unit in world.units.values():
			if u.kind != "mob" or u.elite == 0 or not u.alive:
				continue
			var p := u.pos
			if u.node and is_instance_valid(u.node):
				p = u.node.global_position
			var wp := p + Vector3(0, 2.9 * (u.radius / 0.6) + 1.1, 0)
			var d := cam.global_position.distance_to(wp)
			if d < 45.0 and not cam.is_position_behind(wp):
				list.append([d, u, wp])
	list.sort_custom(func(a, b): return a[0] < b[0])
	for i in _elite_tags.size():
		var l: Label = _elite_tags[i]
		l.visible = i < list.size()
		if not l.visible:
			continue
		var u: Unit = list[i][1]
		l.text = "★ %s\n%s" % [u.display_name, ", ".join(u.affixes.map(func(a): return GameData.AFFIXES[a]["name"]))]
		l.position = cam.unproject_position(list[i][2]) - Vector2(120, 36)

## Книга заклинаний: выбор изменился (окно книги перерисуется, когда появится).
func on_choices_changed() -> void:
	Sfx.play("ui_learn")
	world.local_hero.controller.sync_bar()
	rebuild_action_bar()
	if _spellbook and _spellbook.visible:
		_spellbook.refresh()

# ---------------------------------------------------------------- полоса босса
## Крупная полоса вверху по центру: имя, здоровье, метки порогов фаз, текущая фаза и щит;
## в подсказке — механики босса из boss_data.gd. Видна, пока на поле есть босс.
var _boss_panel: PanelContainer
var _boss_name: Label
var _boss_bar: ProgressBar
var _boss_info: Label
var _boss_marks: Control
var _boss_shown := 0

func _build_boss_bar() -> void:
	_boss_panel = PanelContainer.new()
	_boss_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.85, 0.35, 0.2)))
	_boss_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_boss_panel.position = Vector2(-260, 2)
	_boss_panel.custom_minimum_size = Vector2(520, 0)
	_boss_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_boss_panel.visible = false
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_panel.add_child(v)
	_boss_name = _label("", 18, Color(1, 0.8, 0.55))
	_boss_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_boss_name)
	_boss_bar = _bar(Color(0.8, 0.15, 0.1), 18)
	_boss_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_boss_bar)
	_boss_marks = Control.new()
	_boss_marks.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_marks.set_anchors_preset(Control.PRESET_FULL_RECT)
	_boss_bar.add_child(_boss_marks)
	_boss_info = _label("", 13, Color(0.9, 0.85, 0.75))
	_boss_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_boss_info)
	_root.add_child(_boss_panel)

func _update_boss_bar() -> void:
	var bm = null
	for m in world.mobs.mobs.values():
		if GameData.BOSSES.has(m.unit.type_id) and m.unit.alive:
			if not world.mode.show_boss_bar(world.local_hero, m.unit):
				continue      # «Линии» — только своей линии, Арена — только рядом
			bm = m
			break
	_boss_panel.visible = bm != null
	if bm == null:
		_boss_shown = 0
		return
	var u: Unit = bm.unit
	var bd: Dictionary = GameData.BOSSES[u.type_id]
	var st: Dictionary = world.mobs.boss_state.get(u.id, {})
	if _boss_shown != u.id:
		_boss_shown = u.id
		_boss_name.text = ("★ " if bd["rank"] == "main" else "") + u.display_name
		var tip := "Механики:
• " + "
• ".join(PackedStringArray(bd.get("mechanics", [])))
		for uid in bd.get("loot", []):
			tip += "
Добыча: " + str(GameData.ItemData.UNIQUES[uid]["name"])
		_boss_panel.tooltip_text = tip
		for c in _boss_marks.get_children():
			c.queue_free()
		for ph in bd["phases"]:
			if float(ph["hp"]) < 1.0:
				var mk := ColorRect.new()
				mk.color = Color(1, 0.9, 0.5, 0.9)
				mk.mouse_filter = Control.MOUSE_FILTER_IGNORE
				mk.anchor_left = float(ph["hp"])
				mk.anchor_right = float(ph["hp"])
				mk.anchor_bottom = 1.0
				mk.offset_right = 2.0
				_boss_marks.add_child(mk)
	_boss_bar.max_value = u.max_hp
	_boss_bar.value = u.hp
	var info := "%d%%" % int(u.hp_frac() * 100.0)
	var phases: Array = bd["phases"]
	if phases.size() > 1:
		info += "   •   фаза %d из %d" % [int(st.get("phase", 0)) + 1, phases.size()]
	if st.get("shield", false):
		info += "   •   НЕУЯЗВИМ — разбейте филактерии!"
	_boss_info.text = info + "   •   наведите — механики"

# ---------------------------------------------------------------- питомец охотника (сессия 06)

## Цвет полосы ресурса: ярость — красная, концентрация — оранжевая, мана — синяя.
static func res_color(res: String) -> Color:
	match res:
		"rage": return Color(0.85, 0.15, 0.12)
		"focus": return Color(0.95, 0.6, 0.15)
		"energy": return Color(0.95, 0.85, 0.2)
	return Color(0.2, 0.4, 0.95)

var _pet_frame: Dictionary = {}
var _pet_btns: Dictionary = {}       # команда/режим/вид -> Button

const PET_BTNS := [
	["kind:pet_wolf", "Волк", "pet_howl", "Волк — урон. Вой ускоряет группу.\nВыбрать для следующего Призыва питомца."],
	["kind:pet_bear", "Медведь", "pet_growl", "Медведь — танк. Рык заставляет врагов бить его.\nВыбрать для следующего Призыва питомца."],
	["kind:pet_cat", "Кошка", "pet_pounce", "Кошка — рывок к цели и кровотечение.\nВыбрать для следующего Призыва питомца."],
	["aggressive", "Агрессия", "", "Агрессивный: сам нападает на врагов рядом с охотником."],
	["defensive", "Защита", "", "Защитный: бьёт цель охотника и тех, кто напал на охотника или питомца."],
	["passive", "Пассив", "", "Пассивный: не нападает сам, только по команде «Атака»."],
	["attack", "Атака", "", "Атаковать текущую цель охотника."],
	["follow", "К ноге", "", "Бросить бой и идти за охотником."],
	["stay", "Стоять", "", "Стоять на месте (бьёт только по команде)."],
]

func _build_pet_frames() -> void:
	# рамка питомца — под рамкой героя
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_style())
	_frame("pet", p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	v.custom_minimum_size = Vector2(200, 0)
	p.add_child(v)
	var name_l := _label("", 13, GOLD)
	v.add_child(name_l)
	var hp := _bar(Color(0.2, 0.75, 0.25), 14)
	v.add_child(hp)
	var hp_l := _label("", 11)
	hp_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_l.set_anchors_preset(Control.PRESET_FULL_RECT)
	hp.add_child(hp_l)
	_pet_frame = {"panel": p, "name": name_l, "hp": hp, "hp_l": hp_l}
	# панель питомца — над панелью 1: вид, режим, команды
	var bp := PanelContainer.new()
	bp.add_theme_stylebox_override("panel", _panel_style(Color(0.4, 0.35, 0.25), Color(0, 0, 0, 0.55)))
	_frame("petbar", bp)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 3)
	bp.add_child(h)
	for i in PET_BTNS.size():
		var d: Array = PET_BTNS[i]
		if i == 3 or i == 6:
			h.add_child(VSeparator.new())
		var b := Button.new()
		b.text = d[1]
		b.toggle_mode = i < 6
		b.tooltip_text = d[3]
		b.add_theme_font_size_override("font_size", 12)
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_filter = Control.MOUSE_FILTER_STOP
		if d[2] != "":
			b.icon = load("res://assets/icons/spells/%s.svg" % d[2])
			b.expand_icon = false
			b.add_theme_constant_override("icon_max_width", 18)
		var cmd: String = d[0]
		b.pressed.connect(func(): _pet_button(cmd))
		h.add_child(b)
		_pet_btns[cmd] = b
	bp.mouse_filter = Control.MOUSE_FILTER_STOP

func _pet_button(cmd: String) -> void:
	var lh = world.local_hero
	if lh == null:
		return
	var arg: int = lh.controller.target_id if cmd == "attack" else 0
	world.mobs.send_pet(cmd, arg)
	Sfx.play("ui_click")

func _update_pet(lh) -> void:
	var hunter: bool = lh.class_id == "hunter"
	_frames["petbar"].visible = hunter
	var pu: Unit = world.mobs.pet_of(lh.hero_id) if hunter else null
	_frames["pet"].visible = hunter and (pu != null or world.mobs.my_pet.get("dead", false) or is_editing())
	if not hunter:
		return
	var st: Dictionary = world.mobs.my_pet
	for cmd in _pet_btns:
		var b: Button = _pet_btns[cmd]
		if b.toggle_mode:
			b.set_pressed_no_signal(cmd == "kind:" + str(st.get("kind", "")) or cmd == str(st.get("mode", "")))
	var kind_name: String = GameData.MOBS.get(str(st.get("kind", "pet_wolf")), {}).get("name", "Питомец")
	if pu:
		_pet_frame["name"].text = "%s  •  %d ур.  •  %s" % [pu.display_name, lh.unit.level, {"follow": "к ноге", "stay": "стоит", "attack": "атакует"}.get(str(st.get("cmd", "")), "")]
		_pet_frame["hp"].max_value = 1.0
		_pet_frame["hp"].value = pu.hp_frac()
		_pet_frame["hp_l"].text = "%d%%" % int(pu.hp_frac() * 100.0)
	else:
		_pet_frame["name"].text = "%s погиб — Воскрешение питомца" % kind_name if st.get("dead", false) else kind_name
		_pet_frame["hp"].value = 0.0
		_pet_frame["hp_l"].text = ""

## «Война линий»: обзор линий — мини-карта с видом сверху и подвижной камерой (scripts/ui/lane_view.gd).
var _lane_view: Control

func _build_lane_view() -> void:
	if not (world.mode is LinesMode):
		return
	_lane_view = preload("res://scripts/ui/lane_view.gd").new()
	_lane_view.setup(world)
	_frame("lanes", _lane_view)
