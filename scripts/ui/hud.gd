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

var world: Node3D
var hover_unit_id := 0
var game_over_shown := false

var _font: Font
var _root: Control
var _overlay: Control
var _frames: Dictionary = {}           # id -> Control (подвижные рамки)
var _frame_titles := {"player": "Мой герой", "target": "Цель", "party": "Группа", "bar1": "Панель 1",
	"bar2": "Панель 2", "cast": "Полоса произнесения", "siege": "Осада"}
var _layout_pos: Dictionary = {}       # id -> Vector2 (сохранённое)
var _opts := {"party_horizontal": false, "bar2_vertical": false}

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
var _talent_window: Control
var _spellbook: Control
var _keybinds: Control
var _cast_bar: Dictionary
var _xp_bar: ProgressBar
var _xp_label: Label
var _wave_label: Label
var _castle_bar: ProgressBar
var _castle_label: Label
var _gold_label: Label
var _announce: Label
var _announce_t := 0.0
var _error: Label
var _error_t := 0.0
var _death_label: Label
var _menu: PanelContainer
var _help: PanelContainer
var _target_ring: MeshInstance3D
var _numbers: Array = []               # {pos, text, color, age, size, drift}
var _drag_from := Vector2i(-1, -1)     # (панель, ячейка), откуда тащат заклинание

func setup(w: Node3D) -> void:
	world = w
	layer = 5
	_font = _make_font()
	var theme := Theme.new()
	theme.default_font = _font
	theme.default_font_size = 15
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
	_build_siege()
	_build_messages()
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
	rebuild_party()
	Keys.changed.connect(rebuild_action_bar)
	get_viewport().size_changed.connect(_apply_layout)
	_apply_layout.call_deferred()

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
	var name_l := _label("", 16, GOLD)
	v.add_child(name_l)
	_target_frame = _hp_mp(v, 22, 12)
	_target_frame.merge({"name": name_l, "panel": p})

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
					world.local_hero.controller.target_id = hid)
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
		_party_frames[hid] = {"frame": frame, "style": st, "hp": hp, "mp": mp, "info": info, "buffs": buffs, "name": nl}

func party_order() -> Array:
	var ids: Array = world.heroes.keys()
	ids.sort()
	if world.local_hero:
		ids.erase(world.local_hero.hero_id)
		ids.push_front(world.local_hero.hero_id)
	return ids

# ---------------------------------------------------------------- панели заклинаний

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
	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", 4)
	row.add_child(side)
	_talent_btn = Button.new()
	_talent_btn.text = "Таланты"
	_talent_btn.custom_minimum_size = Vector2(150, 27)
	_talent_btn.pressed.connect(toggle_talents)
	side.add_child(_talent_btn)
	var book_btn := Button.new()
	book_btn.text = "Книга"
	book_btn.custom_minimum_size = Vector2(150, 27)
	book_btn.pressed.connect(toggle_spellbook)
	side.add_child(book_btn)
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
	else:
		var sp: Dictionary = GameData.SPELLS[sid]
		var col: Color = GameData.SCHOOLS[sp["school"]]["color"]
		st.bg_color = col.darkened(0.55)
		st.border_color = GOLD if sp.get("talent", false) else col.lightened(0.1)
		var icon := SpellIcon.make(sid, SLOT - 4)
		icon.position = Vector2(2, 2)
		slot.add_child(icon)
		var cd := ColorRect.new()
		cd.color = Color(0, 0, 0, 0.65)
		cd.position = Vector2(2, 2)
		cd.size = Vector2(SLOT - 4, 0)
		cd.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(cd)
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
		entry.merge({"cd": cd, "cd_l": cd_l, "icon": icon, "lock": lock})
	var key := _label(Keys.short_label("bar%d_%d" % [b + 1, i]), 12, Color(1, 1, 1, 0.9))
	key.position = Vector2(5, 1)
	slot.add_child(key)
	_slots.append(entry)

func _slot_drag(_at: Vector2, b: int, i: int, slot: Control) -> Variant:
	var sid: String = world.local_hero.controller.bars[b][i]
	if sid == "":
		return null
	_drag_from = Vector2i(b, i)
	slot.set_drag_preview(SpellIcon.make(sid, 50))
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
			s["slot"].tooltip_text = "Пустая ячейка — перетащите сюда заклинание из книги"
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

