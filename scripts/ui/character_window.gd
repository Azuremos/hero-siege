extends PanelContainer
## Окно персонажа (C): снаряжение, атрибуты, сумка.
## Сумка: ЛКМ — надеть/выпить, ПКМ — продать (когда открыта лавка), перетаскивание — на панель или в другую ячейку.
## Снаряжение: ПКМ — снять.

const GOLD := Color(0.95, 0.78, 0.35)
const CELL := 50.0

var world: Node3D
var _equip_box: VBoxContainer
var _equip_grid: GridContainer   # ячейки снаряжения в два столбца, чтобы окно влезало по высоте
var _stats_box: VBoxContainer
var _bag_grid: GridContainer
var _gold: Label
var _title: Label

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
	var head := HBoxContainer.new()
	v.add_child(head)
	_title = _lbl("", 19, GOLD)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	var close := Button.new()
	close.text = "  ✕  "
	close.pressed.connect(func(): visible = false)
	head.add_child(close)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	v.add_child(h)
	_equip_box = VBoxContainer.new()
	_equip_box.add_theme_constant_override("separation", 4)
	h.add_child(_equip_box)
	_stats_box = VBoxContainer.new()
	_stats_box.custom_minimum_size = Vector2(210, 0)
	h.add_child(_stats_box)
	var bag_v := VBoxContainer.new()
	h.add_child(bag_v)
	bag_v.add_child(_lbl("Сумка", 15, GOLD))
	_bag_grid = GridContainer.new()
	_bag_grid.columns = 5
	_bag_grid.add_theme_constant_override("h_separation", 4)
	_bag_grid.add_theme_constant_override("v_separation", 4)
	bag_v.add_child(_bag_grid)
	_gold = _lbl("", 15, GOLD)
	bag_v.add_child(_gold)
	var hint := _lbl("ЛКМ — надеть / выпить.  ПКМ — меню (выбросить); у торговца — продать, при обмене — в обмен.\nЗелья и используемые аксессуары перетаскиваются на панель заклинаний.\nУтащите вещь за пределы окна — она упадёт на землю.", 12, Color(1, 1, 1, 0.6))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(300, 0)
	v.add_child(hint)

func _lbl(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l

func _cell(content: Control, tip: String) -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(CELL, CELL)
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0, 0, 0, 0.55)
	st.border_color = Color(0.35, 0.32, 0.25)
	st.set_border_width_all(2)
	st.set_corner_radius_all(5)
	p.add_theme_stylebox_override("panel", st)
	p.tooltip_text = tip
	if content:
		content.position = Vector2(2, 2)
		p.add_child(content)
	return p

