extends Node3D
## Главное меню: выбор имени, класса и расы, одиночная игра, хост и подключение
## (по локальной сети или через Radmin VPN), лобби.

const SETTINGS_PATH := "user://settings.cfg"
const GOLD := Color(0.95, 0.78, 0.35)

var _cam: Camera3D
var _orbit := 0.0
var _preview: Node3D
var _preview_anchor := Vector3(0, 0, 16)

var _ui: Control
var _main_panel: PanelContainer
var _lobby_panel: PanelContainer
var _name_edit: LineEdit
var _class_buttons: Dictionary = {}
var _class_desc: Label
var _spell_row: HBoxContainer
var _talent_view: Control = null
var _race_option: OptionButton
var _race_desc: Label
var _waves_option: OptionButton
var _lanes_option: OptionButton
const LANE_NAMES := ["1 — только с юга", "2 — юг и восток", "3 — юг, восток и запад", "4 — со всех сторон"]
const WAVE_CHOICES := [1, 2, 3, 4, 5, 10, 20]
var _ip_edit: LineEdit
var _status: Label
var _lobby_list: VBoxContainer
var _lobby_info: Label
var _start_btn: Button
var _cli: Dictionary = {}

func _ready() -> void:
	_parse_cli()
	var map := (load("res://scenes/map.tscn") as PackedScene).instantiate()
	add_child(map)
	_cam = Camera3D.new()
	_cam.fov = 55
	_cam.far = 500
	add_child(_cam)
	_cam.current = true
	_place_camera()
	_build_ui()
	for b in _ui.find_children("*", "BaseButton", true, false):
		(b as BaseButton).pressed.connect(func(): Sfx.play("ui_click"))
	_load_settings()
	_update_preview()
	Net.players_changed.connect(_refresh_lobby)
	Net.connection_failed.connect(_on_fail)
	Net.disconnected.connect(_on_fail)
	multiplayer.connected_to_server.connect(func(): _show_lobby())
	_run_cli()

## Камера неподвижно смотрит на героя (он стоит справа от панели, на фоне — замок).
func _place_camera() -> void:
	var side := Vector3(-2.3, 0, 0)
	_cam.look_at_from_position(_preview_anchor + side + Vector3(0, 2.3, 8.8), _preview_anchor + side + Vector3(0, 1.3, 0))

# ---------------------------------------------------------------- интерфейс

func _style(border: Color = Color(0.55, 0.45, 0.25)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.05, 0.05, 0.08, 0.86)
	s.border_color = border
	s.set_border_width_all(2)
	s.set_corner_radius_all(8)
	s.set_content_margin_all(16)
	return s