func _build_siege() -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_style())
	p.custom_minimum_size = Vector2(380, 0)
	_frame("siege", p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	p.add_child(v)
	_wave_label = _label("", 16, GOLD)
	_wave_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_wave_label)
	_castle_bar = _bar(Color(0.3, 0.55, 0.95), 18)
	v.add_child(_castle_bar)
	_castle_label = _label("", 12)
	_castle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_castle_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_castle_bar.add_child(_castle_label)
	_gold_label = _label("", 15, GOLD)
	_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_gold_label)
	_skip_btn = Button.new()
	_skip_btn.text = "Начать волну сейчас"
	_skip_btn.visible = false
	_skip_btn.pressed.connect(func(): world.waves.skip_break())
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
	var vol_row := HBoxContainer.new()
	v.add_child(vol_row)
	vol_row.add_child(_label("Громкость", 15))
	var vol := HSlider.new()
	vol.min_value = 0.0
	vol.max_value = 1.0
	vol.step = 0.05
	vol.value = Sfx.load_volume()
	vol.custom_minimum_size = Vector2(180, 24)
	vol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vol.value_changed.connect(func(x: float):
		Sfx.set_volume(x)
		Sfx.save_volume(x))
	vol_row.add_child(vol)
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
	for k in _opts:
		_opts[k] = cfg.get_value("opt", k, _opts[k])

func _save_layout() -> void:
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
		"party": return Vector2(16, 175)
		"siege": return Vector2(vp.x - size.x - 16, 12)
		"bar1": return Vector2((vp.x - size.x) * 0.5 + 80, bar1_y)
		"bar2":
			if _opts["bar2_vertical"]:
				return Vector2(vp.x - size.x - 16, (vp.y - size.y) * 0.5)
			return Vector2((vp.x - BAR_SLOTS * (SLOT + SLOT_GAP)) * 0.5 + 80, bar1_y - size.y - 8)
		"cast": return Vector2((vp.x - size.x) * 0.5, vp.y - 250)
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
	_opts = {"party_horizontal": false, "bar2_vertical": false}
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
	b_done.text = "Готово"
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

func toggle_keybinds() -> void:
	if _keybinds == null:
		_keybinds = preload("res://scripts/ui/keybind_window.gd").new()
		_root.add_child(_keybinds)
		_keybinds.visible = false
	_keybinds.visible = not _keybinds.visible
	Sfx.play("ui_open" if _keybinds.visible else "ui_close")

func talents_open() -> bool:
	return _talent_window != null and _talent_window.visible

## Закрыть открытое окно (для Esc). true — если что-то закрыли.
func close_windows() -> bool:
	var closed := false
	if _edit_layer:
		set_edit_mode(false)
		closed = true
	for w in [_talent_window, _spellbook, _keybinds, _menu, _help]:
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
	var d := _label("Все волны отбиты (%d). Замок выстоял!" % world.wave_count if victory else "Замок пал на волне %d." % world.wave, 17)
	d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(d)
	var b := Button.new()
	b.text = "В главное меню"
	b.pressed.connect(func(): Net.back_to_menu())
	v.add_child(b)

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
		"immune":
			text = "Невосприимчив"
			col = Color(1, 1, 0.7)
		"saved":
			text = "Спасён Оберегающим духом!"
			col = Color(1, 0.95, 0.6)
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

# ---------------------------------------------------------------- обновление