func refresh() -> void:
	var hero = world.local_hero
	if hero == null:
		return
	_title.text = "%s — %s %d ур." % [hero.player_name, GameData.CLASSES[hero.class_id]["name"], hero.unit.level]
	# снаряжение
	for c in _equip_box.get_children():
		_equip_box.remove_child(c)   # сразу из раскладки — иначе размер окна считается со старыми рядами
		c.queue_free()
	_equip_box.add_child(_lbl("Снаряжение", 15, GOLD))
	_equip_grid = GridContainer.new()
	_equip_grid.columns = 2
	_equip_grid.add_theme_constant_override("h_separation", 10)
	_equip_grid.add_theme_constant_override("v_separation", 4)
	_equip_box.add_child(_equip_grid)
	for slot in GameData.ItemData.SLOT_ORDER:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var id = hero.equip.get(slot, null)
		var tip: String = GameData.item_tooltip(id, hero.class_id, hero.unit.level) + "\n\nПКМ — снять" if id != null else GameData.ItemData.SLOTS[slot] + " — пусто"
		var cell := _cell(SpellIcon.make_item(id, CELL - 4) if id != null else null, tip)
		var s: String = slot
		cell.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
				world.economy.send("request_unequip", [s]))
		if id != null and GameData.ItemData.use_of(id) != "":
			# используемый аксессуар: кнопку ячейки можно перетащить на панель заклинаний
			cell.tooltip_text += "\nПеретащите на панель заклинаний — кнопка «Использовать»"
			cell.set_drag_forwarding(func(_at: Vector2) -> Variant:
				cell.set_drag_preview(SpellIcon.make_item(id, 44))
				return {"type": "spell", "sid": "use:" + s, "from": -1}, Callable(), Callable())
		row.add_child(cell)
		var name_l := _lbl(GameData.item(id)["name"] if id != null else GameData.ItemData.SLOTS[slot], 12,
			GameData.item_color(id) if id != null else Color(0.55, 0.55, 0.55))
		# ширина и высота строки постоянные: длинное название не раздвигает сетку
		name_l.custom_minimum_size = Vector2(130, CELL)
		name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_l.max_lines_visible = 2
		name_l.clip_text = true
		name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(name_l)
		_equip_grid.add_child(row)
	# атрибуты и характеристики
	for c in _stats_box.get_children():
		_stats_box.remove_child(c)
		c.queue_free()
	_stats_box.add_child(_lbl("Атрибуты", 15, GOLD))
	for k in ["str", "agi", "sta", "int", "spi"]:
		var l := _lbl("%s: %d" % [GameData.ATTRS[k]["name"], int(hero.attrs.get(k, 0))], 14, Color.WHITE)
		l.tooltip_text = GameData.ATTRS[k]["desc"]
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		_stats_box.add_child(l)
	_stats_box.add_child(HSeparator.new())
	var u: Unit = hero.unit
	var res: String = {"rage": "Ярость", "focus": "Концентрация"}.get(u.resource, "Мана")
	for line in [
		"Здоровье: %d" % int(u.max_hp),
		"%s: %d" % [res, int(u.max_mana)],
		"Сила заклинаний: %d" % int(hero.spell_power),
		"Сила атаки: %d" % int(hero.attack_power),
		"Шанс крита: %.1f%%" % (u.crit_base * 100.0),
		"Броня: −%d%% физ. урона" % int(u.armor * 100.0),
		"Блок щитом: %.1f%%" % (u.mod("block") * 100.0),
		"Множитель заклинаний: ×%.2f" % u.power,
		"Множитель оружия: ×%.2f" % u.phys_power]:
		_stats_box.add_child(_lbl(line, 13, Color(0.9, 0.9, 0.85)))
	# сумка
	for c in _bag_grid.get_children():
		c.queue_free()
	for i in hero.bag.size():
		var s = hero.bag[i]
		var cell: Panel
		if s == null:
			cell = _cell(null, "Пусто")
		else:
			cell = _cell(SpellIcon.make_item(s["id"], CELL - 4), GameData.item_tooltip(s["id"], hero.class_id, hero.unit.level))
			if int(s["n"]) > 1:
				var n := _lbl(str(s["n"]), 13, Color.WHITE)
				n.add_theme_color_override("font_outline_color", Color(0, 0, 0))
				n.add_theme_constant_override("outline_size", 4)
				n.position = Vector2(CELL - 22, CELL - 22)
				cell.add_child(n)
		if not world.trade.state.is_empty() and world.trade.state["slots"].has(i):
			cell.modulate = Color(0.45, 0.45, 0.45)     # лежит в окне обмена
		var idx: int = i
		cell.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and ev.pressed:
				if ev.button_index == MOUSE_BUTTON_LEFT and ev.double_click == false:
					pass
				if ev.button_index == MOUSE_BUTTON_RIGHT:
					if world.hud.shop_open():
						world.economy.send("request_sell", [idx])
					elif world.hud.trade_open():
						world.trade.toggle_slot(idx)
					elif hero.bag[idx] != null:
						_bag_menu(idx)
			elif ev is InputEventMouseButton and not ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				if hero.bag[idx] != null:
					world.economy.send("request_use", [idx]))
		cell.set_drag_forwarding(_bag_drag.bind(idx, cell), _bag_can_drop, _bag_drop.bind(idx))
		_bag_grid.add_child(cell)
	_gold.text = "Золото: %d" % hero.gold

func _bag_drag(_at: Vector2, idx: int, cell: Control) -> Variant:
	var hero = world.local_hero
	var s = hero.bag[idx]
	if s == null:
		return null
	cell.set_drag_preview(SpellIcon.make_item(s["id"], 44))
	_drag_bag = idx
	var it := GameData.item(s["id"])
	if it["kind"] == "consumable":
		return {"type": "spell", "sid": "item:" + s["id"], "from": -1, "bag": idx}
	return {"type": "bag", "bag": idx}

func _bag_can_drop(_at: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.has("bag")

func _bag_drop(_at: Vector2, data: Variant, idx: int) -> void:
	world.economy.send("request_swap", [int(data["bag"]), idx])

# ---------------------------------------------------------------- меню вещи и выбрасывание

var _menu: PopupMenu
var _menu_idx := -1
var _drag_bag := -1

## ПКМ по вещи (лавка и обмен закрыты): надеть / выпить, выбросить.
func _bag_menu(idx: int) -> void:
	var hero = world.local_hero
	if _menu == null:
		_menu = PopupMenu.new()
		_menu.id_pressed.connect(func(mid: int):
			if mid == 1:
				world.economy.send("request_use", [_menu_idx])
			elif mid == 2:
				world.economy.send("request_drop", [_menu_idx]))
		add_child(_menu)
	_menu.clear()
	var it := GameData.item(hero.bag[idx]["id"])
	_menu.add_item("Надеть" if it["kind"] == "gear" else "Использовать", 1)
	_menu.add_item("Выбросить", 2)
	_menu_idx = idx
	_menu.position = Vector2i(get_viewport().get_mouse_position())
	_menu.popup()

## Вещь утащили из сумки и бросили не на окно — выбросить её на землю (как в WoW).
func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and _drag_bag >= 0:
		var idx := _drag_bag
		_drag_bag = -1
		if visible and not get_viewport().gui_is_drag_successful() and not get_global_rect().has_point(get_global_mouse_position()):
			var hud = world.hud
			if not (hud.trade_open() and hud._trade_win.get_global_rect().has_point(get_global_mouse_position())):
				world.economy.send("request_drop", [idx])
