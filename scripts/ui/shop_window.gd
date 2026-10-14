extends PanelContainer
## Лавка торговца: список товаров с ценами. Продажа — ПКМ по предмету в сумке (окно персонажа).

const GOLD := Color(0.95, 0.78, 0.35)
const SHORT := {"str": "сил", "agi": "лвк", "sta": "вын", "int": "инт", "spi": "дух", "sp": "сила закл.", "ap": "сила атаки"}

var world: Node3D
var vendor := ""
var _title: Label
var _list: VBoxContainer
var _only_mine: CheckBox
var _gold: Label

func setup(w: Node3D) -> void:
	world = w
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.06, 0.05, 0.04, 0.97)
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
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 19)
	_title.add_theme_color_override("font_color", GOLD)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	var close := Button.new()
	close.text = "  ✕  "
	close.pressed.connect(func(): visible = false)
	head.add_child(close)
	var opts := HBoxContainer.new()
	v.add_child(opts)
	_only_mine = CheckBox.new()
	_only_mine.text = "Только для моего класса"
	_only_mine.button_pressed = true
	_only_mine.toggled.connect(func(_on): refresh())
	opts.add_child(_only_mine)
	_gold = Label.new()
	_gold.add_theme_color_override("font_color", GOLD)
	_gold.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gold.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	opts.add_child(_gold)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(560, 470)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 4)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	var hint := Label.new()
	hint.text = "Продать: ПКМ по предмету в сумке (окно персонажа).  Торговец выкупает за 25% цены."
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	v.add_child(hint)

func open(vid: String) -> void:
	vendor = vid
	var v: Dictionary = world.economy.VENDORS[vid]
	_title.text = "%s — %s" % [v["name"], v["desc"]]
	_only_mine.visible = v["kind"] == "gear"
	visible = true
	refresh()

func refresh() -> void:
	var hero = world.local_hero
	if hero == null or vendor == "":
		return
	_gold.text = "Золото: %d" % hero.gold
	for c in _list.get_children():
		c.queue_free()
	for id in world.economy.vendor_items(vendor):
		var it := GameData.item(id)
		if _only_mine.visible and _only_mine.button_pressed and not it["classes"].is_empty() and not it["classes"].has(hero.class_id):
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.tooltip_text = GameData.item_tooltip(id, hero.class_id, hero.unit.level)
		row.mouse_filter = Control.MOUSE_FILTER_PASS
		var icon_holder := Control.new()
		icon_holder.custom_minimum_size = Vector2(42, 42)
		icon_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon_holder.add_child(SpellIcon.make_item(id, 42))
		row.add_child(icon_holder)
		var text := VBoxContainer.new()
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(text)
		var n := Label.new()
		n.text = it["name"]
		n.add_theme_color_override("font_color", GameData.item_color(id))
		text.add_child(n)
		var sub := Label.new()
		sub.add_theme_font_size_override("font_size", 12)
		var low: bool = hero.unit.level < int(it["level"])
		if low:
			row.modulate = Color(1, 1, 1, 0.5)   # не по уровню: видно, но приглушено
		sub.add_theme_color_override("font_color", Color(1, 0.4, 0.35) if low else Color(0.75, 0.75, 0.75))
		sub.text = "ур. %d   •   %s" % [it["level"], _short(it)]
		text.add_child(sub)
		var price := Label.new()
		price.text = "%d з." % it["price"]
		price.custom_minimum_size = Vector2(60, 0)
		price.add_theme_color_override("font_color", GOLD if hero.gold >= int(it["price"]) else Color(1, 0.4, 0.35))
		row.add_child(price)
		var buy := Button.new()
		buy.text = "Купить"
		buy.disabled = low or hero.gold < int(it["price"])
		if low:
			buy.tooltip_text = "Нужен %d уровень — у вас %d" % [it["level"], hero.unit.level]
		var item_id: String = id
		buy.pressed.connect(func(): world.economy.send("request_buy", [vendor, item_id]))
		row.add_child(buy)
		_list.add_child(row)

func _short(it: Dictionary) -> String:
	if it["kind"] != "gear":
		var u: Dictionary = it["use"]
		if u.has("heal"):
			return "+%d здоровья" % int(u["heal"])
		if u.has("mana"):
			return "+%d маны" % int(u["mana"])
		return it.get("desc", "")
	var parts := []
	for k in ["str", "agi", "sta", "int", "spi", "sp", "ap"]:
		if it["stats"].has(k):
			parts.append("+%d %s" % [int(it["stats"][k]), SHORT[k]])
	if it["stats"].has("armor"):
		parts.append("+%.1f%% брони" % (it["stats"]["armor"] * 100.0))
	return "  ".join(parts)
