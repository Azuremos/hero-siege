extends CenterContainer
## Окно настроек (главное меню и игра): звук, графика, интерфейс, горячие клавиши.

const GOLD := Color(0.95, 0.78, 0.35)

## Вызывается при смене раскладки интерфейса (в игре HUD перестраивает рамки).
var on_ui_changed: Callable
var on_keys: Callable

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel := PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.05, 0.045, 0.07, 0.97)
	st.border_color = GOLD
	st.set_border_width_all(2)
	st.set_corner_radius_all(8)
	st.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", st)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.custom_minimum_size = Vector2(560, 0)
	add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var title := _lbl("Настройки", 22, GOLD)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close := Button.new()
	close.text = "  ✕  "
	close.pressed.connect(func(): visible = false)
	head.add_child(close)

	v.add_child(_lbl("Звук", 17, GOLD))
	_slider(v, "Общая громкость", Settings.master, func(x): Settings.master = x)
	_slider(v, "Музыка", Settings.music, func(x): Settings.music = x)
	_slider(v, "Эффекты", Settings.sfx, func(x): Settings.sfx = x)

	v.add_child(HSeparator.new())
	v.add_child(_lbl("Графика", 17, GOLD))
	_check(v, "Полноэкранный режим", Settings.fullscreen, func(on): Settings.fullscreen = on)
	_check(v, "Вертикальная синхронизация (без разрывов кадра)", Settings.vsync, func(on): Settings.vsync = on)
	var sh_row := HBoxContainer.new()
	v.add_child(sh_row)
	var sh_l := _lbl("Тени", 15, Color.WHITE)
	sh_l.custom_minimum_size = Vector2(180, 0)
	sh_row.add_child(sh_l)
	var sh := OptionButton.new()
	for n in ["Выключены (быстрее всего)", "Средние", "Высокие"]:
		sh.add_item(n)
	sh.select(Settings.shadows)
	sh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sh.item_selected.connect(func(i):
		Settings.shadows = i
		Settings.save()
		var sun := get_tree().current_scene.find_child("Sun", true, false) as DirectionalLight3D
		Settings.apply_shadows(sun))
	sh_row.add_child(sh)
	var cm := CheckBox.new()
	cm.text = "Режим совместимости для старых видеокарт (OpenGL, после перезапуска)"
	cm.tooltip_text = "Если игра не запускается, мерцает или рисует с ошибками. Чуть проще графика, зато работает почти везде."
	cm.button_pressed = Settings.compat_mode()
	v.add_child(cm)
	var cm_note := _lbl("Сейчас: %s" % ("OpenGL (совместимость)" if Settings.compat_running() else "Vulkan"), 13, Color(0.8, 0.8, 0.8))
	v.add_child(cm_note)
	cm.toggled.connect(func(on):
		var err := Settings.set_compat_mode(on)
		if err != "":
			cm_note.text = err
			cm.set_pressed_no_signal(not on)
		else:
			cm_note.text = "Перезапустите игру — %s." % ("включится OpenGL" if on else "вернётся Vulkan"))

	v.add_child(HSeparator.new())
	v.add_child(_lbl("Интерфейс", 17, GOLD))
	_check(v, "Карточки группы — горизонтально", bool(Settings.get_ui_opt("party_horizontal", false)), func(on):
		Settings.set_ui_opt("party_horizontal", on)
		_ui_changed(), false)
	_check(v, "Панель заклинаний 2 — вертикально", bool(Settings.get_ui_opt("bar2_vertical", false)), func(on):
		Settings.set_ui_opt("bar2_vertical", on)
		_ui_changed(), false)
	_check(v, "Прок: бегущая рамка на ячейке", bool(Settings.get_ui_opt("proc_border", true)), func(on):
		Settings.set_ui_opt("proc_border", on)
		_ui_changed(), false)
	_check(v, "Прок: сигнал в центре экрана и звук", bool(Settings.get_ui_opt("proc_center", true)), func(on):
		Settings.set_ui_opt("proc_center", on)
		_ui_changed(), false)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)
	var reset := Button.new()
	reset.text = "Вернуть рамки на место"
	reset.pressed.connect(func():
		Settings.reset_ui_positions()
		_ui_changed())
	row.add_child(reset)
	var keys := Button.new()
	keys.text = "Горячие клавиши"
	keys.pressed.connect(func():
		if on_keys.is_valid():
			on_keys.call())
	row.add_child(keys)
	var hint := _lbl("Любую рамку (портрет, цель, группу, панели заклинаний) можно перетащить мышью прямо в игре: Esc → «Настроить интерфейс».", 13, Color(1, 1, 1, 0.65))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(hint)

func _ui_changed() -> void:
	if on_ui_changed.is_valid():
		on_ui_changed.call()

func _lbl(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l

func _slider(parent: Control, text: String, value: float, setter: Callable) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var l := _lbl(text, 15, Color.WHITE)
	l.custom_minimum_size = Vector2(180, 0)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.05
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size = Vector2(240, 24)
	s.value_changed.connect(func(x):
		setter.call(x)
		Settings.apply()
		Settings.save())
	row.add_child(s)

func _check(parent: Control, text: String, value: bool, setter: Callable, apply_display: bool = true) -> void:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = value
	c.toggled.connect(func(on):
		setter.call(on)
		if apply_display:
			Settings.apply()
		Settings.save())
	parent.add_child(c)
