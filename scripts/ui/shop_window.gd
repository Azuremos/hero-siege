extends PanelContainer
## Лавка торговца: список товаров с ценами. Продажа — ПКМ по предмету в сумке (окно персонажа).

const GOLD := Color(0.95, 0.78, 0.35)
const SHORT := {"str": "сил", "agi": "лвк", "sta": "вын", "int": "инт", "spi": "дух", "sp": "сила закл.", "ap": "сила атаки"}

var world: Node3D
var vendor := ""
var _title: Label
var _list: VBoxContainer
var _only_mine: CheckBox
var _sort: OptionButton
## Сортировка товаров кузнеца: по ячейке (с заголовками), уровню, цене, качеству.
const SORTS := [["slot", "По ячейке"], ["level", "По уровню"], ["price", "По цене"], ["quality", "По качеству"]]
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
	_only_mine.text = "Только подходящее моему герою"
	_only_mine.tooltip_text = "Вещи, которые ваш класс может надеть и которые ему полезны\n(воину не показываются мантии и кольца на интеллект, магу — кирасы и кольца на силу)."
	_only_mine.button_pressed = true
	_only_mine.toggled.connect(func(_on): refresh())
	opts.add_child(_only_mine)
	_sort = OptionButton.new()
	for s in SORTS:
		_sort.add_item(s[1])
	_sort.tooltip_text = "Сортировка товаров"
	_sort.item_selected.connect(func(_i): refresh())
	opts.add_child(_sort)
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
	hint.text = "Продать: ПКМ по предмету в сумке (окно персонажа).  Торговец выкупает за 20% цены (ПКМ — с подтверждением, Shift + ПКМ — сразу)."
	hint.add_theme_font_size_override("font_size", 12)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(560, 0)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	v.add_child(hint)

var _tomes_wait := 0.0

## Томики: цена и прибавки приходят снимком режима — окно Книжника обновляется само раз в полсекунды.
func _process(delta: float) -> void:
	if not visible or vendor == "" or world.economy.VENDORS[world.economy.vkind(vendor)]["kind"] != "tomes":
		return
	_tomes_wait -= delta
	if _tomes_wait <= 0.0:
		_tomes_wait = 0.5
		refresh()

func open(vid: String) -> void:
	vendor = vid
	var v: Dictionary = world.economy.VENDORS[world.economy.vkind(vid)]   # в «Войне линий» id вида smith#a
	_title.text = "%s — %s" % [v["name"], v["desc"]]
	_only_mine.visible = v["kind"] == "gear"
	_sort.visible = v["kind"] == "gear"
	_tomes_wait = 0.0
	visible = true
	refresh()

func refresh() -> void:
	var hero = world.local_hero
	if hero == null or vendor == "":
		return
	GameData.tooltip_equip = hero.equip      # подсказка товара — сравнение с надетым
	_gold.text = "Золото: %d" % hero.gold
	for c in _list.get_children():
		c.queue_free()
	if world.economy.VENDORS[world.economy.vkind(vendor)]["kind"] == "tomes":
		_refresh_tomes(hero)
		return
	var ids: Array = world.economy.vendor_items(vendor, hero.unit.level).filter(func(id):
		return not (_only_mine.visible and _only_mine.button_pressed) or GameData.ItemData.fits_class(GameData.item(id), hero.class_id))
	var mode: String = SORTS[_sort.selected][0] if _sort.visible else ""
	if mode != "":
		ids.sort_custom(func(a, b): return _sort_key(GameData.item(a), mode) < _sort_key(GameData.item(b), mode))
	var last_slot := ""
	for id in ids:
		var it := GameData.item(id)
		if mode == "slot" and it["slot"] != last_slot:
			# заголовок ячейки: «Оружие», «Голова»…
			last_slot = it["slot"]
			var hl := Label.new()
			hl.text = GameData.ItemData.SLOTS.get(last_slot, last_slot)
			hl.add_theme_color_override("font_color", GOLD)
			hl.add_theme_font_size_override("font_size", 15)
			_list.add_child(hl)
		var row := HBoxContainer.new()
		RichTip.attach(row)
		row.add_theme_constant_override("separation", 8)
		var cost := GameData.shop_price(id)
		row.tooltip_text = GameData.item_tooltip(id, hero.class_id, hero.unit.level, cost)
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
		price.text = "%d з." % cost
		price.custom_minimum_size = Vector2(60, 0)
		price.add_theme_color_override("font_color", GOLD if hero.gold >= cost else Color(1, 0.4, 0.35))
		row.add_child(price)
		var buy := Button.new()
		buy.text = "Купить"
		buy.disabled = low or hero.gold < cost
		if low:
			buy.tooltip_text = "Нужен %d уровень — у вас %d" % [it["level"], hero.unit.level]
		var item_id: String = id
		buy.pressed.connect(func(): world.economy.send("request_buy", [vendor, item_id]))
		row.add_child(buy)
		_list.add_child(row)

