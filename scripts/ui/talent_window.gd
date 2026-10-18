extends CenterContainer
## Окно талантов (клавиша N) в стиле WotLK: три ветки, ряды открываются за вложенные очки.
## ЛКМ по таланту — изучить ранг. В игре изменения проверяет хост.
## Из главного меню окно открывается в режиме просмотра: можно спланировать раскладку на 30 уровне.

const GOLD := Color(0.95, 0.78, 0.35)
const CELL := 56.0
const GAP := 14.0
const COLS := 4
const ROWS := 5

var world: Node3D
var _title: Label
var _trees_box: HBoxContainer
var _cells: Dictionary = {}       # tid -> {panel, style, rank, icon, tree, t}
var _tree_labels: Array = []
var _preview := false
var _class_id := ""
var _plan: Dictionary = {}        # таланты в режиме просмотра

## Режим просмотра (главное меню): без героя, 30 уровень, изменения только на экране.
func setup_preview(class_id: String) -> void:
	_preview = true
	_class_id = class_id
	setup(null)

func _cls() -> String:
	return _class_id if _preview else world.local_hero.class_id

func _ranks() -> Dictionary:
	return _plan if _preview else world.local_hero.talents

func _level() -> int:
	return GameData.MAX_LEVEL if _preview else world.local_hero.unit.level

func _learn(tid: String) -> void:
	if _preview:
		if GameData.can_learn(_class_id, _plan, GameData.MAX_LEVEL, tid) == "":
			_plan[tid] = int(_plan.get(tid, 0)) + 1
			_plan_order.append(tid)      # порядок вкачки — для заготовки
			Sfx.play("ui_learn")
		refresh()
	else:
		world.spells.send_to_server("request_learn", [tid])

func _reset() -> void:
	if _preview:
		_plan.clear()
		_plan_order.clear()
		refresh()
	else:
		world.spells.send_to_server("request_reset_talents", [])

func setup(w: Node3D) -> void:
	world = w
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel := PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.05, 0.045, 0.07, 0.96)
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
	_title = _label("", 20, GOLD)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	var reset := Button.new()
	reset.text = "Сбросить таланты"
	reset.pressed.connect(_reset)
	head.add_child(reset)
	var close := Button.new()
	close.text = "  ✕  "
	close.pressed.connect(func(): visible = false)
	head.add_child(close)

	_trees_box = HBoxContainer.new()
	_trees_box.add_theme_constant_override("separation", 12)
	v.add_child(_trees_box)
	var hint := _label("ЛКМ — изучить ранг.  Каждый ряд открывается после %d очков в ветке.  Таланты с иконкой заклинания дают новое заклинание." % GameData.TalentData.POINTS_PER_ROW, 13, Color(1, 1, 1, 0.65))
	v.add_child(hint)
	_build_trees()
	if _preview and GameData.BOOKS.has(_class_id):
		_book_box = HBoxContainer.new()
		_book_box.add_theme_constant_override("separation", 8)
		v.add_child(_label("Книга заклинаний — выберите вариант в каждом ряду (ЛКМ):", 15, GOLD))
		v.add_child(_book_box)
		_build_book()
	if _preview:
		_build_builds_row(v)

