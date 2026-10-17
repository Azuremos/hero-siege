extends PanelContainer
## Окно обмена (как в WoW): слева — что отдаёте вы, справа — что предлагает союзник.
## Положить вещь: ПКМ по ней в сумке или перетащить на свою сторону. Убрать — ЛКМ по ячейке обмена.
## Любое изменение сбрасывает подтверждения обоих; обмен проходит, когда «Обменять» нажали оба.

const GOLD := Color(0.95, 0.78, 0.35)
const CELL := 46.0

var world: Node3D
var _title: Label
var _mine: GridContainer
var _theirs: GridContainer
var _my_gold: SpinBox
var _their_gold: Label
var _my_ok: Label
var _their_ok: Label
var _accept: Button
var _quiet := false        # не слать предложение, пока окно само выставляет золото

func setup(w: Node3D) -> void:
	world = w
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.05, 0.045, 0.07, 0.96)
	st.border_color = GOLD
	st.set_border_width_all(2)
	st.set_corner_radius_all(8)
	st.set_content_margin_all(12)
	add_theme_stylebox_override("panel", st)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	add_child(v)
	_title = _lbl("Обмен", 19, GOLD)
	v.add_child(_title)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 22)
	v.add_child(h)
	var left := _column(h, "Вы отдаёте")
	_mine = left[0]
	_my_ok = left[1]
	var gl := HBoxContainer.new()
	gl.add_child(_lbl("Золото:", 14, GOLD))
	_my_gold = SpinBox.new()
	_my_gold.min_value = 0
	_my_gold.step = 1
	_my_gold.custom_minimum_size = Vector2(110, 0)
	_my_gold.value_changed.connect(func(val: float):
		if not _quiet:
			world.trade.set_gold(int(val)))
	gl.add_child(_my_gold)
	left[2].add_child(gl)
	var right := _column(h, "Вы получаете")
	_theirs = right[0]
	_their_ok = right[1]
	_their_gold = _lbl("Золото: 0", 14, GOLD)
	right[2].add_child(_their_gold)
	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_END
	btns.add_theme_constant_override("separation", 10)
	v.add_child(btns)
	_accept = Button.new()
	_accept.text = "  Обменять  "
	_accept.pressed.connect(func(): world.trade.send("request_accept", []))
	btns.add_child(_accept)
	var cancel := Button.new()
	cancel.text = "  Отмена  "
	cancel.pressed.connect(func(): world.trade.send("request_cancel", []))
	btns.add_child(cancel)
	v.add_child(_lbl("ПКМ по вещи в сумке или перетаскивание — положить в обмен, ЛКМ здесь — убрать.\nЛюбое изменение снимает подтверждения.", 12, Color(1, 1, 1, 0.6)))

func _lbl(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l

## Колонка: заголовок, 6 ячеек (3×2), отметка «готов», место под золото. [сетка, отметка, контейнер]
func _column(parent: Control, title: String) -> Array:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	parent.add_child(col)
	col.add_child(_lbl(title, 15, Color(0.9, 0.9, 0.85)))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	col.add_child(grid)
	var ok := _lbl("", 14, Color(0.4, 1.0, 0.4))
	col.add_child(ok)
	var extra := VBoxContainer.new()
	col.add_child(extra)
	return [grid, ok, extra]

func _cell(id: String, n: int) -> Panel:
	var p := Panel.new()
	RichTip.attach(p)
	p.custom_minimum_size = Vector2(CELL, CELL)
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0, 0, 0, 0.55)
	st.border_color = GameData.item_color(id) if id != "" else Color(0.35, 0.32, 0.25)
	st.set_border_width_all(2)
	st.set_corner_radius_all(5)
	p.add_theme_stylebox_override("panel", st)
	if id != "":
		var icon := SpellIcon.make_item(id, CELL - 4)
		icon.position = Vector2(2, 2)
		p.add_child(icon)
		p.tooltip_text = GameData.item_tooltip(id)
		if n > 1:
			var l := _lbl(str(n), 13, Color.WHITE)
			l.position = Vector2(CELL - 20, CELL - 20)
			p.add_child(l)
	return p

func refresh(st: Dictionary) -> void:
	if world.local_hero:
		GameData.tooltip_equip = world.local_hero.equip      # вещи партнёра — сравнение со своим снаряжением
	var partner = world.heroes.get(int(st["partner"]), null)
	_title.text = "Обмен с героем %s" % (partner.player_name if partner else "?")
	for c in _mine.get_children():
		c.queue_free()
	for c in _theirs.get_children():
		c.queue_free()
	for i in world.trade.MAX_ITEMS:
		var mine: Array = st["mine"]
		var cell := _cell(str(mine[i][0]) if i < mine.size() else "", int(mine[i][1]) if i < mine.size() else 0)
		if i < st["slots"].size():
			var bag_idx: int = st["slots"][i]
			cell.gui_input.connect(func(ev: InputEvent):
				if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
					world.trade.toggle_slot(bag_idx))
		cell.set_drag_forwarding(Callable(), _can_drop, _drop)
		_mine.add_child(cell)
		var theirs: Array = st["theirs"]
		_theirs.add_child(_cell(str(theirs[i][0]) if i < theirs.size() else "", int(theirs[i][1]) if i < theirs.size() else 0))
	_quiet = true
	_my_gold.max_value = maxf(0.0, float(world.local_hero.gold))
	_my_gold.value = int(st["my_gold"])
	_quiet = false
	_their_gold.text = "Золото: %d" % int(st["their_gold"])
	_my_ok.text = "✓ Вы готовы" if st["my_ok"] else ""
	_their_ok.text = "✓ Союзник готов" if st["their_ok"] else ""
	_accept.disabled = bool(st["my_ok"])

func _can_drop(_at: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.has("bag")

func _drop(_at: Vector2, data: Variant) -> void:
	var idx := int(data["bag"])
	if not world.trade.state.is_empty() and not world.trade.state["slots"].has(idx):
		world.trade.toggle_slot(idx)
