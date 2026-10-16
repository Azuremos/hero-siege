extends Node3D
## Главное меню в духе больших игр: Одиночная игра, Сетевая игра, Таланты классов, Настройки, Об игре, Выход.
## Экран героя (имя, класс, раса) общий для одиночной и сетевой игры. Лобби для игры по сети (Radmin VPN).

const SETTINGS_PATH := "user://settings.cfg"
const GOLD := Color(0.95, 0.78, 0.35)
const LANE_NAMES := ["1 — только с юга", "2 — юг и восток", "3 — юг, восток и запад", "4 — со всех сторон"]
const WAVE_CHOICES := [1, 2, 3, 4, 5, 10, 20, 30, 50, 0]
const BREAK_CHOICES := [30, 60, 90]

var _cam: Camera3D
var _preview: Node3D
var _preview_anchor := Vector3(0, 0, 16)

var _ui: Control
var _screens: Dictionary = {}          # имя -> Control
var _mode := "solo"                    # solo | net — какой экран героя открыт
var _name_edit: LineEdit
var _class_buttons: Dictionary = {}
var _class_desc: Label
var _spell_row: HBoxContainer
var _race_option: OptionButton
var _race_desc: Label
var _waves_option: OptionButton
var _lanes_option: OptionButton
var _break_option: OptionButton
var _marks_check: CheckBox
var _faction_option: OptionButton
## Фракции: [режим, подпись, фракция для «одной везде»]
const FACTION_CHOICES := [["sides", "По сторонам света", ""], ["random", "Случайно по сторонам", ""],
	["single", "Только нежить", "undead"], ["single", "Только орки", "orcs"], ["single", "Только демоны", "demons"],
	["single", "Только гоблины и огры", "goblins"]]
var _ip_edit: LineEdit
var _status: Label
var _solo_box: Control
var _net_box: Control
var _lobby_list: VBoxContainer
var _lobby_info: Label
var _start_btn: Button
var _talent_view: Control = null
var _talent_class := "mage"
var _keys_view: Control = null
var _settings_view: Control = null
var _cli: Dictionary = {}
var _reconnect_btn: Button
var _camp_box: HBoxContainer
var _camp_list: VBoxContainer
var _camp_ip: LineEdit
var _camp_char: Dictionary = {}
var _sieges_box: VBoxContainer
var _del_armed := ""

func _ready() -> void:
	_parse_cli()
	if Net.cli.has("heroshot"):
		# снимок героев в снаряжении вместо меню (tools/hero_shot.gd)
		add_child(preload("res://tools/hero_shot.gd").new())
		return
	var map := (load("res://scenes/map.tscn") as PackedScene).instantiate()
	add_child(map)
	var roads := map.get_node_or_null("Roads") as MeshInstance3D
	if roads:
		var mat := ShaderMaterial.new()
		mat.shader = load("res://shaders/cobblestone.gdshader")
		roads.material_override = mat
	Settings.apply_shadows(map.get_node_or_null("Sun") as DirectionalLight3D)
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
	_show("main")
	Net.players_changed.connect(_refresh_lobby)
	Net.connection_failed.connect(_on_fail)
	Net.disconnected.connect(_on_fail)
	multiplayer.connected_to_server.connect(func(): _show("lobby"))
	Sfx.play_music("menu")
	_run_cli()

## Камера неподвижно смотрит на героя (он стоит справа от меню, на фоне — замок).
func _place_camera() -> void:
	var side := Vector3(-2.3, 0, 0)
	_cam.look_at_from_position(_preview_anchor + side + Vector3(0, 2.3, 8.8), _preview_anchor + side + Vector3(0, 1.3, 0))

# ---------------------------------------------------------------- построение

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