func _label(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 4)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _build_trees() -> void:
	var cls := _cls()
	var trees: Array = GameData.talent_trees(cls)
	for ti in trees.size():
		var tree: Dictionary = trees[ti]
		var col: Color = tree["color"]
		var box := PanelContainer.new()
		var st := StyleBoxFlat.new()
		st.bg_color = col.darkened(0.85)
		st.bg_color.a = 0.9
		st.border_color = col.darkened(0.3)
		st.set_border_width_all(1)
		st.set_corner_radius_all(6)
		st.set_content_margin_all(10)
		box.add_theme_stylebox_override("panel", st)
		_trees_box.add_child(box)
		var v := VBoxContainer.new()
		box.add_child(v)
		var name_l := _label(tree["name"], 18, col.lightened(0.3))
		name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(name_l)
		_tree_labels.append(name_l)
		var grid := Control.new()
		grid.custom_minimum_size = Vector2(COLS * CELL + (COLS - 1) * GAP, ROWS * CELL + (ROWS - 1) * GAP + 6)
		grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		v.add_child(grid)
		# сдвиг, чтобы занятые колонки стояли по центру ветки
		var min_c := COLS
		var max_c := 0
		for tt in tree["talents"]:
			min_c = mini(min_c, int(tt["col"]))
			max_c = maxi(max_c, int(tt["col"]))
		var shift := (float(COLS - 1) - float(min_c + max_c)) * 0.5 * (CELL + GAP)
		# стрелки требований (рисуем до ячеек, чтобы были под ними)
		for t in tree["talents"]:
			if t.has("req"):
				var req := GameData.find_talent(cls, t["req"])
				var rt: Dictionary = req["t"]
				var x: float = rt["col"] * (CELL + GAP) + CELL * 0.5 - 2 + shift
				var y0: float = rt["row"] * (CELL + GAP) + CELL
				var y1: float = t["row"] * (CELL + GAP)
				var line := ColorRect.new()
				line.color = col.darkened(0.2)
				line.position = Vector2(x, y0)
				line.size = Vector2(4, y1 - y0)
				line.mouse_filter = Control.MOUSE_FILTER_IGNORE
				grid.add_child(line)
		for t in tree["talents"]:
			var cell := Panel.new()
			cell.position = Vector2(t["col"] * (CELL + GAP) + shift, t["row"] * (CELL + GAP))
			cell.size = Vector2(CELL, CELL)
			var cs := StyleBoxFlat.new()
			cs.bg_color = Color(0, 0, 0, 0.7)
			cs.set_border_width_all(2)
			cs.set_corner_radius_all(6)
			cell.add_theme_stylebox_override("panel", cs)
			cell.mouse_filter = Control.MOUSE_FILTER_STOP
			var tid: String = t["id"]
			cell.gui_input.connect(func(ev: InputEvent):
				if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
					_learn(tid))
			if t.has("spell") and not _preview:
				# изученный талант-заклинание можно перетащить на панель
				var tsid: String = t["spell"]
				cell.set_drag_forwarding(func(_at: Vector2) -> Variant:
					if int(_ranks().get(tid, 0)) <= 0:
						return null
					cell.set_drag_preview(SpellIcon.make(tsid, 50))
					return {"type": "spell", "sid": tsid, "from": -1}, Callable(), Callable())
			grid.add_child(cell)
			var icon := SpellIcon.make_talent(t, col, CELL - 6)
			icon.position = Vector2(3, 3)
			cell.add_child(icon)
			var rank := _label("", 13, Color.WHITE)
			rank.position = Vector2(CELL - 34, CELL - 20)
			rank.size = Vector2(32, 18)
			rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			cell.add_child(rank)
			# талант на заклинание ряда книги закрыт до уровня ряда: замок и уровень
			var lock := _label("", 12, Color(1, 0.85, 0.5))
			lock.position = Vector2(2, 2)
			lock.size = Vector2(CELL - 4, CELL - 4)
			lock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lock.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			lock.add_theme_color_override("font_outline_color", Color.BLACK)
			lock.add_theme_constant_override("outline_size", 4)
			cell.add_child(lock)
			_cells[tid] = {"panel": cell, "style": cs, "rank": rank, "icon": icon, "tree": ti, "t": t, "lock": lock}