func _label(text: String, size: int = 16, col: Color = Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_ui = Control.new()
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	var theme := Theme.new()
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Segoe UI", "Arial", "Tahoma"])
	f.font_weight = 600
	theme.default_font = f
	theme.default_font_size = 16
	_ui.theme = theme
	layer.add_child(_ui)

	var title := _label("HERO SIEGE", 54, GOLD)
	title.autowrap_mode = TextServer.AUTOWRAP_OFF
	title.position = Vector2(40, 24)
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	title.add_theme_constant_override("outline_size", 10)
	_ui.add_child(title)
	var sub := _label("Осада замка  •  кооператив до 6 героев", 18, Color(1, 1, 1, 0.85))
	sub.autowrap_mode = TextServer.AUTOWRAP_OFF
	sub.position = Vector2(44, 92)
	sub.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	sub.add_theme_constant_override("outline_size", 6)
	_ui.add_child(sub)

	_main_panel = PanelContainer.new()
	_main_panel.add_theme_stylebox_override("panel", _style())
	_main_panel.position = Vector2(40, 140)
	_main_panel.custom_minimum_size = Vector2(440, 0)
	_ui.add_child(_main_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 7)
	_main_panel.add_child(v)

	v.add_child(_label("Имя героя", 14, GOLD))
	_name_edit = LineEdit.new()
	_name_edit.max_length = 16
	_name_edit.text = "Герой"
	v.add_child(_name_edit)

	v.add_child(_label("Класс", 14, GOLD))
	var classes := HBoxContainer.new()
	classes.add_theme_constant_override("separation", 6)
	v.add_child(classes)
	var group := ButtonGroup.new()
	for cid in GameData.CLASSES:
		var b := Button.new()
		b.text = GameData.CLASSES[cid]["name"]
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(130, 40)
		b.add_theme_color_override("font_color", GameData.CLASSES[cid]["color"])
		b.add_theme_color_override("font_pressed_color", GameData.CLASSES[cid]["color"].lightened(0.3))
		b.pressed.connect(_on_class.bind(cid))
		classes.add_child(b)
		_class_buttons[cid] = b
	_class_desc = _label("", 14, Color(0.9, 0.9, 0.85))
	_class_desc.custom_minimum_size = Vector2(400, 44)
	v.add_child(_class_desc)
	_spell_row = HBoxContainer.new()
	_spell_row.add_theme_constant_override("separation", 4)
	v.add_child(_spell_row)
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 6)
	v.add_child(row1)
	var tal := Button.new()
	tal.text = "Таланты класса"
	tal.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tal.pressed.connect(_toggle_talents)
	row1.add_child(tal)
	var keys_btn := Button.new()
	keys_btn.text = "Горячие клавиши"
	keys_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	keys_btn.pressed.connect(_toggle_keys)
	row1.add_child(keys_btn)

	v.add_child(_label("Раса", 14, GOLD))
	_race_option = OptionButton.new()
	for rid in GameData.RACES:
		_race_option.add_item(GameData.RACES[rid]["name"])
		_race_option.set_item_metadata(_race_option.item_count - 1, rid)
	_race_option.item_selected.connect(func(_i): _update_preview())
	v.add_child(_race_option)
	_race_desc = _label("", 14, Color(0.9, 0.9, 0.85))
	v.add_child(_race_desc)

	v.add_child(_label("Длительность осады", 14, GOLD))
	_waves_option = OptionButton.new()
	for n in WAVE_CHOICES:
		var word := "волна" if n == 1 else ("волны" if n < 5 else "волн")
		var extra := "  — быстрая игра, в конце босс" if n < 5 else ("  — полная осада" if n == 20 else "")
		_waves_option.add_item("%d %s%s" % [n, word, extra])
		_waves_option.set_item_metadata(_waves_option.item_count - 1, n)
	_waves_option.select(WAVE_CHOICES.size() - 1)
	v.add_child(_waves_option)
	v.add_child(_label("Направления атаки", 14, GOLD))
	_lanes_option = OptionButton.new()
	for n in LANE_NAMES:
		_lanes_option.add_item(n)
	_lanes_option.select(3)
	v.add_child(_lanes_option)

	v.add_child(HSeparator.new())
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	v.add_child(row2)
	var solo := Button.new()
	solo.text = "Одиночная игра"
	solo.custom_minimum_size = Vector2(0, 42)
	solo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	solo.pressed.connect(_on_solo)
	row2.add_child(solo)
	var host := Button.new()
	host.text = "Создать игру (хост)"
	host.custom_minimum_size = Vector2(0, 42)
	host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host.pressed.connect(_on_host)
	row2.add_child(host)
	var jh := HBoxContainer.new()
	v.add_child(jh)
	_ip_edit = LineEdit.new()
	_ip_edit.placeholder_text = "IP хоста, например 26.12.34.56"
	_ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	jh.add_child(_ip_edit)
	var join := Button.new()
	join.text = "Подключиться"
	join.pressed.connect(_on_join)
	jh.add_child(join)
	_status = _label("", 14, Color(1, 0.6, 0.5))
	v.add_child(_status)
	var quit := Button.new()
	quit.text = "  Выход из игры  "
	quit.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	quit.position = Vector2(-170, 20)
	quit.pressed.connect(func(): get_tree().quit())
	_ui.add_child(quit)

	# лобби
	_lobby_panel = PanelContainer.new()
	_lobby_panel.add_theme_stylebox_override("panel", _style(GOLD))
	_lobby_panel.position = Vector2(40, 140)
	_lobby_panel.custom_minimum_size = Vector2(440, 0)
	_lobby_panel.visible = false
	_ui.add_child(_lobby_panel)
	var lv := VBoxContainer.new()
	lv.add_theme_constant_override("separation", 10)
	_lobby_panel.add_child(lv)
	lv.add_child(_label("Лобби", 24, GOLD))
	_lobby_info = _label("", 14, Color(0.85, 0.95, 1.0))
	lv.add_child(_lobby_info)
	lv.add_child(HSeparator.new())
	_lobby_list = VBoxContainer.new()
	lv.add_child(_lobby_list)
	lv.add_child(HSeparator.new())
	_start_btn = Button.new()
	_start_btn.text = "Начать осаду!"
	_start_btn.custom_minimum_size = Vector2(0, 44)
	_start_btn.pressed.connect(func(): Net.start_game())
	lv.add_child(_start_btn)
	var leave := Button.new()
	leave.text = "Покинуть лобби"
	leave.pressed.connect(func():
		Net.leave()
		_show_main())
	lv.add_child(leave)