func _panel(name_id: String, width: float) -> VBoxContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _style())
	p.position = Vector2(40, 140)
	p.custom_minimum_size = Vector2(width, 0)
	_ui.add_child(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	p.add_child(v)
	_screens[name_id] = p
	return v

func _big_button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(320, 52)
	b.add_theme_font_size_override("font_size", 20)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_ui = Control.new()
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE      # свободное место — вращение героя на подиуме
	var theme := Theme.new()
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Segoe UI", "Arial", "Tahoma"])
	f.font_weight = 600
	theme.default_font = f
	theme.default_font_size = 16
	_ui.theme = theme
	layer.add_child(_ui)

	var title := _label("HERO SIEGE", 58, GOLD)
	title.autowrap_mode = TextServer.AUTOWRAP_OFF
	title.position = Vector2(40, 22)
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	title.add_theme_constant_override("outline_size", 10)
	_ui.add_child(title)
	var sub := _label("Осада замка  •  кооператив до 6 героев", 18, Color(1, 1, 1, 0.85))
	sub.autowrap_mode = TextServer.AUTOWRAP_OFF
	sub.position = Vector2(44, 96)
	sub.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	sub.add_theme_constant_override("outline_size", 6)
	_ui.add_child(sub)
	var ver := _label("Версия %s" % Net.game_version(), 14, Color(1, 1, 1, 0.6))
	ver.autowrap_mode = TextServer.AUTOWRAP_OFF
	ver.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	ver.add_theme_constant_override("outline_size", 4)
	_ui.add_child(ver)
	ver.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 12)
	ver.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	ver.grow_vertical = Control.GROW_DIRECTION_BEGIN

	# --- главный экран
	var m := _panel("main", 360)
	_big_button(m, "Одиночная игра", func(): _open_hero("solo"))
	_big_button(m, "Сетевая игра", func(): _open_hero("net"))
	_big_button(m, "Поход (свои герои)", _show_campaign)
	_big_button(m, "Продолжить осаду", _show_sieges)
	_reconnect_btn = _big_button(m, "Переподключиться", _on_reconnect)
	_reconnect_btn.visible = bool(Net.profile_get("unclean", false)) and str(Net.profile_get("last_host", "")) != ""
	_reconnect_btn.tooltip_text = "Партия оборвалась — вернуться к хосту %s тем же героем" % str(Net.profile_get("last_host", ""))
	_big_button(m, "Таланты классов", func(): _show("talents"))
	_big_button(m, "Настройки", _toggle_settings)
	_big_button(m, "Настроить интерфейс", _start_ui_preview)
	_big_button(m, "Об игре", func(): _show("about"))
	_big_button(m, "Выход", func(): Sfx.quit_game())

	# --- экран героя (общий для одиночной и сетевой игры)
	var h := _panel("hero", 460)
	h.add_child(_label("Имя героя", 14, GOLD))
	_name_edit = LineEdit.new()
	_name_edit.max_length = 16
	_name_edit.text = "Герой"
	h.add_child(_name_edit)
	h.add_child(_label("Класс", 14, GOLD))
	var classes := HBoxContainer.new()
	classes.add_theme_constant_override("separation", 6)
	h.add_child(classes)
	var group := ButtonGroup.new()
	for cid in GameData.CLASSES:
		var b := Button.new()
		b.text = GameData.CLASSES[cid]["name"]
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(102, 38)
		b.add_theme_color_override("font_color", GameData.CLASSES[cid]["color"])
		b.add_theme_color_override("font_pressed_color", GameData.CLASSES[cid]["color"].lightened(0.3))
		b.pressed.connect(func(): _update_preview())
		classes.add_child(b)
		_class_buttons[cid] = b
	_class_desc = _label("", 14, Color(0.9, 0.9, 0.85))
	_class_desc.custom_minimum_size = Vector2(420, 40)
	h.add_child(_class_desc)
	_spell_row = HBoxContainer.new()
	_spell_row.add_theme_constant_override("separation", 3)
	h.add_child(_spell_row)
	h.add_child(_label("Раса", 14, GOLD))
	_race_option = OptionButton.new()
	for rid in GameData.RACES:
		_race_option.add_item(GameData.RACES[rid]["name"])
		_race_option.set_item_metadata(_race_option.item_count - 1, rid)
	_race_option.item_selected.connect(func(_i): _update_preview())
	h.add_child(_race_option)
	_race_desc = _label("", 14, Color(0.9, 0.9, 0.85))
	h.add_child(_race_desc)
	h.add_child(HSeparator.new())
	# настройки партии (одиночная игра и хост)
	var opts := GridContainer.new()
	opts.columns = 2
	opts.add_theme_constant_override("h_separation", 10)
	h.add_child(opts)
	var l_w := _label("Длительность", 14, GOLD)
	l_w.autowrap_mode = TextServer.AUTOWRAP_OFF
	opts.add_child(l_w)
	_waves_option = OptionButton.new()
	for n in WAVE_CHOICES:
		var text := "Бесконечная осада" if n == 0 else "%d %s" % [n, "волна" if n == 1 else ("волны" if n < 5 else "волн")]
		if n > 0 and n < 5:
			text += " — быстрая, в конце босс"
		elif n == 20:
			text += " — полная осада"
		_waves_option.add_item(text)
		_waves_option.set_item_metadata(_waves_option.item_count - 1, n)
	_waves_option.select(WAVE_CHOICES.find(20))
	_waves_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opts.add_child(_waves_option)
	var l_l := _label("Направления", 14, GOLD)
	l_l.autowrap_mode = TextServer.AUTOWRAP_OFF
	opts.add_child(l_l)
	_lanes_option = OptionButton.new()
	for n in LANE_NAMES:
		_lanes_option.add_item(n)
	_lanes_option.select(3)
	_lanes_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opts.add_child(_lanes_option)
	var l_b := _label("Передышка", 14, GOLD)
	l_b.autowrap_mode = TextServer.AUTOWRAP_OFF
	opts.add_child(l_b)
	_break_option = OptionButton.new()
	for n in BREAK_CHOICES:
		_break_option.add_item("%d сек. каждые 3 волны" % n)
		_break_option.set_item_metadata(_break_option.item_count - 1, n)
	_break_option.select(BREAK_CHOICES.find(60))
	_break_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opts.add_child(_break_option)
	var l_f := _label("Фракции", 14, GOLD)
	l_f.autowrap_mode = TextServer.AUTOWRAP_OFF
	opts.add_child(l_f)
	_faction_option = OptionButton.new()
	for fo in FACTION_CHOICES:
		_faction_option.add_item(fo[1])
	_faction_option.tooltip_text = "По сторонам: юг — нежить, восток — орки, запад — демоны, север — гоблины и огры"
	_faction_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opts.add_child(_faction_option)
	# действия: одиночная
	_camp_box = HBoxContainer.new()      # «Поход»: создать героя с выбранными именем, классом и расой
	h.add_child(_camp_box)
	var mk := Button.new()
	mk.text = "Создать героя"
	mk.custom_minimum_size = Vector2(0, 44)
	mk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mk.pressed.connect(func():
		_apply_local_info()
		CharacterStore.create(Net.local_info["name"], Net.local_info["class"], Net.local_info["race"])
		_show_campaign())
	_camp_box.add_child(mk)
	_solo_box = HBoxContainer.new()
	_solo_box.add_theme_constant_override("separation", 6)
	h.add_child(_solo_box)
	var start := Button.new()
	start.text = "Начать осаду"
	start.custom_minimum_size = Vector2(0, 44)
	start.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	start.pressed.connect(_on_solo)
	_solo_box.add_child(start)
	# действия: сетевая
	var net := VBoxContainer.new()
	net.add_theme_constant_override("separation", 6)
	h.add_child(net)
	_net_box = net
	_marks_check = CheckBox.new()
	_marks_check.text = "Метки целей ставит только хост"
	_marks_check.tooltip_text = "Иначе метки (Ctrl+1…8) может ставить любой игрок"
	net.add_child(_marks_check)
	var host := Button.new()
	host.text = "Создать игру (хост)"
	host.custom_minimum_size = Vector2(0, 42)
	host.pressed.connect(_on_host)
	net.add_child(host)
	var jh := HBoxContainer.new()
	net.add_child(jh)
	_ip_edit = LineEdit.new()
	_ip_edit.placeholder_text = "IP хоста, например 26.12.34.56"
	_ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	jh.add_child(_ip_edit)
	var join := Button.new()
	join.text = "Подключиться"
	join.pressed.connect(_on_join)
	jh.add_child(join)
	_status = _label("", 14, Color(1, 0.6, 0.5))
	h.add_child(_status)
	var back := Button.new()
	back.text = "Назад"
	back.pressed.connect(func(): _show("main"))
	h.add_child(back)

	# --- лобби
	var lv := _panel("lobby", 460)
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
		_show("main"))
	lv.add_child(leave)

	# --- таланты классов
	var tv := _panel("talents", 360)
	tv.add_child(_label("Таланты классов", 22, GOLD))
	tv.add_child(_label("Выберите класс — откроется его дерево талантов. Можно спланировать раскладку на 30 уровне.", 14, Color(0.9, 0.9, 0.85)))
	for cid in GameData.CLASSES:
		var b := Button.new()
		b.text = GameData.CLASSES[cid]["name"]
		b.custom_minimum_size = Vector2(0, 40)
		b.add_theme_color_override("font_color", GameData.CLASSES[cid]["color"])
		var c: String = cid
		b.pressed.connect(func(): _open_talents(c))
		tv.add_child(b)
	var tback := Button.new()
	tback.text = "Назад"
	tback.pressed.connect(func():
		if _talent_view:
			_talent_view.visible = false
		_show("main"))
	tv.add_child(tback)

	# --- об игре
	var ab := _panel("about", 560)
	ab.add_child(_label("Об игре", 22, GOLD))
	ab.add_child(_label("Hero Siege — кооперативная защита замка в духе карт Warcraft 3 с управлением как в World of Warcraft. Движок Godot 4.", 15))
	ab.add_child(_label("""Модели: KayKit (Kay Lousberg, CC0).
Иконки: game-icons.net — Lorc, Delapouite и другие (CC BY 3.0).
Звуки: rubberduck, bart, IgnasD, Kenney (CC0); DoKashiteru, spookymodem (CC BY 3.0).
Музыка: cynicmusic, RandomMind (CC0).""", 14, Color(0.85, 0.85, 0.85)))
	var aback := Button.new()
	aback.text = "Назад"
	aback.pressed.connect(func(): _show("main"))
	ab.add_child(aback)

