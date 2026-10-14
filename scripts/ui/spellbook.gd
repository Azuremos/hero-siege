extends CenterContainer
## Книга заклинаний (клавиша P): базовые заклинания героя и ряды выбора по уровням.
## В каждом ряду — три варианта, щелчок выбирает (бесплатно, но только вне боя: сервер проверит).
## Перетащите заклинание на панель внизу, чтобы назначить его на клавишу.

const GOLD := Color(0.95, 0.78, 0.35)

var world: Node3D
var _grid: GridContainer
var _rows: VBoxContainer
var _pulse: Array = []        # метки «Новый выбор!» — мигают в _process

func setup(w: Node3D) -> void:
	world = w
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel := PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.06, 0.05, 0.04, 0.96)
	st.border_color = GOLD
	st.set_border_width_all(2)
	st.set_corner_radius_all(8)
	st.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", st)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var title := Label.new()
	title.text = "Книга заклинаний"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", GOLD)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close := Button.new()
	close.text = "  ✕  "
	close.pressed.connect(func(): visible = false)
	head.add_child(close)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(960, 560)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	scroll.add_child(body)
	body.add_child(_caption("Базовые заклинания"))
	_grid = GridContainer.new()
	_grid.columns = 3
	_grid.add_theme_constant_override("h_separation", 12)
	_grid.add_theme_constant_override("v_separation", 6)
	body.add_child(_grid)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 6)
	body.add_child(_rows)
	var hint := Label.new()
	hint.text = "Щелчок по варианту — выбрать (вне боя: до волн, в передышке или через 5 сек. без боя).  Перетащите заклинание на панель, чтобы назначить клавишу."
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.65))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(960, 0)
	v.add_child(hint)

func _caption(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	l.add_theme_color_override("font_color", GOLD)
	return l

func _process(_dt: float) -> void:
	if not visible or _pulse.is_empty():
		return
	var a := 0.55 + 0.45 * sin(Time.get_ticks_msec() * 0.008)
	for l in _pulse:
		if is_instance_valid(l):
			l.modulate.a = a

## Ряды, открытые по уровню, где игрок ещё ни разу не выбирал сам (для «Новый выбор!»).
static func pending_rows(hero) -> Array:
	var out: Array = []
	if hero == null or not GameData.BOOKS.has(hero.class_id):
		return out
	var rows: Array = GameData.BOOKS[hero.class_id]["rows"]
	for i in rows.size():
		if hero.unit.level >= int(rows[i]["level"]) and not hero.choices.has(i):
			out.append(i)
	return out

func refresh() -> void:
	for c in _grid.get_children():
		c.queue_free()
	for c in _rows.get_children():
		c.queue_free()
	_pulse.clear()
	var hero = world.local_hero
	if not GameData.BOOKS.has(hero.class_id):
		for sid in hero.spell_list():
			_grid.add_child(_spell_cell(sid, hero, false, false))
		return
	var book: Dictionary = GameData.BOOKS[hero.class_id]
	for sid in book["base"] + GameData.talent_spells(hero.class_id, hero.talents):
		_grid.add_child(_spell_cell(sid, hero, false, false))
	var pending := pending_rows(hero)
	for i in book["rows"].size():
		var r: Dictionary = book["rows"][i]
		var open: bool = hero.unit.level >= int(r["level"])
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 10)
		_rows.add_child(line)
		var cap := VBoxContainer.new()
		cap.custom_minimum_size = Vector2(150, 0)
		line.add_child(cap)
		var lv := Label.new()
		lv.text = "%d уровень" % int(r["level"])
		lv.add_theme_font_size_override("font_size", 15)
		lv.add_theme_color_override("font_color", GOLD if open else Color(0.55, 0.55, 0.55))
		cap.add_child(lv)
		var nm := Label.new()
		nm.text = r["name"]
		nm.add_theme_font_size_override("font_size", 12)
		nm.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
		cap.add_child(nm)
		if pending.has(i):
			var nw := Label.new()
			nw.text = "Новый выбор!"
			nw.add_theme_font_size_override("font_size", 13)
			nw.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
			cap.add_child(nw)
			_pulse.append(nw)
		var chosen := GameData.book_choice(hero.class_id, i, hero.choices)
		for sid in r["options"]:
			var cell := _spell_cell(sid, hero, true, sid == chosen)
			if open and sid != chosen:
				var row_i: int = i
				var pick: String = sid
				cell.gui_input.connect(func(ev: InputEvent):
					if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
						Sfx.play("ui_click")
						world.spells.send_to_server("request_choose", [row_i, pick]))
			if not open:
				cell.modulate = Color(0.5, 0.5, 0.5)
			line.add_child(cell)

## Ячейка заклинания. В рядах выбранный вариант в золотой рамке; перетаскивать можно только
## открытое активное заклинание, которое сейчас есть у героя.
func _spell_cell(sid: String, hero, in_row: bool, chosen: bool) -> Control:
	var sp: Dictionary = GameData.SPELLS[sid]
	var open: bool = hero.unit.level >= GameData.spell_level(sid)
	var passive: bool = sp.get("passive", false)
	var frame := PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.16, 0.13, 0.08, 0.9) if chosen else Color(0.1, 0.09, 0.08, 0.6)
	st.border_color = GOLD if chosen else Color(0.3, 0.27, 0.22)
	st.set_border_width_all(2 if chosen else 1)
	st.set_corner_radius_all(5)
	st.set_content_margin_all(4)
	frame.add_theme_stylebox_override("panel", st)
	frame.custom_minimum_size = Vector2(250, 52)
	frame.mouse_filter = Control.MOUSE_FILTER_STOP
	var tip := SpellIcon.tooltip(sid, hero.unit) if not passive else "%s\n%s" % [sp["name"], sp["desc"]]
	if in_row and not chosen and open:
		tip = "Щелчок — выбрать\n\n" + tip
	frame.tooltip_text = tip
	if open and not passive and (not in_row or chosen):
		frame.set_drag_forwarding(func(_at: Vector2) -> Variant:
			frame.set_drag_preview(SpellIcon.make(sid, 50))
			return {"type": "spell", "sid": sid, "from": -1}, Callable(), Callable())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(row)
	var icon_holder := Control.new()
	icon_holder.custom_minimum_size = Vector2(44, 44)
	icon_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon_holder)
	var icon := SpellIcon.make(sid, 44)
	icon.modulate = Color.WHITE if open else Color(0.4, 0.4, 0.4)
	icon_holder.add_child(icon)
	var text := VBoxContainer.new()
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.add_theme_constant_override("separation", 0)
	row.add_child(text)
	var n := Label.new()
	n.text = sp["name"]
	n.add_theme_font_size_override("font_size", 15)
	n.add_theme_color_override("font_color", GOLD if sp.get("talent", false) or chosen else Color.WHITE)
	text.add_child(n)
	var sub := Label.new()
	var parts: Array = [GameData.SCHOOLS[sp["school"]]["name"]]
	if passive:
		parts.append("пассивно")
	elif float(sp.get("cd", 0.0)) > 0.0:
		parts.append("%d сек." % int(sp["cd"]))
	if not open and not in_row:
		parts.append("откроется на %d ур." % GameData.spell_level(sid))
	sub.text = "   •   ".join(parts)
	sub.add_theme_font_size_override("font_size", 12)
	sub.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	text.add_child(sub)
	return frame
