class_name SpellIcon
extends RefCounted
## Иконки заклинаний (game-icons.net, CC BY 3.0) и текст подсказки — общие для меню и интерфейса боя.

static var _bg_cache: Dictionary = {}

## Подсказки (заклинания, предметы, таланты) — на непрозрачной тёмной подложке с золотой рамкой:
## полупрозрачные по умолчанию плохо читались поверх боя (просьба пользователя). Ставится в тему окна
## и в тему по умолчанию — на случай подсказок вне неё.
static func style_tooltips(theme: Theme) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.07, 0.09, 1.0)
	sb.border_color = Color(0.62, 0.52, 0.3)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	sb.shadow_color = Color(0, 0, 0, 0.5)
	sb.shadow_size = 4
	for t: Theme in [theme, ThemeDB.get_default_theme()]:
		if t == null:
			continue
		t.set_stylebox("panel", "TooltipPanel", sb)
		t.set_color("font_color", "TooltipLabel", Color(0.96, 0.94, 0.88))
		t.set_color("font_outline_color", "TooltipLabel", Color(0, 0, 0))
		t.set_constant("outline_size", "TooltipLabel", 2)

## Иконка заклинания: фон в цвете школы магии + силуэт (game-icons.net, CC BY 3.0).
## Роль заклинания для оттенка иконки: heal / shield / dmg.
static func role_of(sid: String) -> String:
	var sp: Dictionary = GameData.SPELLS[sid]
	for e in sp.get("effects", []) + sp.get("ally_fx", []):
		if e["type"] in ["heal", "hot", "heal_pct"] and not sp.has("enemy_fx"):
			return "heal"
		if e["type"] in ["absorb", "immune"]:
			return "shield"
	if sp.get("ally_dr", 0.0) > 0.0:
		return "shield"
	return "dmg"

## Иконка предмета: фон в цвете качества (обычный/необычный/редкий/эпический/легендарный).
static func make_item(id: String, size: float) -> Control:
	var it := GameData.item(id)
	var col := GameData.item_color(id)
	return make_icon("res://assets/icons/items/%s.svg" % it.get("icon", ""), str(it.get("name", "?")).substr(0, 2), col, "item_q%d" % int(it.get("q", 0)), size)

static func make(sid: String, size: float) -> Control:
	if sid.begins_with("item:"):
		return make_item(sid.trim_prefix("item:"), size)
	var sp: Dictionary = GameData.SPELLS[sid]
	var school: String = sp["school"]
	var col: Color = GameData.SCHOOLS[school]["color"]
	var role := role_of(sid)
	if role == "heal":
		col = Color(0.55, 0.95, 0.45)
	elif role == "shield":
		col = Color(0.95, 0.95, 0.85)
	return make_icon("res://assets/icons/spells/%s.svg" % sid, sp["icon"], col, school + "_" + role, size)

## Иконка таланта: своя картинка или иконка заклинания, которое он усиливает.
static func make_talent(t: Dictionary, tree_color: Color, size: float) -> Control:
	var icon: String = t.get("icon", "")
	if icon.begins_with("spell:"):
		return make(icon.trim_prefix("spell:"), size)
	return make_icon("res://assets/icons/talents/%s.svg" % icon, str(t["name"]).substr(0, 2), tree_color, "tree_" + tree_color.to_html(), size)

static func make_icon(path: String, fallback: String, col: Color, bg_key: String, size: float) -> Control:
	var school := bg_key
	var holder := Control.new()
	holder.size = Vector2(size, size)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.clip_contents = true
	if not _bg_cache.has(school):
		var g := Gradient.new()
		g.set_color(0, col.darkened(0.15))
		g.set_color(1, col.darkened(0.82))
		var gt := GradientTexture2D.new()
		gt.gradient = g
		gt.fill = GradientTexture2D.FILL_RADIAL
		gt.fill_from = Vector2(0.5, 0.42)
		gt.fill_to = Vector2(1.05, 1.0)
		gt.width = 64
		gt.height = 64
		_bg_cache[school] = gt
	var bg := TextureRect.new()
	bg.texture = _bg_cache[school]
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.size = Vector2(size, size)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(bg)
	if ResourceLoader.exists(path):
		var tex: Texture2D = load(path)
		var pad := size * 0.1
		var shadow := TextureRect.new()
		shadow.texture = tex
		shadow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		shadow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		shadow.position = Vector2(pad + 2, pad + 2)
		shadow.size = Vector2(size - pad * 2, size - pad * 2)
		shadow.modulate = Color(0, 0, 0, 0.6)
		shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(shadow)
		var fg := TextureRect.new()
		fg.texture = tex
		fg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		fg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		fg.position = Vector2(pad, pad)
		fg.size = Vector2(size - pad * 2, size - pad * 2)
		fg.modulate = col.lerp(Color.WHITE, 0.6)
		fg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(fg)
	else:
		var l := Label.new()
		l.text = fallback
		l.add_theme_font_size_override("font_size", int(size * 0.36))
		l.add_theme_color_override("font_color", col.lightened(0.45))
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.size = Vector2(size, size)
		holder.add_child(l)
	return holder

## Подсказка; если передан герой (Unit) — с учётом его талантов.
static func tooltip(sid: String, u: Unit = null) -> String:
	if sid.begins_with("item:"):
		return GameData.item_tooltip(sid.trim_prefix("item:"))
	var sp: Dictionary = GameData.SPELLS[sid]
	var mana := float(sp["mana"]) if u == null else GameData.spell_cost(u, sid)
	var res_name: String = {"rage": "Ярость", "focus": "Концентрация"}.get(u.resource if u != null else _spell_resource(sid), "Мана")
	var cast := float(sp["cast"]) if u == null else GameData.eff_cast(u, sid)
	var cd := float(sp["cd"]) if u == null else GameData.eff_cd(u, sid)
	var rng := float(sp["range"]) if u == null else GameData.eff_range(u, sid)
	var lines := [sp["name"], GameData.SCHOOLS[sp["school"]]["name"]]
	if sp.get("talent", false):
		lines[1] += "  •  заклинание таланта"
	else:
		lines.append("Открывается на %d уровне" % GameData.spell_level(sid))
	lines.append("%s: %d" % [res_name, int(round(mana))])
	lines.append("Мгновенное" if cast <= 0.0 else "Произнесение: %.1f сек." % cast)
	if cd > 0.0:
		lines.append("Перезарядка: %s сек." % GameData._fmt(cd))
	if rng > 0.0:
		lines.append("Дальность: %d м" % int(rng))
	lines.append("")
	lines.append(sp["desc"])
	return "\n".join(lines)


## Ресурс класса, которому принадлежит заклинание (книга или талант): mana | rage | focus.
static func _spell_resource(sid: String) -> String:
	for cid in GameData.CLASSES:
		var book: Dictionary = GameData.BOOKS.get(cid, {})
		var own: bool = GameData.CLASSES[cid]["spells"].has(sid) or book.get("base", []).has(sid)
		for r in book.get("rows", []):
			own = own or r["options"].has(sid)
		for tree in GameData.talent_trees(cid):
			for t in tree["talents"]:
				own = own or t.get("spell", "") == sid
		if own:
			return str(GameData.CLASSES[cid].get("resource", "mana"))
	return "mana"
