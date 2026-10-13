extends Node
## Горячие клавиши способностей и окон (автозагрузка «Keys»).
## Привязка — {key: физический код клавиши, shift, ctrl, alt}. Хранится в user://keybinds.cfg.

signal changed

const PATH := "user://keybinds.cfg"
const BAR_SIZE := 12
const BAR_KEYS := [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9, KEY_0, KEY_MINUS, KEY_EQUAL]

## Порядок действий в окне настройки.
var actions: Array = []
var names: Dictionary = {}
var binds: Dictionary = {}       # действие -> {key, shift, ctrl, alt} или {}

func _ready() -> void:
	for b in 2:
		for i in BAR_SIZE:
			var a := "bar%d_%d" % [b + 1, i]
			actions.append(a)
			names[a] = "Панель %d, ячейка %d" % [b + 1, i + 1]
	for a in [["talents", "Окно талантов"], ["spellbook", "Книга заклинаний"]]:
		actions.append(a[0])
		names[a[0]] = a[1]
	reset_defaults(false)
	_load()

func reset_defaults(save_now: bool = true) -> void:
	binds.clear()
	for i in BAR_SIZE:
		binds["bar1_%d" % i] = {"key": BAR_KEYS[i], "shift": false, "ctrl": false, "alt": false}
		binds["bar2_%d" % i] = {"key": BAR_KEYS[i], "shift": true, "ctrl": false, "alt": false}
	binds["talents"] = {"key": KEY_N, "shift": false, "ctrl": false, "alt": false}
	binds["spellbook"] = {"key": KEY_P, "shift": false, "ctrl": false, "alt": false}
	if save_now:
		save()
		changed.emit()

func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	for a in actions:
		if cfg.has_section_key("keys", a):
			var v = cfg.get_value("keys", a)
			if v is Dictionary:
				binds[a] = v

func save() -> void:
	var cfg := ConfigFile.new()
	for a in actions:
		cfg.set_value("keys", a, binds.get(a, {}))
	cfg.save(PATH)

## Какое действие привязано к нажатию (или "").
func action_for_event(ev: InputEventKey) -> String:
	var code := ev.physical_keycode
	for a in actions:
		var b: Dictionary = binds.get(a, {})
		if b.is_empty():
			continue
		if int(b["key"]) == code and bool(b["shift"]) == ev.shift_pressed and bool(b["ctrl"]) == ev.ctrl_pressed and bool(b["alt"]) == ev.alt_pressed:
			return a
	return ""

## Назначить клавишу (снимает её с других действий).
func bind(action: String, ev: InputEventKey) -> void:
	var nb := {"key": ev.physical_keycode, "shift": ev.shift_pressed, "ctrl": ev.ctrl_pressed, "alt": ev.alt_pressed}
	for a in actions:
		var b: Dictionary = binds.get(a, {})
		if not b.is_empty() and int(b["key"]) == nb["key"] and b["shift"] == nb["shift"] and b["ctrl"] == nb["ctrl"] and b["alt"] == nb["alt"]:
			binds[a] = {}
	binds[action] = nb
	save()
	changed.emit()

func unbind(action: String) -> void:
	binds[action] = {}
	save()
	changed.emit()

static func _key_name(code: int) -> String:
	match code:
		KEY_MINUS: return "-"
		KEY_EQUAL: return "="
	return OS.get_keycode_string(code)

## Полное название: «Shift+1».
func label(action: String) -> String:
	var b: Dictionary = binds.get(action, {})
	if b.is_empty():
		return "—"
	var s := ""
	if b["ctrl"]:
		s += "Ctrl+"
	if b["alt"]:
		s += "Alt+"
	if b["shift"]:
		s += "Shift+"
	return s + _key_name(int(b["key"]))

## Короткое название для ячейки панели: «s1», «c2», «a3».
func short_label(action: String) -> String:
	var b: Dictionary = binds.get(action, {})
	if b.is_empty():
		return ""
	var s := ""
	if b["ctrl"]:
		s += "c"
	if b["alt"]:
		s += "a"
	if b["shift"]:
		s += "s"
	return s + _key_name(int(b["key"]))
