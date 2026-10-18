extends PanelContainer
## Окно «Мастер сборки» (сессия 13): слева — сумка, справа — рецепты (recipes.gd). Доступные из того, что есть, —
## зелёные, у остальных подсвечено, чего не хватает. Выбранный рецепт: слоты компонентов (ЛКМ по вещи в сумке
## или перетаскивание кладёт её в слот, ЛКМ по слоту — убрать), что получится, цена и «Собрать».
## Собирает сервер (economy.request_craft) — он же всё проверяет.

const GOLD := Color(0.95, 0.78, 0.35)
const CELL := 46.0
const R := preload("res://scripts/data/recipes.gd")

var world: Node3D
var vendor := ""
var _bag_grid: GridContainer
var _list: VBoxContainer
var _gold: Label
var _title: Label
var _desc: Label
var _slots_box: HBoxContainer
var _result: Label
var _craft_btn: Button
var _scroll_lbl: Label
var _rid := "merge"
var _chosen: Array = []          # индексы сумки по слотам выбранного рецепта (-1 — пусто)

func setup(w: Node3D) -> void:
	world = w
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.05, 0.045, 0.07, 0.97)
	st.border_color = GOLD
	st.set_border_width_all(2)
	st.set_corner_radius_all(8)
	st.set_content_margin_all(12)
	add_theme_stylebox_override("panel", st)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	_title = _lbl("Мастер сборки", 19, GOLD)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	_gold = _lbl("", 15, GOLD)
	head.add_child(_gold)
	var close := Button.new()
	close.text = "  ✕  "
	close.pressed.connect(func(): visible = false)
	head.add_child(close)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	v.add_child(h)
	# слева — сумка
	var left := VBoxContainer.new()
	h.add_child(left)
	left.add_child(_lbl("Сумка", 15, GOLD))
	_bag_grid = GridContainer.new()
	_bag_grid.columns = 5
	_bag_grid.add_theme_constant_override("h_separation", 4)
	_bag_grid.add_theme_constant_override("v_separation", 4)
	left.add_child(_bag_grid)
	var srow := HBoxContainer.new()
	left.add_child(srow)
	_scroll_lbl = _lbl("", 13, Color(0.8, 0.85, 1.0))
	_scroll_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	srow.add_child(_scroll_lbl)
	var buy := Button.new()
	buy.text = "Купить свиток"
	buy.tooltip_text = "Свиток улучшения: «Улучшение свитком» поднимает качество вещи на ступень."
	buy.pressed.connect(func(): world.economy.send("request_buy", [vendor, R.SCROLL]))
	srow.add_child(buy)
	# справа — рецепты и выбранный рецепт
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 6)
	right.custom_minimum_size = Vector2(430, 0)
	h.add_child(right)
	right.add_child(_lbl("Рецепты", 15, GOLD))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(430, 230)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 3)
	scroll.add_child(_list)
	right.add_child(HSeparator.new())
	_desc = _lbl("", 13, Color(0.85, 0.85, 0.85))
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc.custom_minimum_size = Vector2(430, 0)
	right.add_child(_desc)
	_slots_box = HBoxContainer.new()
	_slots_box.add_theme_constant_override("separation", 6)
	right.add_child(_slots_box)
	_result = _lbl("", 14, Color(1, 1, 1))
	_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result.custom_minimum_size = Vector2(430, 0)
	right.add_child(_result)
	var btns := HBoxContainer.new()
	right.add_child(btns)
	var auto := Button.new()
	auto.text = "Подобрать из сумки"
	auto.pressed.connect(func():
		_auto()
		refresh())
	btns.add_child(auto)
	var clear := Button.new()
	clear.text = "Очистить"
	clear.pressed.connect(func():
		_chosen.fill(-1)
		refresh())
	btns.add_child(clear)
	_craft_btn = Button.new()
	_craft_btn.text = "Собрать"
	_craft_btn.pressed.connect(_craft)
	btns.add_child(_craft_btn)
	var hint := _lbl("ЛКМ по вещи в сумке или перетаскивание — положить в слот рецепта, ЛКМ по слоту — убрать. Легендарки, части сетов и именные вещи не собираются.", 12, Color(1, 1, 1, 0.55))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(700, 0)
	v.add_child(hint)