# ---------------------------------------------------------------- выбор героя

func _selected_class() -> String:
	for cid in _class_buttons:
		if _class_buttons[cid].button_pressed:
			return cid
	return "mage"

func _selected_race() -> String:
	return _race_option.get_item_metadata(_race_option.selected)

func _on_class(_cid: String) -> void:
	_update_preview()

func _update_preview() -> void:
	var cid := _selected_class()
	var rid := _selected_race()
	_class_desc.text = GameData.CLASSES[cid]["desc"]
	for c in _spell_row.get_children():
		c.queue_free()
	for sid in GameData.CLASSES[cid]["spells"]:
		var cell := Panel.new()
		cell.custom_minimum_size = Vector2(46, 46)
		cell.tooltip_text = SpellIcon.tooltip(sid)
		var st := StyleBoxFlat.new()
		st.bg_color = Color(0, 0, 0, 0.6)
		st.border_color = GameData.SCHOOLS[GameData.SPELLS[sid]["school"]]["color"].darkened(0.2)
		st.set_border_width_all(2)
		st.set_corner_radius_all(5)
		cell.add_theme_stylebox_override("panel", st)
		var icon := SpellIcon.make(sid, 42)
		icon.position = Vector2(2, 2)
		cell.add_child(icon)
		var lvl := _label(str(GameData.spell_level(sid)), 12, Color(1, 0.95, 0.7))
		lvl.autowrap_mode = TextServer.AUTOWRAP_OFF
		lvl.add_theme_color_override("font_outline_color", Color(0, 0, 0))
		lvl.add_theme_constant_override("outline_size", 4)
		lvl.position = Vector2(30, 26)
		cell.add_child(lvl)
		_spell_row.add_child(cell)
	_race_desc.text = GameData.RACES[rid]["desc"]
	if _preview:
		_preview.queue_free()
	_preview = ModelFactory.build_hero(cid, rid)
	add_child(_preview)
	_preview.position = _preview_anchor
	_preview.rotation.y = PI + 0.3
	if _talent_view:
		_talent_view.queue_free()
		_talent_view = null
	var ap := ModelFactory.find_anim(_preview)
	if ap:
		ap.play("Idle")

var _keys_view: Control = null
func _toggle_keys() -> void:
	if _keys_view == null:
		_keys_view = preload("res://scripts/ui/keybind_window.gd").new()
		_ui.add_child(_keys_view)
		return
	_keys_view.visible = not _keys_view.visible

func _toggle_talents() -> void:
	if _talent_view == null:
		_talent_view = preload("res://scripts/ui/talent_window.gd").new()
		_talent_view.setup_preview(_selected_class())
		_ui.add_child(_talent_view)
		_talent_view.refresh()
		return
	_talent_view.visible = not _talent_view.visible
	if _talent_view.visible:
		_talent_view.refresh()

func _apply_local_info() -> void:
	var n := _name_edit.text.strip_edges()
	Net.local_info = {"name": n if n != "" else "Герой", "class": _selected_class(), "race": _selected_race()}
	Net.settings = {"waves": int(_waves_option.get_item_metadata(_waves_option.selected)), "lanes": _lanes_option.selected + 1}
	_save_settings()

# ---------------------------------------------------------------- сеть

func _on_solo() -> void:
	_apply_local_info()
	if Net.host_game(true) != OK:
		_status.text = "Не удалось запустить игру (порт %d занят?)" % Net.PORT
		return
	Net.start_game()

func _on_host() -> void:
	_apply_local_info()
	var err := Net.host_game(false)
	if err != OK:
		_status.text = "Не удалось создать игру: порт %d занят." % Net.PORT
		return
	_show_lobby()

func _on_join() -> void:
	_apply_local_info()
	var ip := _ip_edit.text.strip_edges()
	if ip == "":
		_status.text = "Введите IP хоста."
		return
	_status.text = "Подключение к %s..." % ip
	_status.add_theme_color_override("font_color", Color(0.8, 0.9, 1))
	if Net.join_game(ip) != OK:
		_on_fail("Неверный адрес.")

func _on_fail(reason: String) -> void:
	_show_main()
	_status.text = reason
	_status.add_theme_color_override("font_color", Color(1, 0.6, 0.5))