## Книжник (Арена): томики характеристик — прибавка навсегда, цена растёт с каждой покупкой.
func _refresh_tomes(hero) -> void:
	var A := preload("res://scripts/data/arena_data.gd")
	var price: int = world.mode.tome_price(hero) if world.mode.has_method("tome_price") else A.TOME_PRICE
	var bought: int = world.mode.tome_count(hero) if world.mode.has_method("tome_count") else 0
	var head := Label.new()
	head.text = "Куплено томиков: %d.  Каждая покупка дороже на %d золота.  Ваши прибавки: %s" % [bought, A.TOME_STEP,
		", ".join(hero.tome_stats.keys().map(func(k): return "+%d %s" % [int(hero.tome_stats[k]), SHORT.get(k, k)])) if not hero.tome_stats.is_empty() else "нет"]
	head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.custom_minimum_size = Vector2(540, 0)
	head.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	_list.add_child(head)
	var desc := {"str": "урон оружием", "agi": "крит и броня", "sta": "+10 здоровья за единицу", "int": "мана и сила заклинаний", "spi": "восполнение маны и здоровья"}
	for tid in A.TOME_ORDER:
		var td: Dictionary = A.TOMES[tid]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var icon_holder := Control.new()
		icon_holder.custom_minimum_size = Vector2(42, 42)
		var tcol: Color = {"str": Color(1.0, 0.45, 0.35), "agi": Color(0.5, 1.0, 0.45), "sta": Color(1.0, 0.8, 0.35),
			"int": Color(0.5, 0.65, 1.0), "spi": Color(0.85, 0.6, 1.0)}.get(td["stat"], Color(0.9, 0.8, 0.5))
		icon_holder.add_child(SpellIcon.make_icon("res://assets/icons/items/tome.svg", "Т", tcol, "item_q3", 42))
		row.add_child(icon_holder)
		var text := VBoxContainer.new()
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(text)
		var n := Label.new()
		n.text = td["name"]
		n.add_theme_color_override("font_color", Color(0.75, 0.55, 1.0))
		text.add_child(n)
		var sub := Label.new()
		sub.add_theme_font_size_override("font_size", 12)
		sub.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
		sub.text = "+%d %s навсегда  •  %s" % [int(td["amount"]), SHORT.get(td["stat"], td["stat"]), desc.get(td["stat"], "")]
		text.add_child(sub)
		var pl := Label.new()
		pl.text = "%d з." % price
		pl.custom_minimum_size = Vector2(60, 0)
		pl.add_theme_color_override("font_color", GOLD if hero.gold >= price else Color(1, 0.4, 0.35))
		row.add_child(pl)
		var buy := Button.new()
		buy.text = "Купить"
		buy.disabled = hero.gold < price
		var t: String = tid
		buy.pressed.connect(func(): world.economy.send("request_buy", [vendor, t]))
		row.add_child(buy)
		_list.add_child(row)

func _short(it: Dictionary) -> String:
	if it["kind"] != "gear":
		var u: Dictionary = it["use"]
		if u.has("heal_pct"):
			return "+%d%% здоровья" % roundi(float(u["heal_pct"]) * 100.0)
		if u.has("mana_pct"):
			return "+%d%% маны" % roundi(float(u["mana_pct"]) * 100.0)
		return it.get("desc", "")
	var parts := []
	for k in ["str", "agi", "sta", "int", "spi", "sp", "ap"]:
		if it["stats"].has(k):
			parts.append("+%d %s" % [int(it["stats"][k]), SHORT[k]])
	if it["stats"].has("crit"):
		parts.append("+%.1f%% крит" % (it["stats"]["crit"] * 100.0))
	if it["stats"].has("armor"):
		parts.append("+%.1f%% брони" % (it["stats"]["armor"] * 100.0))
	return "  ".join(parts)

## Ключ сортировки: по ячейке — порядок ячеек снаряжения, внутри — уровень и цена.
func _sort_key(it: Dictionary, mode: String) -> Array:
	var slot_i: int = GameData.ItemData.SLOT_ORDER.find(it["slot"])
	if slot_i < 0:
		slot_i = 99      # аксессуары и прочее — в конце
	match mode:
		"slot":
			return [slot_i, int(it["level"]), int(it["price"])]
		"level":
			return [-int(it["level"]), slot_i, int(it["price"])]
		"price":
			return [int(it["price"]), slot_i]
		_:
			return [-int(it["q"]), slot_i, int(it["level"])]