func _lbl(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l

func open(vid: String) -> void:
	vendor = vid
	visible = true
	_select(_rid)

func _select(rid: String) -> void:
	_rid = rid
	_chosen = []
	_chosen.resize(R.slots(rid))
	_chosen.fill(-1)
	_auto()
	refresh()

func _bag_items() -> Array:
	var out: Array = []
	var hero = world.local_hero
	for i in hero.bag.size():
		if hero.bag[i] != null:
			out.append([i, GameData.item(hero.bag[i]["id"])])
	return out

func _auto() -> void:
	_chosen = R.auto_fill(_rid, _bag_items())

func _chosen_items() -> Array:
	var hero = world.local_hero
	var out: Array = []
	for i in _chosen:
		out.append(GameData.item(hero.bag[i]["id"]) if int(i) >= 0 and int(i) < hero.bag.size() and hero.bag[int(i)] != null else {})
	return out

func _names() -> Dictionary:
	var d := {}
	for b in GameData.ItemData.TEMPLATES:
		d[b] = GameData.ItemData.TEMPLATES[b]["name"]
	return d

func refresh() -> void:
	var hero = world.local_hero
	if hero == null:
		return
	GameData.tooltip_equip = hero.equip
	_gold.text = "Золото: %d" % hero.gold
	_scroll_lbl.text = "Свитков улучшения: %d  (%d з.)" % [hero.bag_count(R.SCROLL), GameData.shop_price(R.SCROLL)]
	# убрать из слотов то, чего больше нет в сумке
	for k in _chosen.size():
		var i := int(_chosen[k])
		if i >= 0 and (i >= hero.bag.size() or hero.bag[i] == null):
			_chosen[k] = -1
	# сумка
	for c in _bag_grid.get_children():
		c.queue_free()
	for i in hero.bag.size():
		var s = hero.bag[i]
		var cell := _cell(s["id"] if s != null else "", int(s["n"]) if s != null else 0)
		if s != null:
			var it := GameData.item(s["id"])
			var ok := R.usable(it)
			if _chosen.has(i):
				cell.modulate = Color(0.45, 0.45, 0.45)       # уже в слоте рецепта
			elif not ok:
				cell.modulate = Color(1, 1, 1, 0.4)
			var idx: int = i
			cell.gui_input.connect(func(ev): _bag_click(ev, idx))
			cell.set_drag_forwarding(func(_p): return _drag_bag(idx), func(_p, _d): return false, func(_p, _d): pass)
		_bag_grid.add_child(cell)
	# рецепты
	for c in _list.get_children():
		c.queue_free()
	var bag := _bag_items()
	var names := _names()
	for rid in R.ORDER:
		var r: Dictionary = R.RECIPES[rid]
		var fill: Array = R.auto_fill(rid, bag)
		var ready: bool = not fill.has(-1) and (r["kind"] != "scroll" or hero.bag_count(R.SCROLL) > 0)
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.toggle_mode = true
		b.button_pressed = rid == _rid
		b.text = "%s  —  %s" % [r["name"], "можно собрать" if ready else "нужно: " + R.need_text(rid, fill, names)]
		b.tooltip_text = r["desc"]
		b.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5) if ready else Color(1.0, 0.6, 0.5))
		b.clip_text = true
		b.custom_minimum_size = Vector2(410, 0)
		var rr: String = rid
		b.pressed.connect(func(): _select(rr))
		_list.add_child(b)
	# выбранный рецепт
	var r: Dictionary = R.RECIPES[_rid]
	_desc.text = "%s: %s" % [r["name"], r["desc"]]
	for c in _slots_box.get_children():
		c.queue_free()
	var items := _chosen_items()
	for k in _chosen.size():
		var i := int(_chosen[k])
		var slot := _cell(hero.bag[i]["id"] if i >= 0 else "", 0)
		if i < 0:
			var need := "?"
			if r["kind"] == "combine":
				var part: Dictionary = r["parts"][k]
				need = str(names.get(part["base"], part["base"])).substr(0, 3)
			var ql := _lbl(need, 12, Color(1, 0.6, 0.5))
			ql.position = Vector2(4, 14)
			slot.add_child(ql)
			slot.tooltip_text = "Положите сюда компонент"
		var kk := k
		slot.gui_input.connect(func(ev):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				_chosen[kk] = -1
				refresh())
		slot.set_drag_forwarding(func(_p): return null, func(_p, d): return d is Dictionary and d.has("craft_bag"),
			func(_p, d): _put(int(d["craft_bag"]), kk))
		_slots_box.add_child(slot)
	if r["kind"] == "scroll":
		_slots_box.add_child(_lbl("+ свиток (%d)" % hero.bag_count(R.SCROLL), 14, Color(0.8, 0.85, 1.0)))
	var err := R.check(_rid, items, hero.bag_count(R.SCROLL))
	var res: Dictionary = R.result(_rid, items) if not _chosen.has(-1) else {}
	if err == "" and not res.is_empty():
		var price: int = world.economy.craft_price(_rid, items)
		var tpl: Dictionary = GameData.ItemData.tpl(res["base"])
		_result.text = "Получится: %s %s, уровень предмета %d (свойства и прок — случайные).  Цена: %d з." % [
			GameData.ItemData.QUALITY_NAMES[int(res["q"])].to_lower(), tpl["name"], int(res["ilvl"]), price]
		_result.add_theme_color_override("font_color", GameData.ItemData.QUALITY[int(res["q"])])
		_craft_btn.disabled = hero.gold < price
		_craft_btn.text = "Собрать (%d з.)" % price
		_craft_btn.tooltip_text = "" if hero.gold >= price else "Недостаточно золота"
	else:
		_result.text = err if err != "" else "Положите компоненты"
		_result.add_theme_color_override("font_color", Color(1, 0.6, 0.5))
		_craft_btn.disabled = true
		_craft_btn.text = "Собрать"