func _show(screen: String) -> void:
	for s in _screens:
		_screens[s].visible = s == screen
	if screen == "lobby":
		_refresh_lobby()

func _open_hero(mode: String) -> void:
	_mode = mode
	_solo_box.visible = mode == "solo"
	_camp_box.visible = mode == "campaign"
	_net_box.visible = mode == "net"
	_status.text = ""
	_show("hero")

# ---------------------------------------------------------------- выбор героя

func _selected_class() -> String:
	for cid in _class_buttons:
		if _class_buttons[cid].button_pressed:
			return cid
	return "mage"

func _selected_race() -> String:
	return _race_option.get_item_metadata(_race_option.selected)

func _update_preview() -> void:
	var cid := _selected_class()
	var rid := _selected_race()
	_class_desc.text = GameData.CLASSES[cid]["desc"]
	for c in _spell_row.get_children():
		c.queue_free()
	for sid in GameData.CLASSES[cid]["spells"]:
		var cell := Panel.new()
		cell.custom_minimum_size = Vector2(38, 38)
		cell.tooltip_text = SpellIcon.tooltip(sid)
		var st := StyleBoxFlat.new()
		st.bg_color = Color(0, 0, 0, 0.6)
		st.border_color = GameData.SCHOOLS[GameData.SPELLS[sid]["school"]]["color"].darkened(0.2)
		st.set_border_width_all(2)
		st.set_corner_radius_all(5)
		cell.add_theme_stylebox_override("panel", st)
		var icon := SpellIcon.make(sid, 34)
		icon.position = Vector2(2, 2)
		cell.add_child(icon)
		var lvl := _label(str(GameData.spell_level(sid)), 11, Color(1, 0.95, 0.7))
		lvl.autowrap_mode = TextServer.AUTOWRAP_OFF
		lvl.add_theme_color_override("font_outline_color", Color(0, 0, 0))
		lvl.add_theme_constant_override("outline_size", 4)
		lvl.position = Vector2(24, 20)
		cell.add_child(lvl)
		_spell_row.add_child(cell)
	_race_desc.text = GameData.RACES[rid]["desc"]
	if _preview:
		_preview.queue_free()
	_preview = ModelFactory.build_hero(cid, rid)
	add_child(_preview)
	_preview.position = _preview_anchor
	_preview.rotation.y = _preview_yaw
	var ap := ModelFactory.find_anim(_preview)
	if ap:
		ap.play("Idle")