func refresh() -> void:
	if not _preview and (world == null or world.local_hero == null):
		return
	if _preview and _book_box:
		_refresh_book()
	var cls := _cls()
	var ranks: Dictionary = _ranks()
	var level := _level()
	var free: int = GameData.talent_points_total(level) - GameData.talent_points_spent(ranks)
	if _preview:
		_title.text = "Таланты — %s (просмотр, %d ур.)     Свободных очков: %d" % [GameData.CLASSES[cls]["name"], level, free]
	else:
		_title.text = "Таланты — %s %d ур.     Свободных очков: %d" % [GameData.CLASSES[cls]["name"], level, free]
	var trees: Array = GameData.talent_trees(cls)
	for ti in trees.size():
		_tree_labels[ti].text = "%s  (%d)" % [trees[ti]["name"], GameData.tree_points(cls, ranks, ti)]
	for tid in _cells:
		var c: Dictionary = _cells[tid]
		var t: Dictionary = c["t"]
		var r := int(ranks.get(tid, 0))
		var mx := int(t["max"])
		var err: String = GameData.can_learn(cls, ranks, level, tid)
		var tree_ok: bool = GameData.tree_points(cls, ranks, c["tree"]) >= int(t["row"]) * GameData.TalentData.POINTS_PER_ROW
		c["rank"].text = "%d/%d" % [r, mx]
		var style: StyleBoxFlat = c["style"]
		if r >= mx:
			style.border_color = GOLD
			c["rank"].add_theme_color_override("font_color", GOLD)
			c["icon"].modulate = Color.WHITE
		elif err == "":
			style.border_color = Color(0.3, 0.95, 0.35)
			c["rank"].add_theme_color_override("font_color", Color(0.4, 1, 0.4))
			c["icon"].modulate = Color.WHITE
		elif r > 0 or tree_ok:
			style.border_color = Color(0.55, 0.55, 0.55)
			c["rank"].add_theme_color_override("font_color", Color.WHITE)
			c["icon"].modulate = Color(0.8, 0.8, 0.8)
		else:
			style.border_color = Color(0.25, 0.25, 0.25)
			c["rank"].add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
			c["icon"].modulate = Color(0.35, 0.35, 0.35)
		var need_lvl := GameData.talent_level(cls, t)
		var locked := level < need_lvl
		c["lock"].text = "🔒\n%d ур." % need_lvl if locked else ""
		if locked:
			c["icon"].modulate = Color(0.3, 0.3, 0.3)
		c["panel"].tooltip_text = _tooltip(t, r, err)
func _tooltip(t: Dictionary, r: int, err: String) -> String:
	var lines := ["%s   (ранг %d/%d)" % [t["name"], r, int(t["max"])]]
	# талант ряда книги: усиливает то, что выбрано в ряду, — показываем ряд и выбранный вариант
	var cls := _cls()
	var row := GameData.talent_book_row(cls, t)
	if row >= 0:
		var rd: Dictionary = GameData.BOOKS[cls]["rows"][row]
		var chosen := GameData.book_choice(cls, row, _choices())
		lines.append("Ваше заклинание ряда «%s» (%d ур.)%s" % [rd["name"], int(rd["level"]),
			(" — сейчас: %s" % GameData.SPELLS[chosen]["name"]) if chosen != "" else ""])
		if _level() < int(rd["level"]):
			lines.append("✗ Доступно с %d уровня" % int(rd["level"]))
	if r > 0:
		lines.append(GameData.talent_desc(t, r))
	if r < int(t["max"]):
		if r > 0:
			lines.append("")
			lines.append("Следующий ранг:")
		lines.append(GameData.talent_desc(t, r + 1))
	if t.has("spell"):
		lines.append("")
		lines.append(SpellIcon.tooltip(t["spell"]))
	if err != "" and r < int(t["max"]):
		lines.append("")
		lines.append("✗ " + err)
	return "\n".join(lines)

# ---------------------------------------------------------------- книга в режиме просмотра

var _book_box: HBoxContainer
var _plan_choices: Dictionary = {}    # ряд -> id (просмотр из главного меню)
var _book_cells: Array = []           # [ряд, id, панель, стиль]

## Выбор книги: в просмотре — план, в игре — выбор героя.
func _choices() -> Dictionary:
	return _plan_choices if _preview else world.local_hero.choices

## Ряды книги в столбик: уровень, название и три варианта; выбранный — в золотой рамке.
func _build_book() -> void:
	var rows: Array = GameData.BOOKS[_class_id]["rows"]
	for i in rows.size():
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 3)
		_book_box.add_child(col)
		var head := _label("%d ур.\n%s" % [int(rows[i]["level"]), rows[i]["name"]], 11, Color(1, 1, 1, 0.8))
		head.custom_minimum_size = Vector2(96, 30)
		head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		col.add_child(head)
		var icons := HBoxContainer.new()
		icons.add_theme_constant_override("separation", 2)
		col.add_child(icons)
		for sid in rows[i]["options"]:
			var p := Panel.new()
			p.custom_minimum_size = Vector2(32, 32)
			var ps := StyleBoxFlat.new()
			ps.bg_color = Color(0, 0, 0, 0.6)
			ps.set_border_width_all(2)
			p.add_theme_stylebox_override("panel", ps)
			p.tooltip_text = SpellIcon.tooltip(sid)
			var ic := SpellIcon.make(sid, 28)
			ic.position = Vector2(2, 2)
			p.add_child(ic)
			var row_i: int = i
			var pick: String = sid
			p.gui_input.connect(func(ev: InputEvent):
				if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
					_plan_choices[row_i] = pick
					Sfx.play("ui_learn")
					refresh())
			icons.add_child(p)
			_book_cells.append([i, sid, p, ps])