func _cell(id: String, n: int) -> Panel:
	var p := Panel.new()
	RichTip.attach(p)
	p.custom_minimum_size = Vector2(CELL, CELL)
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0, 0, 0, 0.55)
	st.border_color = Color(0.35, 0.32, 0.25)
	st.set_border_width_all(2)
	st.set_corner_radius_all(5)
	p.add_theme_stylebox_override("panel", st)
	if id != "":
		var icon := SpellIcon.make_item(id, CELL - 6)
		icon.position = Vector2(3, 3)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.add_child(icon)
		p.tooltip_text = GameData.item_tooltip(id, world.local_hero.class_id, world.local_hero.unit.level)
		if n > 1:
			var nl := _lbl(str(n), 12, Color.WHITE)
			nl.position = Vector2(CELL - 18, CELL - 18)
			p.add_child(nl)
	return p

func _drag_bag(idx: int) -> Variant:
	var hero = world.local_hero
	if hero.bag[idx] == null:
		return null
	var prev := SpellIcon.make_item(hero.bag[idx]["id"], CELL - 6)
	set_drag_preview(prev)
	return {"craft_bag": idx}

func _bag_click(ev: InputEvent, idx: int) -> void:
	if not (ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT):
		return
	var at: int = _chosen.find(idx)
	if at >= 0:
		_chosen[at] = -1
		refresh()
		return
	# в первый пустой слот, куда вещь подходит
	var items := _chosen_items()
	var it := GameData.item(world.local_hero.bag[idx]["id"])
	for k in _chosen.size():
		if int(_chosen[k]) < 0 and R.fits(_rid, k, it, items):
			_chosen[k] = idx
			refresh()
			return
	world.hud.error("Не подходит для рецепта «%s»" % R.RECIPES[_rid]["name"])

func _put(idx: int, k: int) -> void:
	var items := _chosen_items()
	items[k] = {}
	var it := GameData.item(world.local_hero.bag[idx]["id"])
	if not R.fits(_rid, k, it, items):
		world.hud.error("Не подходит в этот слот")
		return
	var at: int = _chosen.find(idx)
	if at >= 0:
		_chosen[at] = -1
	_chosen[k] = idx
	refresh()

func _craft() -> void:
	if _chosen.has(-1):
		return
	world.economy.send("request_craft", [_rid, _chosen.duplicate()])
	Sfx.play("ui_click")