func _open_talents(cid: String) -> void:
	if _talent_view:
		_talent_view.queue_free()
	_talent_view = preload("res://scripts/ui/talent_window.gd").new()
	_talent_view.setup_preview(cid)
	_ui.add_child(_talent_view)
	_talent_view.refresh()

func _toggle_settings() -> void:
	if _settings_view == null:
		_settings_view = preload("res://scripts/ui/settings_window.gd").new()
		_settings_view.on_keys = func():
			_settings_view.visible = false
			_toggle_keys()
		_ui.add_child(_settings_view)
		return
	_settings_view.visible = not _settings_view.visible

func _toggle_keys() -> void:
	if _keys_view == null:
		_keys_view = preload("res://scripts/ui/keybind_window.gd").new()
		_ui.add_child(_keys_view)
		return
	_keys_view.visible = not _keys_view.visible

func _apply_local_info() -> void:
	var n := _name_edit.text.strip_edges()
	Net.local_info = {"name": n if n != "" else "Герой", "class": _selected_class(), "race": _selected_race(), "uid": Net.uid}
	Net.settings = {"waves": int(_waves_option.get_item_metadata(_waves_option.selected)), "lanes": _lanes_option.selected + 1,
		"break": int(_break_option.get_item_metadata(_break_option.selected)),
		"marks_host_only": _marks_check.button_pressed or _cli.has("markshost"),
		"factions": FACTION_CHOICES[_faction_option.selected][0], "faction": FACTION_CHOICES[_faction_option.selected][2],
		"seed": randi(), "siege_id": Net.new_uid().substr(0, 12), "late_join": true}
	Net.pending_siege = {}
	_save_settings()

