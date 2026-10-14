extends PanelContainer
## Окно счётчика урона и лечения (в духе Details / Recount).
## Заголовок: режим (урон, лечение, получено, смерти) и отрезок (текущий бой, прошлая волна, вся партия).
## Строки: полоса цвета класса, имя, всего, в секунду, доля. Наведение на строку — разбивка по заклинаниям.
## Окно тянется за правый нижний угол (ширина и число строк), двигается в режиме настройки интерфейса.

const GOLD := Color(0.95, 0.78, 0.35)
const MODES := [["dmg", "Урон"], ["heal", "Лечение"], ["taken", "Получено"], ["deaths", "Смерти"]]
const SEGS := [["current", "Текущий бой"], ["last", "Прошлая волна"], ["total", "Вся партия"]]
const ROW_H := 20.0

var world: Node3D
var meter: Node
var preview := false          # предпросмотр из меню: фальшивые данные
var _mode := 0
var _seg := 0
var _w := 260.0
var _rows := 6
var _mode_btn: Button
var _seg_btn: Button
var _list: VBoxContainer
var _detail: PanelContainer
var _detail_l: Label
var _hover_hid := 0
var _resizing := false
var _rows_cache: Array = []

func setup(w: Node3D, m: Node) -> void:
	world = w
	meter = m
	_w = float(Settings.get_ui_opt("meter_w", 260.0))
	_rows = int(Settings.get_ui_opt("meter_rows", 6))
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.05, 0.05, 0.08, 0.82)
	st.border_color = Color(0.35, 0.32, 0.25)
	st.set_border_width_all(1)
	st.set_corner_radius_all(5)
	st.set_content_margin_all(5)
	add_theme_stylebox_override("panel", st)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 3)
	v.add_child(head)
	_mode_btn = _small_btn("", func():
		_mode = (_mode + 1) % MODES.size()
		_refresh_titles())
	_mode_btn.tooltip_text = "Режим: урон / лечение / получено / смерти"
	head.add_child(_mode_btn)
	_seg_btn = _small_btn("", func():
		_seg = (_seg + 1) % SEGS.size()
		_refresh_titles())
	_seg_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seg_btn.tooltip_text = "Отрезок: текущий бой / прошлая волна / вся партия"
	head.add_child(_seg_btn)
	var reset := _small_btn("⟲", func():
		if meter and not preview:
			meter.send("request_reset", []))
	reset.tooltip_text = "Сбросить данные счётчика"
	head.add_child(reset)
	var close := _small_btn("✕", func(): visible = false)
	head.add_child(close)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 1)
	v.add_child(_list)
	# уголок для изменения размера
	var grip := Label.new()
	grip.text = "◢"
	grip.add_theme_font_size_override("font_size", 12)
	grip.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
	grip.size_flags_horizontal = Control.SIZE_SHRINK_END
	grip.mouse_filter = Control.MOUSE_FILTER_STOP
	grip.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	grip.tooltip_text = "Потяните, чтобы изменить ширину и число строк"
	grip.gui_input.connect(_on_grip)
	v.add_child(grip)
	# разбивка по заклинаниям при наведении на строку
	_detail = PanelContainer.new()
	_detail.add_theme_stylebox_override("panel", st)
	_detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail.top_level = true
	_detail.visible = false
	_detail_l = Label.new()
	_detail_l.add_theme_font_size_override("font_size", 12)
	_detail.add_child(_detail_l)
	add_child(_detail)
	if meter:
		meter.detail_received.connect(_on_detail)
	_refresh_titles()
	_apply_size()

func _small_btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 12)
	b.custom_minimum_size = Vector2(0, 20)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b

func _refresh_titles() -> void:
	_mode_btn.text = MODES[_mode][1]
	var seg_id: String = SEGS[_seg][0]
	var seg_name: String = SEGS[_seg][1]
	if meter and seg_id == "current":
		seg_name = "Бой: " + str(meter.view[seg_id]["name"])
	_seg_btn.text = seg_name
	_rows_cache = []

