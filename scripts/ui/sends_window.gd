extends PanelContainer
## Окно Вербовщика («Война линий»): враги на линию соперника. У каждой отправки — облик врага, цена,
## прибавка к доходу, перезарядка и минута, с которой она доступна. Отправки на выбранную линию
## уходят на линию из списка «Куда», у элитных можно выбрать аффикс.

const GOLD := Color(0.95, 0.78, 0.35)
const ICON_DIR := "res://assets/icons/mobs/%s.png"

var world: Node3D
var vendor := ""
var _title: Label
var _gold: Label
var _income: Label
var _lane: OptionButton
var _affix: OptionButton
var _list: VBoxContainer
var _rows: Dictionary = {}          # отправка -> {row, buy, state}
var _refresh_t := 0.0

func setup(w: Node3D) -> void:
	world = w
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.06, 0.05, 0.04, 0.97)
	st.border_color = Color(1.0, 0.45, 0.35)
	st.set_border_width_all(2)
	st.set_corner_radius_all(8)
	st.set_content_margin_all(12)
	add_theme_stylebox_override("panel", st)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
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
	var info := HBoxContainer.new()
	v.add_child(info)
	_income = Label.new()
	_income.add_theme_font_size_override("font_size", 14)
	_income.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_child(_income)
	_gold = Label.new()
	_gold.add_theme_color_override("font_color", GOLD)
	info.add_child(_gold)
	var opts := HBoxContainer.new()
	opts.add_theme_constant_override("separation", 8)
	v.add_child(opts)
	var lt := Label.new()
	lt.text = "Куда:"
	opts.add_child(lt)
	_lane = OptionButton.new()
	_lane.tooltip_text = "Линия соперника для отправок «на выбранную» (массовка и тяжёлые всегда идут на линию напротив)"
	opts.add_child(_lane)
	var at := Label.new()
	at.text = "  Аффикс элитного:"
	opts.add_child(at)
	_affix = OptionButton.new()
	_affix.add_item("случайный")
	_affix.set_item_metadata(0, "")
	for a in GameData.AFFIXES:
		_affix.add_item(GameData.AFFIXES[a]["name"])
		_affix.set_item_metadata(_affix.item_count - 1, a)
		_affix.set_item_tooltip(_affix.item_count - 1, GameData.AFFIXES[a]["desc"])
	opts.add_child(_affix)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(600, 480)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 3)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	var hint := Label.new()
	hint.text = "Каждая отправка навсегда повышает доход (каждые 15 сек.). Отправленные враги вещей не роняют — только золото."
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(600, 0)
	v.add_child(hint)
	_build_rows()

func open(vid: String) -> void:
	vendor = vid
	var v: Dictionary = world.economy.VENDORS[world.economy.vkind(vid)]
	_title.text = "%s — %s" % [v["name"], v["desc"]]
	visible = true
	_fill_lanes()
	refresh()

func _fill_lanes() -> void:
	var lm := world.mode as LinesMode
	var lh = world.local_hero
	if lm == null or lh == null:
		return
	var keep := _lane.selected
	_lane.clear()
	var foe: int = 1 - lh.team
	for li in lm.lane_count:
		var who := ""
		for h in world.heroes.values():
			if h.team == foe and int(lm.slot.get(h.hero_id, -1)) == li:
				who = h.player_name
		var text := "Линия %d%s" % [li + 1, (" — " + who) if who != "" else " — пусто"]
		if li == int(lm.slot.get(lh.hero_id, 0)):
			text += " (напротив)"
		_lane.add_item(text)
	var mine := mini(int(lm.slot.get(lh.hero_id, 0)), lm.lane_count - 1)
	_lane.select(keep if keep >= 0 and keep < _lane.item_count else mine)
	_lane.visible = lm.lane_count > 1

func _build_rows() -> void:
	var SD := GameData.SendData
	var tier := -1
	for sid in SD.ordered():
		var s: Dictionary = SD.SENDS[sid]
		if int(s["tier"]) != tier:
			tier = int(s["tier"])
			var th := Label.new()
			th.text = "%d. %s" % [tier, SD.TIERS[tier]]
			th.add_theme_font_size_override("font_size", 15)
			th.add_theme_color_override("font_color", GOLD)
			_list.add_child(th)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.mouse_filter = Control.MOUSE_FILTER_PASS
		row.tooltip_text = _tooltip(sid)
		var icon := _icon(s["mob"], s.get("elite", false) or s.get("champion", false) or s.get("boss", false))
		row.add_child(icon)
		var text := VBoxContainer.new()
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(text)
		var n := Label.new()
		n.text = SD.title(sid, GameData.MOBS)
		n.add_theme_color_override("font_color", Color(1.0, 0.82, 0.25) if (s.get("elite", false) or s.get("champion", false) or s.get("boss", false)) else Color(0.95, 0.95, 0.9))
		text.add_child(n)
		var sub := Label.new()
		sub.add_theme_font_size_override("font_size", 12)
		sub.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
		var cd_txt := "%d сек." % int(s["cd"]) if float(s["cd"]) < 60.0 else "%d мин." % int(float(s["cd"]) / 60.0)
		sub.text = "+%d к доходу   •   перезарядка %s%s   •   %s" % [int(s["income"]), cd_txt, " (на команду)" if s.get("team_cd", false) else "",
			"на линию напротив" if s["target"] == "opposite" else "на выбранную линию"]
		text.add_child(sub)
		var state := Label.new()
		state.custom_minimum_size = Vector2(92, 0)
		state.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		state.add_theme_font_size_override("font_size", 13)
		row.add_child(state)
		var price := Label.new()
		price.text = "%d з." % int(s["price"])
		price.custom_minimum_size = Vector2(56, 0)
		price.add_theme_color_override("font_color", GOLD)
		row.add_child(price)
		var buy := Button.new()
		buy.text = "Отправить"
		var send_id: String = sid
		buy.pressed.connect(func(): _buy(send_id))
		row.add_child(buy)
		_list.add_child(row)
		_rows[sid] = {"row": row, "buy": buy, "state": state, "price": price}