# ---------------------------------------------------------------- сеть

## Предпросмотр интерфейса: облегчённая одиночная сцена (режим preview) с группой из 6 героев,
## врагом в цели и примером данных — рамки двигаются так же, как в игре, и сохраняются туда же.
func _start_ui_preview() -> void:
	_apply_local_info()
	Net.settings = {"mode": "preview", "waves": 20, "lanes": 4, "break": 60}
	if Net.host_game(true) != OK:
		_status.text = "Не удалось открыть предпросмотр"
		return
	var fake := [["Торин", "warrior"], ["Лира", "priest"], ["Утер", "paladin"], ["Кель", "mage"], ["Мира", "priest"]]
	for i in fake.size():
		Net.players[100 + i] = {"name": fake[i][0], "class": fake[i][1], "race": "human", "version": Net.game_version()}
	Net.start_game()

func _on_solo() -> void:
	_apply_local_info()
	if Net.host_game(true) != OK:
		_status.text = "Не удалось запустить игру (порт %d занят?)" % Net.port()
		return
	Net.start_game()

func _on_host() -> void:
	_apply_local_info()
	var err := Net.host_game(false)
	if err != OK:
		_status.text = "Не удалось создать игру: порт %d занят." % Net.port()
		return
	_show("lobby")

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
	_open_hero("net")
	_status.text = reason
	if not Net.cli.is_empty():
		print("NET FAIL: ", reason.replace("
", " "))
	_status.add_theme_color_override("font_color", Color(1, 0.6, 0.5))

func _refresh_lobby() -> void:
	if not _screens.has("lobby") or not _screens["lobby"].visible:
		return
	for c in _lobby_list.get_children():
		c.queue_free()
	var ids := Net.players.keys()
	ids.sort()
	for pid in ids:
		var p: Dictionary = Net.players[pid]
		var cls: Dictionary = GameData.CLASSES[p["class"]]
		if pid < 0:
			# продолженная осада: место игрока, который ещё не зашёл
			_lobby_list.add_child(_label("ждём %s — %s, %s" % [p["name"], GameData.RACES[p["race"]]["name"], cls["name"]], 17, Color(0.6, 0.6, 0.6)))
			continue
		var l := _label("%s%s — %s, %s  ·  v%s" % ["★ " if pid == 1 else "", p["name"], GameData.RACES[p["race"]]["name"], cls["name"],
			p.get("version", "?")], 17, cls["color"])
		_lobby_list.add_child(l)
	if Net.lobby_notice != "":
		_lobby_list.add_child(_label(Net.lobby_notice, 14, Color(1, 0.6, 0.5)))
	if Net.is_server():
		var addrs := Net.local_addresses()
		var w: int = Net.settings.get("waves", 20)
		_lobby_info.text = "Вы хост. Друзья подключаются по одному из адресов:\n%s\n(в Radmin VPN это адрес 26.x.x.x, порт %d)\nОсада: %s, направлений: %d, передышка: %d сек." % [
			", ".join(addrs), Net.port(), "бесконечная" if w == 0 else "%d волн" % w, int(Net.settings.get("lanes", 4)), int(Net.settings.get("break", 60))]
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
		var wi := WAVE_CHOICES.find(int(cfg.get_value("game", "waves", 20)))
		if wi >= 0:
			_waves_option.select(wi)
		var bi := BREAK_CHOICES.find(int(cfg.get_value("game", "break", 60)))
		if bi >= 0:
			_break_option.select(bi)
		var rid: String = cfg.get_value("player", "race", "human")
		for i in _race_option.item_count:
			if _race_option.get_item_metadata(i) == rid:
				_race_option.select(i)
	if not _class_buttons[_selected_class()].button_pressed:
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
	cfg.set_value("game", "break", Net.settings.get("break", 60))
	cfg.save(SETTINGS_PATH)

func _parse_cli() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		_cli[kv[0]] = kv[1] if kv.size() > 1 else "1"
	Net.cli = _cli
	if _cli.has("playerid"):
		Net.uid = str(_cli["playerid"])      # тест: свой id игрока (переподключение тем же игроком)

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
		_show("talents")
		_open_talents.call_deferred(_cli.get("class", "mage"))
	if _cli.has("menuscreen"):
		if _cli["menuscreen"] == "hero":
			_open_hero("solo")
		elif _cli["menuscreen"] == "settings":
			_toggle_settings()
		else:
			_show(_cli["menuscreen"])
	if _cli.has("lanes"):
		_lanes_option.select(clampi(int(_cli["lanes"]), 1, 4) - 1)
	if _cli.has("waves"):
		var wi := WAVE_CHOICES.find(int(_cli["waves"]))
		if wi >= 0:
			_waves_option.select(wi)
	if _cli.has("breaktime"):
		var bi := BREAK_CHOICES.find(int(_cli["breaktime"]))
		if bi >= 0:
			_break_option.select(bi)
	_update_preview()
	if _cli.has("uipreview"):
		_start_ui_preview()
		return
	if _cli.get("mode", "") == "campaign":
		# --mode=campaign --character=<id>|new (new — из --name, --class, --race) и --solo | --host | --join=IP
		var cid: String = str(_cli.get("character", "new"))
		if cid == "new":
			_apply_local_info()
			_camp_char = CharacterStore.create(Net.local_info["name"], Net.local_info["class"], Net.local_info["race"])
			print("CHARACTER ", _camp_char["id"])
		else:
			_camp_char = CharacterStore.load_one(cid)
		_show_campaign()
		if _cli.has("join"):
			_camp_ip.text = str(_cli["join"])
		_campaign_start("solo" if _cli.has("solo") else ("join" if _cli.has("join") else "host"))
		return
	if _cli.has("continue"):
		# --continue=last | <id>: загрузить сохранённую осаду (с --autostart=N — сетевая, ждёт N игроков)
		var sl := SiegeSave.list()
		var csid: String = (str(sl[0]["id"]) if not sl.is_empty() else "") if _cli["continue"] == "last" else str(_cli["continue"])
		_continue_siege(csid)
		return
	if _cli.has("solo"):
		_on_solo()
	elif _cli.has("host"):
		_on_host()
	elif _cli.has("join"):
		_ip_edit.text = _cli["join"]
		_on_join()

func _check_autostart() -> void:
	if _cli.has("autostart") and Net.players.keys().filter(func(k): return k > 0).size() >= int(_cli["autostart"]):
		Net.start_game()

## --menushot=путь: снимок меню (для проверки внешнего вида).
func _notification(what: int) -> void:
	if what == NOTIFICATION_READY and _cli.has("menushot"):
		await get_tree().create_timer(1.5).timeout
		get_viewport().get_texture().get_image().save_png(_cli["menushot"])
		Sfx.quit_game()

# ---------------------------------------------------------------- вращение героя на подиуме
var _preview_yaw := PI + 0.3
var _drag_preview := false

## Зажать ЛКМ на свободном месте экрана и вести — герой на подиуме поворачивается.
func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_drag_preview = (ev as InputEventMouseButton).pressed
	elif ev is InputEventMouseMotion and _drag_preview and _preview:
		_preview_yaw += (ev as InputEventMouseMotion).relative.x * 0.012
		_preview.rotation.y = _preview_yaw

# ---------------------------------------------------------------- продолжить осаду, переподключиться (сессия 07)

## Партия оборвалась: вернуться к тому же хосту (герой ждёт по uid игрока).
func _on_reconnect() -> void:
	_apply_local_info()
	_ip_edit.text = str(Net.profile_get("last_host", ""))
	_open_hero("net")
	_on_join()

## Список сохранённых осад хоста: дата, отбито волн, отряд. «Продолжить» — лобби ждёт тех же игроков.
func _show_sieges() -> void:
	if not _screens.has("sieges"):
		var v := _panel("sieges", 560)
		v.add_child(_label("Продолжить осаду", 24, GOLD))
		v.add_child(_label("Осады сохраняются сами после каждой волны и по кнопке «Сохранить осаду и выйти» в меню (Esc). Друзья заходят как обычно — каждый получит своего героя из сохранения.", 14, Color(0.9, 0.9, 0.85)))
		_sieges_box = VBoxContainer.new()
		_sieges_box.add_theme_constant_override("separation", 6)
		v.add_child(_sieges_box)
		var back := Button.new()
		back.text = "Назад"
		back.pressed.connect(func(): _show("main"))
		v.add_child(back)
	for c in _sieges_box.get_children():
		c.queue_free()
	var list := SiegeSave.list()
	if list.is_empty():
		_sieges_box.add_child(_label("Сохранённых осад пока нет.", 15, Color(0.7, 0.7, 0.7)))
	for d: Dictionary in list:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var w: int = int(d["settings"].get("waves", 20))
		var names: Array = d["party"].map(func(p): return "%s (%s %d)" % [p["name"], GameData.CLASSES[p["class"]]["name"], int(p["level"])])
		var l := _label("%s\nОтбито волн: %d из %s  ·  %s" % [str(d["date"]).replace("T", " "), int(d["wave"]), "∞" if w == 0 else str(w), ", ".join(names)], 14, Color.WHITE)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		var go := Button.new()
		go.text = "Продолжить"
		var sid: String = d["id"]
		go.pressed.connect(func(): _continue_siege(sid))
		row.add_child(go)
		var del := Button.new()
		del.text = "Удалить"
		del.pressed.connect(func():
			if _del_armed != sid:
				_del_armed = sid
				del.text = "Точно удалить?"
				return
			SiegeSave.remove(sid)
			_del_armed = ""
			_show_sieges())
		row.add_child(del)
		_sieges_box.add_child(row)
	_show("sieges")

## Загрузить осаду: одиночную — сразу в бой, сетевую — лобби с местами «ждём <имя>» для остальных игроков.
func _continue_siege(sid: String) -> void:
	var d := SiegeSave.load_file(sid)
	if d.is_empty():
		_status.text = "Сохранение повреждено"
		return
	_apply_local_info()
	var me: Dictionary = d["party"][0]
	for p in d["party"]:
		if p["uid"] == Net.uid:
			me = p
	Net.local_info["class"] = me["class"]
	Net.local_info["race"] = me["race"]
	Net.local_info["name"] = me["name"]
	Net.local_info["uid"] = me["uid"]       # хост — тот же игрок, что сохранял (его герой в сохранении)
	var solo: bool = d["party"].size() == 1 and bool(d.get("solo", false))
	if Net.host_game(solo) != OK:
		_status.text = "Не удалось запустить игру (порт %d занят?)" % Net.port()
		return
	Net.settings = d["settings"].duplicate()
	Net.settings["siege_id"] = sid
	Net.pending_siege = d
	var i := 1
	for p in d["party"]:
		if p["uid"] == me["uid"]:
			continue
		Net.players[-i] = {"name": p["name"], "class": p["class"], "race": p["race"], "uid": p["uid"], "offline": true, "version": Net.game_version()}
		i += 1
	if solo:
		Net.start_game()
	else:
		_show("lobby")

# ---------------------------------------------------------------- «Поход»: свои герои (сессия 07)

## Список своих героев: выбрать (герой встаёт на подиум), создать, удалить; в поход — одному, хостом или к другу.
func _show_campaign() -> void:
	if not _screens.has("campaign"):
		var v := _panel("campaign", 520)
		v.add_child(_label("Поход", 24, GOLD))
		v.add_child(_label("Свои герои растут от осады к осаде: уровень, вещи, таланты, золото. Каждая победа поднимает уровень угрозы — враги сильнее, добыча лучше. Обычная осада этих героев не трогает.", 14, Color(0.9, 0.9, 0.85)))
		_camp_list = VBoxContainer.new()
		_camp_list.add_theme_constant_override("separation", 6)
		v.add_child(_camp_list)
		var mk := Button.new()
		mk.text = "Новый герой…"
		mk.pressed.connect(func(): _open_hero("campaign"))
		v.add_child(mk)
		v.add_child(HSeparator.new())
		var go1 := Button.new()
		go1.text = "В поход одному"
		go1.custom_minimum_size = Vector2(0, 42)
		go1.pressed.connect(func(): _campaign_start("solo"))
		v.add_child(go1)
		var go2 := Button.new()
		go2.text = "Создать игру (хост)"
		go2.pressed.connect(func(): _campaign_start("host"))
		v.add_child(go2)
		var jh := HBoxContainer.new()
		v.add_child(jh)
		_camp_ip = LineEdit.new()
		_camp_ip.placeholder_text = "IP хоста"
		_camp_ip.text = str(Net.profile_get("last_host", ""))
		_camp_ip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		jh.add_child(_camp_ip)
		var jb := Button.new()
		jb.text = "Подключиться"
		jb.pressed.connect(func(): _campaign_start("join"))
		jh.add_child(jb)
		var back := Button.new()
		back.text = "Назад"
		back.pressed.connect(func(): _show("main"))
		v.add_child(back)
	for c in _camp_list.get_children():
		c.queue_free()
	var chars := CharacterStore.list()
	if chars.is_empty():
		_camp_list.add_child(_label("Героев пока нет — создайте первого.", 15, Color(0.7, 0.7, 0.7)))
	if not _camp_char.is_empty() and not chars.any(func(c): return c["id"] == _camp_char["id"]):
		_camp_char = {}
	if _camp_char.is_empty() and not chars.is_empty():
		_camp_char = chars[0]
	for d: Dictionary in chars:
		var row := HBoxContainer.new()
		var cls: Dictionary = GameData.CLASSES[d["class"]]
		var pick := Button.new()
		pick.toggle_mode = true
		pick.button_pressed = d["id"] == _camp_char.get("id", "")
		pick.text = "%s — %s, %s, %d ур.  ·  угроза %d  ·  золото %d" % [d["name"], GameData.RACES[d["race"]]["name"], cls["name"], int(d["level"]), int(d["threat"]), int(d["gold"])]
		pick.add_theme_color_override("font_color", cls["color"])
		pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var cd: Dictionary = d
		pick.pressed.connect(func():
			_camp_char = cd
			_show_campaign())
		row.add_child(pick)
		var del := Button.new()
		del.text = "Удалить"
		var cid: String = d["id"]
		del.pressed.connect(func():
			if _del_armed != cid:
				_del_armed = cid
				del.text = "Точно?"
				return
			CharacterStore.remove(cid)
			_del_armed = ""
			_show_campaign())
		row.add_child(del)
		_camp_list.add_child(row)
	if not _camp_char.is_empty():
		_preview_char(_camp_char)
	_show("campaign")

## Подиум: выбранный герой похода.
func _preview_char(d: Dictionary) -> void:
	if _preview:
		_preview.queue_free()
	_preview = ModelFactory.build_hero(d["class"], d["race"])
	add_child(_preview)
	_preview.position = _preview_anchor
	_preview.rotation.y = _preview_yaw
	var ap := ModelFactory.find_anim(_preview)
	if ap:
		ap.play("Idle")

## В поход выбранным героем: его данные уходят хосту при входе (Net.local_info["character"]).
func _campaign_start(how: String) -> void:
	if _camp_char.is_empty():
		return
	_apply_local_info()
	var d: Dictionary = CharacterStore.load_one(_camp_char["id"])
	if d.is_empty():
		_show_campaign()
		return
	Net.local_info["name"] = d["name"]
	Net.local_info["class"] = d["class"]
	Net.local_info["race"] = d["race"]
	Net.local_info["character"] = d
	Net.settings["campaign"] = true
	match how:
		"solo":
			if Net.host_game(true) == OK:
				Net.start_game()
		"host":
			if Net.host_game(false) == OK:
				_show("lobby")
		"join":
			_ip_edit.text = _camp_ip.text
			var ip := _camp_ip.text.strip_edges()
			if ip != "" and Net.join_game(ip) == OK:
				_lobby_info.text = "Подключение к %s..." % ip
				_show("lobby")