func _process(delta: float) -> void:
	var lh = world.local_hero
	if lh == null:
		return
	var c = lh.controller
	var t: float = world.now()

	# игрок
	_fill_frame(_player, lh.unit, "%s  •  %s" % [lh.player_name, GameData.CLASSES[lh.class_id]["name"]], lh.net_absorb)
	_player["level"].text = str(lh.unit.level)
	_player["portrait"].modulate = Color.WHITE if lh.alive_visual else Color(0.35, 0.35, 0.35)
	# цель
	var tu: Unit = world.get_unit(c.target_id)
	_target_frame["panel"].visible = tu != null or is_editing()
	if tu:
		var title := tu.display_name
		if tu.kind == "mob":
			title += "  •  ур. %d" % tu.level
			_bar_color(_target_frame["hp"], Color(0.8, 0.15, 0.12))
		else:
			title += "  •  %d ур." % tu.level
			_bar_color(_target_frame["hp"], Color(0.2, 0.75, 0.25))
		var absorb := 0.0
		if tu.kind == "hero":
			absorb = world.heroes[tu.id].net_absorb
		_fill_frame(_target_frame, tu, title, absorb)
		_target_ring.visible = tu.alive
		var p := tu.pos
		if tu.node and is_instance_valid(tu.node):
			p = tu.node.global_position
		_target_ring.global_position = p + Vector3(0, 0.05, 0)
		var r := tu.radius * 1.8 + 0.4
		_target_ring.scale = Vector3(r, 1, r)
		_target_ring.material_override = _ring_mat(tu.team == Unit.Team.ENEMIES)
	else:
		_target_ring.visible = false

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
		if not h.alive_visual:
			f["info"].text = "Мёртв %d" % int(ceil(h.net_respawn_left))
		elif u.hp < u.max_hp - 0.5:
			f["info"].text = "-%d" % int(u.max_hp - u.hp)
		else:
			f["info"].text = ""
		var selected: bool = c.target_id == hid
		var hovered: bool = hover_unit_id == hid
		f["style"].border_color = GOLD if selected else (Color(0.8, 0.8, 0.8) if hovered else Color(0.25, 0.25, 0.25))
		_update_buff_icons(f["buffs"], h.net_buffs)

	# панели заклинаний
	for s in _slots:
		var sid: String = s["sid"]
		if sid == "":
			continue
		var until := maxf(float(c.cd_until.get(sid, 0.0)), c.gcd_until)
		var total := GameData.eff_cd(lh.unit, sid) if t < float(c.cd_until.get(sid, 0.0)) else GameData.GCD
		var left := until - t
		var inner := SLOT - 4
		if left > 0.0:
			var frac := clampf(left / maxf(total, 0.01), 0.0, 1.0)
			s["cd"].size = Vector2(inner, inner * frac)
			s["cd"].position = Vector2(2, 2 + inner * (1.0 - frac))
			s["cd_l"].text = str(int(ceil(left))) if left > 1.6 else ""
		else:
			s["cd"].size = Vector2(inner, 0)
			s["cd_l"].text = ""
		var no_mana: bool = lh.unit.mana < GameData.eff_mana(lh.unit, sid)
		s["slot"].modulate = Color(0.55, 0.6, 1.0) if no_mana else (Color(1.25, 1.25, 1.0) if c.aim_spell == sid else Color.WHITE)

	_buff_t -= delta
	if _buff_t <= 0.0:
		_buff_t = 0.25
		_update_buff_row(lh.net_buffs)
	var free_pts: int = lh.talent_points_free()
	var tk := Keys.label("talents")
	_talent_btn.text = "Таланты (%s)" % tk if free_pts <= 0 else "Таланты (%s)  +%d" % [tk, free_pts]
	_talent_btn.modulate = Color(1.3, 1.15, 0.6) if free_pts > 0 else Color.WHITE

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
	if lh.gold > _last_gold:
		Sfx.play("coins")
	_last_gold = lh.gold
	var wave_text := "Подготовка" if world.wave == 0 else "Волна %d / %d" % [world.wave, world.wave_count]
	if world.game_state == "clearing":
		wave_text += "   •   добейте врагов — затем передышка"
	elif world.game_state == "break":
		wave_text = "Передышка   •   волна %d через %d сек." % [world.wave + 1, int(ceil(world.next_wave_in))]
	elif world.next_wave_in > 0.0:
		wave_text += "   •   следующая через %d сек." % int(ceil(world.next_wave_in))
	_skip_btn.visible = Net.is_server() and (world.game_state == "break" or world.game_state == "prep")
	_wave_label.text = wave_text
	_castle_bar.max_value = world.castle.max_hp
	_castle_bar.value = world.castle.hp
	var alive_mobs: int = world.mobs.alive_count() if Net.is_server() else world.mobs.client_alive_count
	_castle_label.text = "Замок: %d / %d      Врагов: %d" % [int(world.castle.hp), int(world.castle.max_hp), alive_mobs]

	_death_label.text = "Вы погибли. Воскрешение через %d сек." % int(ceil(lh.net_respawn_left)) if not lh.alive_visual else ""

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
		_ring_mats[enemy] = Vfx.ring_material(Color(1, 0.25, 0.15) if enemy else Color(0.3, 1, 0.4), 0.0, false, 1.5)
	return _ring_mats[enemy]

func _fill_frame(f: Dictionary, u: Unit, title: String, absorb: float) -> void:
	f["name"].text = title
	f["hp"].max_value = u.max_hp
	f["hp"].value = u.hp
	var hp_text := "%d / %d" % [int(u.hp), int(u.max_hp)] if u.kind != "mob" else "%d%%" % int(u.hp_frac() * 100.0)
	if absorb > 0.0:
		hp_text += "   (щит %d)" % int(absorb)
	f["hp_l"].text = hp_text
	f["mp"].visible = u.max_mana > 0.0
	f["mp"].max_value = maxf(1.0, u.max_mana)
	f["mp"].value = u.mana
	f["mp_l"].text = "%d / %d" % [int(u.mana), int(u.max_mana)]

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
		if left <= 0.0:
			tl.text = ""
		elif left >= 60.0:
			tl.text = "%dм" % int(ceil(left / 60.0))
		else:
			tl.text = "%dс" % int(ceil(left))
		c.tooltip_text = "%s\nОсталось: %s" % [GameData.BUFF_INFO[list[i][0]]["name"], tl.text if tl.text != "" else "пока внутри"]
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