## Облик врага: картинка из assets/icons/mobs (снимок модели, tools/mob_icons.gd), иначе — буква на цвете фракции.
func _icon(mob: String, gold_border: bool) -> Control:
	var holder := Panel.new()
	holder.custom_minimum_size = Vector2(46, 46)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var st := StyleBoxFlat.new()
	var md: Dictionary = GameData.MOBS[mob]
	var fcol: Color = GameData.FACTIONS.get(md.get("faction", ""), {}).get("color", Color(0.5, 0.5, 0.5))
	st.bg_color = fcol.darkened(0.7)
	st.border_color = Color(1.0, 0.82, 0.25) if gold_border else fcol.darkened(0.2)
	st.set_border_width_all(2)
	st.set_corner_radius_all(5)
	holder.add_theme_stylebox_override("panel", st)
	var path := ICON_DIR % mob
	if ResourceLoader.exists(path):
		var tr := TextureRect.new()
		tr.texture = load(path)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.position = Vector2(2, 2)
		tr.size = Vector2(42, 42)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(tr)
	else:
		var l := Label.new()
		l.text = str(md["name"]).substr(0, 1)
		l.add_theme_font_size_override("font_size", 22)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.size = Vector2(46, 46)
		holder.add_child(l)
	return holder

func _tooltip(sid: String) -> String:
	var s: Dictionary = GameData.SendData.SENDS[sid]
	var md: Dictionary = GameData.MOBS[s["mob"]]
	var lines := [GameData.SendData.title(sid, GameData.MOBS), "%s, %s" % [GameData.FACTIONS[md["faction"]]["name"], {"swarm": "массовка", "heavy": "тяжёлый",
		"fast": "быстрый", "ranged": "дальний бой", "support": "поддержка", "special": "особый", "boss": "босс"}.get(md["role"], md["role"])]]
	lines.append("Цена %d золота, доход +%d каждые 15 сек." % [int(s["price"]), int(s["income"])])
	lines.append("Доступно с %d минуты, перезарядка %d сек.%s" % [int(s["minute"]), int(s["cd"]), " — общая на команду" if s.get("team_cd", false) else ""])
	if s.get("elite", false):
		lines.append("Элитный: 1–2 аффикса%s, здоровье ×%.1f." % [" (один — на выбор)" if s.get("pick_affix", false) else "", GameData.AffixData.ELITE_HP])
	if s.get("champion", false):
		lines.append("Чемпион: 3 аффикса, здоровье ×%.0f." % GameData.AffixData.CHAMPION_HP)
	lines.append("За убийство сопернику — %d%% цены." % int(GameData.LinesData.SEND_BOUNTY * 100.0))
	return "\n".join(lines)

func _buy(sid: String) -> void:
	var lm := world.mode as LinesMode
	if lm == null:
		return
	var lane := _lane.selected if _lane.visible else -1
	var affix: String = str(_affix.get_item_metadata(_affix.selected))
	lm.send(sid, lane, affix)

func _process(delta: float) -> void:
	if not visible:
		return
	_refresh_t -= delta
	if _refresh_t <= 0.0:
		_refresh_t = 0.4
		refresh()

func refresh() -> void:
	var lm := world.mode as LinesMode
	var lh = world.local_hero
	if lm == null or lh == null:
		return
	_gold.text = "Золото: %d" % lh.gold
	_income.text = "Доход: +%d каждые 15 сек. (от отправок +%d)" % [lm.next_income_view(lh), int(lm.income.get(lh.hero_id, 0))]
	var mins := lm.minute()
	for sid in _rows:
		var s: Dictionary = GameData.SendData.SENDS[sid]
		var r: Dictionary = _rows[sid]
		var cd := lm.cd_left_view(lh, sid)
		var locked := mins < float(s["minute"])
		var poor: bool = lh.gold < int(s["price"])
		(r["buy"] as Button).disabled = locked or cd > 0.0 or poor or not lh.alive_visual
		var st: Label = r["state"]
		if locked:
			st.text = "с %d мин." % int(s["minute"])
			st.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		elif cd > 0.0:
			st.text = "%d сек." % int(ceil(cd))
			st.add_theme_color_override("font_color", Color(1, 0.6, 0.4))
		else:
			st.text = "готово"
			st.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
		(r["price"] as Label).add_theme_color_override("font_color", GOLD if not poor else Color(1, 0.4, 0.35))
		(r["row"] as Control).modulate = Color(1, 1, 1, 0.55) if locked else Color.WHITE
