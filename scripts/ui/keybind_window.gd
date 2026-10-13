extends CenterContainer
## Настройка горячих клавиш: нажмите кнопку действия, затем клавишу (можно с Shift/Ctrl/Alt).
## Backspace — снять клавишу, Esc — отмена.

const GOLD := Color(0.95, 0.78, 0.35)
const MODIFIERS := [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]

var _buttons: Dictionary = {}
var _waiting := ""
var _hint: Label

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel := PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.05, 0.045, 0.07, 0.97)
	st.border_color = GOLD
	st.set_border_width_all(2)
	st.set_corner_radius_all(8)
	st.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", st)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var title := Label.new()
	title.text = "Горячие клавиши"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", GOLD)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var reset := Button.new()
	reset.text = "По умолчанию"
	reset.pressed.connect(func():
		Keys.reset_defaults()
		_refresh())
	head.add_child(reset)
	var close := Button.new()
	close.text = "  ✕  "
	close.pressed.connect(func(): visible = false)
	head.add_child(close)
	_hint = Label.new()
	_hint.text = "Нажмите на кнопку, затем нужную клавишу (можно с Shift, Ctrl, Alt).  Backspace — убрать клавишу."
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	v.add_child(_hint)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(640, 520)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 4)
	scroll.add_child(grid)
	for a in Keys.actions:
		var l := Label.new()
		l.text = Keys.names[a]
		l.custom_minimum_size = Vector2(170, 0)
		grid.add_child(l)
		var b := Button.new()
		b.custom_minimum_size = Vector2(120, 30)
		b.pressed.connect(_start.bind(a))
		grid.add_child(b)
		_buttons[a] = b
	_refresh()

func _start(action: String) -> void:
	_waiting = action
	_refresh()
	_buttons[action].text = "нажмите…"

func _refresh() -> void:
	for a in _buttons:
		_buttons[a].text = Keys.label(a)

func _input(event: InputEvent) -> void:
	if _waiting == "" or not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		get_viewport().set_input_as_handled()
		if MODIFIERS.has(k.keycode):
			return
		if k.keycode == KEY_ESCAPE:
			pass
		elif k.keycode == KEY_BACKSPACE or k.keycode == KEY_DELETE:
			Keys.unbind(_waiting)
		else:
			Keys.bind(_waiting, k)
			Sfx.play("ui_learn")
		_waiting = ""
		_refresh()