func _refresh_book() -> void:
	for c in _book_cells:
		var chosen := GameData.book_choice(_class_id, c[0], _plan_choices)
		var on: bool = chosen == c[1]
		(c[3] as StyleBoxFlat).border_color = GOLD if on else Color(0.25, 0.25, 0.25)
		(c[2] as Control).modulate = Color.WHITE if on else Color(0.55, 0.55, 0.55)

# ---------------------------------------------------------------- заготовки (просмотр из главного меню)

var _plan_order: Array = []          # таланты в порядке вкачки (id повторяется по рангам)
var _build_name: LineEdit
var _build_list: OptionButton

## Ряд «Заготовка»: сохранить план (таланты в порядке вкачки + выбор в книге) под именем, загрузить, удалить.
## Выбранная на экране героя заготовка в игре изучается сама.
func _build_builds_row(v: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)
	row.add_child(_label("Заготовка:", 15, GOLD))
	_build_name = LineEdit.new()
	_build_name.placeholder_text = "Название, например «Огонь»"
	_build_name.custom_minimum_size = Vector2(220, 0)
	row.add_child(_build_name)
	var save := Button.new()
	save.text = "Сохранить"
	save.tooltip_text = "Сохранить таланты (в порядке, в котором вы их вкачали) и выбор в книге.\nНа экране выбора героя выберите заготовку — в игре она изучится сама."
	save.pressed.connect(_save_build)
	row.add_child(save)
	row.add_child(VSeparator.new())
	_build_list = OptionButton.new()
	_build_list.custom_minimum_size = Vector2(200, 0)
	row.add_child(_build_list)
	var load_b := Button.new()
	load_b.text = "Загрузить"
	load_b.pressed.connect(_load_build)
	row.add_child(load_b)
	var del := Button.new()
	del.text = "Удалить"
	del.pressed.connect(func():
		if _build_list.item_count > 0:
			Settings.delete_build(_class_id, _build_list.get_item_text(_build_list.selected))
			_fill_builds())
	row.add_child(del)
	_fill_builds()

func _fill_builds() -> void:
	_build_list.clear()
	for n in Settings.builds(_class_id):
		_build_list.add_item(n)

func _save_build() -> void:
	var n := _build_name.text.strip_edges()
	if n == "" or _plan_order.is_empty():
		Sfx.play("ui_error")
		_title.text = "Заготовка: вкачайте таланты и введите название"
		return
	var ch := {}
	for k in _plan_choices:
		ch[int(k)] = str(_plan_choices[k])
	Settings.save_build(_class_id, n, {"order": _plan_order.duplicate(), "choices": ch})
	Settings.select_build(_class_id, n)
	Sfx.play("ui_learn")
	_fill_builds()
	for i in _build_list.item_count:
		if _build_list.get_item_text(i) == n:
			_build_list.select(i)
	refresh()

func _load_build() -> void:
	if _build_list.item_count == 0:
		return
	var n := _build_list.get_item_text(_build_list.selected)
	var b: Dictionary = Settings.builds(_class_id).get(n, {})
	_plan.clear()
	_plan_order.clear()
	for tid in b.get("order", []):
		if GameData.can_learn(_class_id, _plan, GameData.MAX_LEVEL, tid) == "":
			_plan[tid] = int(_plan.get(tid, 0)) + 1
			_plan_order.append(tid)
	_plan_choices = {}
	for k in b.get("choices", {}):
		_plan_choices[int(k)] = str(b["choices"][k])
	_build_name.text = n
	refresh()