func _apply_size() -> void:
	custom_minimum_size = Vector2(_w, 0)
	_list.custom_minimum_size = Vector2(_w - 12, _rows * (ROW_H + 1))
	reset_size()

func _on_grip(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		_resizing = ev.pressed
		if not ev.pressed:
			Settings.set_ui_opt("meter_w", _w)
			Settings.set_ui_opt("meter_rows", _rows)
	elif ev is InputEventMouseMotion and _resizing:
		var local: Vector2 = get_global_mouse_position() - global_position
		_w = clampf(local.x, 200.0, 560.0)
		_rows = clampi(int((local.y - 50.0) / (ROW_H + 1)), 2, 14)
		_apply_size()

static func fmt(x: float) -> String:
	if x >= 1000000.0:
		return ("%.2fм" % (x / 1000000.0)).replace(".", ",")
	if x >= 10000.0:
		return ("%.1fк" % (x / 1000.0)).replace(".", ",")
	return str(int(round(x)))

## Данные отрезка: [[hero_id, урон, лечение, перелечивание, получено, смерти], …], длительность.
func _data() -> Array:
	var seg_id: String = SEGS[_seg][0]
	if preview:
		return [_fake_rows(), 60.0]
	var vw: Dictionary = meter.view[seg_id]
	return [vw["rows"], float(vw["time"])]

func _fake_rows() -> Array:
	return [[1, 48200, 0, 0, 9100, 0], [2, 31500, 2100, 400, 15300, 1], [3, 12800, 26400, 7800, 4200, 0],
		[4, 27400, 8800, 1200, 21000, 2], [5, 39900, 0, 0, 6100, 0], [6, 9100, 18800, 5100, 3900, 1]]

func _hero_info(hid: int) -> Array:
	if preview:
		var fake := [["Азурмос", "mage"], ["Торин", "warrior"], ["Лира", "priest"], ["Утер", "paladin"], ["Кель", "mage"], ["Мира", "priest"]]
		return fake[(hid - 1) % fake.size()]
	var h = world.heroes.get(hid, null)
	return [h.player_name, h.class_id] if h else ["?", "mage"]

func _process(_delta: float) -> void:
	if not visible:
		return
	if meter and SEGS[_seg][0] == "current":
		var want := "Бой: " + str(meter.view["current"]["name"])
		if _seg_btn.text != want:
			_seg_btn.text = want
	var d := _data()
	var rows: Array = d[0]
	var dur: float = maxf(1.0, d[1])
	var field_i: int = [1, 2, 4, 5][_mode]
	var list: Array = rows.filter(func(r): return float(r[field_i]) > 0.0)
	list.sort_custom(func(a, b): return float(a[field_i]) > float(b[field_i]))
	var total := 0.0
	for r in list:
		total += float(r[field_i])
	var top: float = float(list[0][field_i]) + (float(list[0][3]) if _mode == 1 else 0.0) if not list.is_empty() else 1.0
	# строки пересоздаются только при смене состава; значения — каждый кадр
	var ids := list.map(func(r): return r[0]).slice(0, _rows)
	if ids != _rows_cache:
		_rows_cache = ids
		for c in _list.get_children():
			c.queue_free()
		for hid in ids:
			_list.add_child(_make_row(hid))
	var i := 0
	for c in _list.get_children():
		if c.is_queued_for_deletion() or i >= list.size():
			continue
		var r: Array = list[i]
		var val := float(r[field_i])
		var bar: ColorRect = c.get_meta("bar")
		var over_bar: ColorRect = c.get_meta("over")
		var w := _w - 12.0
		bar.size = Vector2(w * clampf(val / maxf(top, 1.0), 0.0, 1.0), ROW_H)
		over_bar.position.x = bar.size.x
		over_bar.size = Vector2(w * clampf(float(r[3]) / maxf(top, 1.0), 0.0, 1.0) if _mode == 1 else 0.0, ROW_H)
		var info := _hero_info(int(r[0]))
		(c.get_meta("name") as Label).text = "%d. %s" % [i + 1, info[0]]
		var right := ""
		if _mode == 3:
			right = "%d" % int(val)
		else:
			right = "%s  (%s/с, %d%%)" % [fmt(val), fmt(val / dur), int(round(val / maxf(total, 1.0) * 100.0))]
			if _mode == 1 and float(r[3]) > 0.0:
				right = "%s  +%s" % [right, fmt(float(r[3]))]
		(c.get_meta("val") as Label).text = right
		i += 1
	if _detail.visible:
		_detail.global_position = global_position + Vector2(size.x + 6.0, 0.0)
		if _detail.global_position.x + _detail.size.x > get_viewport_rect().size.x:
			_detail.global_position.x = global_position.x - _detail.size.x - 6.0

func _make_row(hid: int) -> Control:
	var row := Control.new()
	row.custom_minimum_size = Vector2(_w - 12.0, ROW_H)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.color = Color(1, 1, 1, 0.05)
	bg.size = Vector2(_w - 12.0, ROW_H)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bg)
	var col: Color = GameData.CLASSES[_hero_info(hid)[1]]["color"]
	var bar := ColorRect.new()
	bar.color = col.darkened(0.25)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bar)
	var over := ColorRect.new()
	over.color = Color(col.r, col.g, col.b, 0.3)       # перелечивание — бледнее
	over.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(over)
	var name_l := Label.new()
	name_l.add_theme_font_size_override("font_size", 12)
	name_l.add_theme_color_override("font_outline_color", Color.BLACK)
	name_l.add_theme_constant_override("outline_size", 3)
	name_l.position = Vector2(4, 1)
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_l)
	var val_l := Label.new()
	val_l.add_theme_font_size_override("font_size", 12)
	val_l.add_theme_color_override("font_outline_color", Color.BLACK)
	val_l.add_theme_constant_override("outline_size", 3)
	val_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_l.position = Vector2(0, 1)
	val_l.size = Vector2(_w - 16.0, ROW_H)
	val_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(val_l)
	row.set_meta("bar", bar)
	row.set_meta("over", over)
	row.set_meta("name", name_l)
	row.set_meta("val", val_l)
	row.mouse_entered.connect(func():
		_hover_hid = hid
		if preview:
			_show_detail_text("%s\nОгненный шар  21,4к  44%%  (38, криты 9)\nОгненный столб  15,1к  31%%  (12, криты 3)\nАвтоатака  2,1к  4%%  (40, криты 6)" % _hero_info(hid)[0])
		elif meter:
			meter.send("request_detail", [SEGS[_seg][0], hid, MODES[_mode][0]]))
	row.mouse_exited.connect(func():
		if _hover_hid == hid:
			_hover_hid = 0
			_detail.visible = false)
	return row

func _on_detail() -> void:
	var d: Dictionary = meter.detail
	if int(d.get("hid", 0)) != _hover_hid or d.get("field", "") != MODES[_mode][0]:
		return
	var list: Array = d["list"]
	var total := 0.0
	for e in list:
		total += float(e[1])
	var lines := ["%s — %s" % [_hero_info(_hover_hid)[0], MODES[_mode][1].to_lower()]]
	if list.is_empty():
		lines.append("пока ничего")
	for e in list:
		var line := "%s  %s  %d%%" % [meter.key_name(e[0]), fmt(float(e[1])), int(round(float(e[1]) / maxf(total, 1.0) * 100.0))]
		if MODES[_mode][0] != "deaths":
			line += "  (%d, криты %d)" % [int(e[2]), int(e[3])]
		if MODES[_mode][0] == "heal" and float(e[4]) > 0.0:
			line += "  перелеч. %s" % fmt(float(e[4]))
		lines.append(line)
	_show_detail_text("\n".join(lines))

func _show_detail_text(text: String) -> void:
	_detail_l.text = text
	_detail.reset_size()
	_detail.visible = true
