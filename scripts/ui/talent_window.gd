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
			Sfx.play("ui_learn")
		refresh()
	else:
		world.spells.send_to_server("request_learn", [tid])

func _reset() -> void:
	if _preview:
		_plan.clear()
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
			grid.add_child(cell)
			var icon := SpellIcon.make_talent(t, col, CELL - 6)
			icon.position = Vector2(3, 3)
			cell.add_child(icon)
			var rank := _label("", 13, Color.WHITE)
			rank.position = Vector2(CELL - 34, CELL - 20)
			rank.size = Vector2(32, 18)
			rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			cell.add_child(rank)
			_cells[tid] = {"panel": cell, "style": cs, "rank": rank, "icon": icon, "tree": ti, "t": t}

func refresh() -> void:
	if not _preview and (world == null or world.local_hero == null):
		return
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
		c["panel"].tooltip_text = _tooltip(t, r, err)
func _tooltip(t: Dictionary, r: int, err: String) -> String:
	var lines := ["%s   (ранг %d/%d)" % [t["name"], r, int(t["max"])]]
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
