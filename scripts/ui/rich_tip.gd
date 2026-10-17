class_name RichTip
extends Control
## Подсказка вещи с цветными строками: в сравнении с надетым «▲» — зелёным, «▼» — красным.
## Обычный tooltip_text раскрасить построчно нельзя, поэтому ячейке вещи вешается этот скрипт
## (RichTip.attach(ячейка)): текст тот же — tooltip_text, а рисуется он RichTextLabel.

const UP := Color(0.35, 0.95, 0.35)
const DOWN := Color(1.0, 0.38, 0.32)

static func attach(c: Control) -> void:
	c.set_script(load("res://scripts/ui/rich_tip.gd"))

func _make_custom_tooltip(for_text: String) -> Object:
	var lines: Array = []
	for line: String in for_text.split("\n"):
		var safe := line.replace("[", "[lb]")
		if line.begins_with("▲"):
			safe = "[color=#%s]%s[/color]" % [UP.to_html(false), safe]
		elif line.begins_with("▼"):
			safe = "[color=#%s]%s[/color]" % [DOWN.to_html(false), safe]
		lines.append(safe)
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.scroll_active = false
	l.text = "\n".join(lines)
	return l