func _show_lobby() -> void:
	_main_panel.visible = false
	_lobby_panel.visible = true
	_refresh_lobby()

func _show_main() -> void:
	_main_panel.visible = true
	_lobby_panel.visible = false

func _refresh_lobby() -> void:
	if not _lobby_panel.visible:
		return
	for c in _lobby_list.get_children():
		c.queue_free()
	var ids := Net.players.keys()
	ids.sort()
	for pid in ids:
		var p: Dictionary = Net.players[pid]
		var cls: Dictionary = GameData.CLASSES[p["class"]]
		var l := _label("%s%s — %s, %s" % ["★ " if pid == 1 else "", p["name"], GameData.RACES[p["race"]]["name"], cls["name"]], 17, cls["color"])
		_lobby_list.add_child(l)
	if Net.is_server():
		var addrs := Net.local_addresses()
		_lobby_info.text = "Вы хост. Друзья подключаются по одному из адресов:\n%s\n(в Radmin VPN это адрес 26.x.x.x, порт %d)" % [", ".join(addrs), Net.PORT]
		_start_btn.visible = true
		_check_autostart()
	else:
		_lobby_info.text = "Ожидание, пока хост начнёт игру..."
		_start_btn.visible = false

# ---------------------------------------------------------------- настройки и запуск из командной строки

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		_name_edit.text = cfg.get_value("player", "name", "Герой")
		_ip_edit.text = cfg.get_value("net", "ip", "")
		var cid: String = cfg.get_value("player", "class", "mage")
		if _class_buttons.has(cid):
			_class_buttons[cid].button_pressed = true
		_lanes_option.select(clampi(int(cfg.get_value("game", "lanes", 4)), 1, 4) - 1)
		var waves: int = cfg.get_value("game", "waves", 20)
		var wi := WAVE_CHOICES.find(waves)
		if wi >= 0:
			_waves_option.select(wi)
		var rid: String = cfg.get_value("player", "race", "human")
		for i in _race_option.item_count:
			if _race_option.get_item_metadata(i) == rid:
				_race_option.select(i)
	if _selected_class() == "mage" and not _class_buttons["mage"].button_pressed:
		_class_buttons["mage"].button_pressed = true

func _save_settings() -> void:
	if not _cli.is_empty():
		return   # тестовые запуски не трогают настройки игрока
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("player", "name", Net.local_info["name"])
	cfg.set_value("player", "class", Net.local_info["class"])
	cfg.set_value("player", "race", Net.local_info["race"])
	cfg.set_value("net", "ip", _ip_edit.text.strip_edges())
	cfg.set_value("game", "waves", Net.settings.get("waves", 20))
	cfg.set_value("game", "lanes", Net.settings.get("lanes", 4))
	cfg.save(SETTINGS_PATH)

func _parse_cli() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		_cli[kv[0]] = kv[1] if kv.size() > 1 else "1"
	Net.cli = _cli

func _run_cli() -> void:
	if _cli.is_empty():
		return
	if _cli.has("name"):
		_name_edit.text = _cli["name"]
	if _cli.has("class") and _class_buttons.has(_cli["class"]):
		_class_buttons[_cli["class"]].button_pressed = true
	if _cli.has("race"):
		for i in _race_option.item_count:
			if _race_option.get_item_metadata(i) == _cli["race"]:
				_race_option.select(i)
	if _cli.has("menutalents"):
		_toggle_talents.call_deferred()
	if _cli.has("lanes"):
		_lanes_option.select(clampi(int(_cli["lanes"]), 1, 4) - 1)
	if _cli.has("waves"):
		var wi := WAVE_CHOICES.find(int(_cli["waves"]))
		if wi >= 0:
			_waves_option.select(wi)
	_update_preview()
	if _cli.has("solo"):
		_on_solo()
	elif _cli.has("host"):
		_on_host()
	elif _cli.has("join"):
		_ip_edit.text = _cli["join"]
		_on_join()

func _check_autostart() -> void:
	if _cli.has("autostart") and Net.players.size() >= int(_cli["autostart"]):
		Net.start_game()

## --menushot=путь: снимок меню (для проверки внешнего вида).
func _notification(what: int) -> void:
	if what == NOTIFICATION_READY and _cli.has("menushot"):
		await get_tree().create_timer(1.5).timeout
		get_viewport().get_texture().get_image().save_png(_cli["menushot"])
		get_tree().quit()
