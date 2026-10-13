extends PanelContainer
## Окно персонажа (C): снаряжение, атрибуты, сумка.
## Сумка: ЛКМ — надеть/выпить, ПКМ — продать (когда открыта лавка), перетаскивание — на панель или в другую ячейку.
## Снаряжение: ПКМ — снять.

const GOLD := Color(0.95, 0.78, 0.35)
const CELL := 50.0

var world: Node3D
var _equip_box: VBoxContainer
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
	var hint := _lbl("ЛКМ — надеть / выпить.  ПКМ у торговца — продать.\nЗелья можно перетащить на панель заклинаний.", 12, Color(1, 1, 1, 0.6))
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
		c.queue_free()
	_equip_box.add_child(_lbl("Снаряжение", 15, GOLD))
	for slot in GameData.ItemData.SLOT_ORDER:
		if slot == "offhand" and hero.unit.flag("dual_wield") <= 0.0 and not hero.equip.has("offhand"):
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var id = hero.equip.get(slot, null)
		var tip: String = GameData.item_tooltip(id, hero.class_id, hero.unit.level) + "\n\nПКМ — снять" if id != null else GameData.ItemData.SLOTS[slot] + " — пусто"
		var cell := _cell(SpellIcon.make_item(id, CELL - 4) if id != null else null, tip)
		var s: String = slot
		cell.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
				world.economy.send("request_unequip", [s]))
		row.add_child(cell)
		var name_l := _lbl(GameData.item(id)["name"] if id != null else GameData.ItemData.SLOTS[slot], 13,
			GameData.item_color(id) if id != null else Color(0.55, 0.55, 0.55))
		name_l.custom_minimum_size = Vector2(150, 0)
		name_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(name_l)
		_equip_box.add_child(row)
	# атрибуты и характеристики
	for c in _stats_box.get_children():
		c.queue_free()
	_stats_box.add_child(_lbl("Атрибуты", 15, GOLD))
	for k in ["str", "agi", "sta", "int", "spi"]:
		var l := _lbl("%s: %d" % [GameData.ATTRS[k]["name"], int(hero.attrs.get(k, 0))], 14, Color.WHITE)
		l.tooltip_text = GameData.ATTRS[k]["desc"]
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		_stats_box.add_child(l)
	_stats_box.add_child(HSeparator.new())
	var u: Unit = hero.unit
	var res := "Ярость" if u.resource == "rage" else "Мана"
	for line in [
		"Здоровье: %d" % int(u.max_hp),
		"%s: %d" % [res, int(u.max_mana)],
		"Сила заклинаний: %d" % int(hero.spell_power),
		"Сила атаки: %d" % int(hero.attack_power),
		"Шанс крита: %.1f%%" % (u.crit_base * 100.0),
		"Броня: −%d%% физ. урона" % int(u.armor * 100.0),
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
		var idx: int = i
		cell.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and ev.pressed:
				if ev.button_index == MOUSE_BUTTON_LEFT and ev.double_click == false:
					pass
				if ev.button_index == MOUSE_BUTTON_RIGHT:
					if world.hud.shop_open():
						world.economy.send("request_sell", [idx])
					else:
						world.economy.send("request_use", [idx])
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
	var it := GameData.item(s["id"])
	if it["kind"] == "consumable":
		return {"type": "spell", "sid": "item:" + s["id"], "from": -1, "bag": idx}
	return {"type": "bag", "bag": idx}

func _bag_can_drop(_at: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.has("bag")

func _bag_drop(_at: Vector2, data: Variant, idx: int) -> void:
	world.economy.send("request_swap", [int(data["bag"]), idx])
