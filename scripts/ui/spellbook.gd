extends CenterContainer
## Книга заклинаний (клавиша P): все заклинания героя.
## Перетащите заклинание на панель внизу, чтобы назначить его на клавишу.

const GOLD := Color(0.95, 0.78, 0.35)

var world: Node3D
var _grid: GridContainer

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
	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", 18)
	_grid.add_theme_constant_override("v_separation", 8)
	v.add_child(_grid)
	var hint := Label.new()
	hint.text = "Перетащите заклинание на любую из двух панелей.  Чтобы убрать с панели — утащите его за её пределы."
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.65))
	v.add_child(hint)

func refresh() -> void:
	for c in _grid.get_children():
		c.queue_free()
	var hero = world.local_hero
	for sid in hero.spell_list():
		var sp: Dictionary = GameData.SPELLS[sid]
		var open: bool = hero.unit.level >= GameData.spell_level(sid)
		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(300, 52)
		row.add_theme_constant_override("separation", 10)
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.tooltip_text = SpellIcon.tooltip(sid, hero.unit)
		row.set_drag_forwarding(func(_at: Vector2) -> Variant:
			row.set_drag_preview(SpellIcon.make(sid, 50))
			return {"type": "spell", "sid": sid, "from": -1}, Callable(), Callable())
		_grid.add_child(row)
		var icon_holder := Control.new()
		icon_holder.custom_minimum_size = Vector2(48, 48)
		icon_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(icon_holder)
		var icon := SpellIcon.make(sid, 48)
		icon.modulate = Color.WHITE if open else Color(0.4, 0.4, 0.4)
		icon_holder.add_child(icon)
		var text := VBoxContainer.new()
		text.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(text)
		var n := Label.new()
		n.text = sp["name"]
		n.add_theme_font_size_override("font_size", 16)
		n.add_theme_color_override("font_color", GOLD if sp.get("talent", false) else Color.WHITE)
		text.add_child(n)
		var sub := Label.new()
		sub.text = GameData.SCHOOLS[sp["school"]]["name"] + ("" if open else "   •   откроется на %d ур." % GameData.spell_level(sid))
		sub.add_theme_font_size_override("font_size", 12)
		sub.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
		text.add_child(sub)
