extends Node
## Единая точка доступа к игровым данным: GameData.CLASSES, GameData.SPELLS, GameData.MOBS и т.д.
## Сами данные лежат рядом, в scripts/data/ (см. ниже). Баланс правится там — без изменения логики.

const MAX_LEVEL := 30
const GCD := 1.25                 # глобальное время восстановления
const XP_SHARE_RADIUS := 45.0     # опыт за убийство получают все герои в этом радиусе
const RESPAWN_BASE := 8.0
const CASTLE_HP := 6000.0
const WAVE_COUNT := 20            # полная осада по умолчанию
const MAX_WAVES := 100            # 0 в настройках = бесконечная осада
const POTION_CD := 40.0           # общее восстановление зелий
const FIRST_WAVE_DELAY := 25.0

## Мана. Восполнение в секунду: запас × MANA_REGEN_POOL + Дух × MANA_REGEN_SPIRIT — это 100% (вне боя).
## Ступени: передышка — ×8; в бою (наносил/получал урон или помогал союзнику в бою за COMBAT_TIME сек.) —
## COMBAT_REGEN; в бою и после траты маны 5 сек. (правило 5 секунд) — CASTING_REGEN.
const MANA_REGEN_POOL := 0.03
const MANA_REGEN_SPIRIT := 0.6
const COMBAT_REGEN := 0.5
const CASTING_REGEN := 0.15
const FIVE_SECOND_RULE := 5.0
const COMBAT_TIME := 6.0
const WAVE_INTERVAL := 42.0

# ---------------------------------------------------------------- Данные по файлам
## classes_data.gd    — классы, расы, школы магии, атрибуты
## spells/<класс>.gd  — заклинания класса (вместе с заклинаниями из его талантов)
## spell_effects.gd   — уровни открытия заклинаний, баффы, проки, автозаклинания
## mob_data.gd        — враги четырёх фракций; factions.gd — фракции и стороны; mob_abilities.gd — способности врагов
## boss_data.gd       — боссы: фазы, механики, реплики, добыча
## lines_data.gd, sends.gd — режим «Война линий»: баланс режима и отправки врагов
## formulas.gd        — опыт, рост силы, состав волн, сила врагов
## talent_data.gd, item_data.gd — таланты и предметы

const ClassData := preload("res://scripts/data/classes_data.gd")
const SpellEffects := preload("res://scripts/data/spell_effects.gd")
const MobData := preload("res://scripts/data/mob_data.gd")
const FactionData := preload("res://scripts/data/factions.gd")
const MobAbilities := preload("res://scripts/data/mob_abilities.gd")
const AffixData := preload("res://scripts/data/affixes.gd")
const BossData := preload("res://scripts/data/boss_data.gd")
const Formulas := preload("res://scripts/data/formulas.gd")
const LinesData := preload("res://scripts/data/lines_data.gd")
const SendData := preload("res://scripts/data/sends.gd")
const SPELL_FILES := [
	preload("res://scripts/data/spells/mage.gd"),
	preload("res://scripts/data/spells/paladin.gd"),
	preload("res://scripts/data/spells/priest.gd"),
	preload("res://scripts/data/spells/warrior.gd"),
	preload("res://scripts/data/spells/hunter.gd"),
	preload("res://scripts/data/spells/shaman.gd"),
]

const SCHOOLS := ClassData.SCHOOLS
const RACES := ClassData.RACES
const CLASSES := ClassData.CLASSES
const ATTRS := ClassData.ATTRS
const SPELL_LEVELS := SpellEffects.SPELL_LEVELS
## Описания баффов и дебаффов: SpellEffects.BUFF_INFO + недостающие, собранные из самих заклинаний
## (см. _build_buff_info) — иначе эффект без описания не виден ни в рамке героя, ни в рамке цели.
const PROC_BUFFS := SpellEffects.PROC_BUFFS
const AUTO_SPELLS := SpellEffects.AUTO_SPELLS
const MOBS := MobData.MOBS
const MONSTER_MODELS := MobData.MODELS
const ANIM_SETS := MobData.ANIM_SETS
const FACTIONS := FactionData.FACTIONS
const MOB_ABILITIES := MobAbilities.ABILITIES
const AFFIXES := AffixData.AFFIXES
const BOSSES := BossData.BOSSES

# ---------------------------------------------------------------- Заклинания
# target: enemy | ally | self | ground | wall
# delivery: projectile | instant | self_aoe | zone | wall
# effects: список эффектов на цель. Для ally/enemy-разделения — enemy_fx / ally_fx.

## Все заклинания всех классов: собираются из scripts/data/spells/*.gd.
var SPELLS: Dictionary = _collect_spells()

func _collect_spells() -> Dictionary:
	var all := {}
	for f in SPELL_FILES:
		for sid in f.SPELLS:
			if all.has(sid):
				push_error("Заклинание %s описано в двух файлах" % sid)
			all[sid] = f.SPELLS[sid]
	return all

var BUFF_INFO: Dictionary = _build_buff_info()

## Эффекту с key (бафф, периодический урон или лечение) без записи в SpellEffects.BUFF_INFO даём описание
## по его заклинанию: имя, иконка и цвет школы, текст подсказки; на враге (enemy_fx, цель-враг, dot) — дебафф.
func _build_buff_info() -> Dictionary:
	var out: Dictionary = SpellEffects.BUFF_INFO.duplicate()
	for sid in SPELLS:
		var sp: Dictionary = SPELLS[sid]
		var on_enemy: bool = sp.get("target", "") == "enemy"
		_add_buff_infos(sid, sp, sp.get("effects", []), on_enemy, out)
		_add_buff_infos(sid, sp, sp.get("enemy_fx", []), true, out)
		_add_buff_infos(sid, sp, sp.get("ally_fx", []), false, out)
		_add_buff_infos(sid, sp, sp.get("impact_fx", []), true, out)
		_add_buff_infos(sid, sp, sp.get("self_fx", []), false, out)
		_add_buff_infos(sid, sp, sp.get("pet_fx", []), false, out)
	return out

func _add_buff_infos(sid: String, sp: Dictionary, fx: Array, on_enemy: bool, out: Dictionary) -> void:
	for e in fx:
		if not e is Dictionary:
			continue
		if e.has("effects"):
			_add_buff_infos(sid, sp, e["effects"], on_enemy, out)
		if not e.has("key") or out.has(e["key"]):
			continue
		var debuff: bool = on_enemy or e["type"] == "dot"
		out[e["key"]] = {"name": sp["name"], "icon": sid, "color": SCHOOLS[sp["school"]]["color"], "debuff": debuff,
			"desc": sp.get("desc", "")}

# ---------------------------------------------------------------- Формулы (scripts/data/formulas.gd)

func xp_to_next(level: int) -> int:
	return Formulas.xp_to_next(level)

## Множитель силы эффектов (урон/лечение) героя от уровня.
func level_power(level: int) -> float:
	return Formulas.level_power(level)

## Состав волны из бюджета (formulas.gd): {"list": [[тип, индекс полосы, флаг], …], "special": …}.
func wave_plan(wave: int, lane_factions: Array, players: int, final_boss: bool = false) -> Dictionary:
	return Formulas.wave_plan(wave, lane_factions, players, final_boss)

func mob_hp_mult(wave: int, players: int) -> float:
	return Formulas.mob_hp_mult(wave, players)

func mob_dmg_mult(wave: int) -> float:
	return Formulas.mob_dmg_mult(wave)

func mana_scale(class_id: String, level: int) -> float:
	return Formulas.mana_scale(CLASSES[class_id], level)

# ---------------------------------------------------------------- Таланты

const TalentData := preload("res://scripts/data/talent_data.gd")
var _talent_index: Dictionary = {}   # class -> tid -> {"t": талант, "tree": индекс ветки}

## Уровень открытия: у заклинания из ряда книги — уровень ряда, у базового — SPELL_LEVELS.
func spell_level(sid: String) -> int:
	for cid in BOOKS:
		var rows: Array = BOOKS[cid]["rows"]
		for r in rows:
			if r["options"].has(sid):
				return int(r["level"])
	return int(SPELL_LEVELS.get(sid, 1))

# ---------------------------------------------------------------- книга заклинаний
## Книга класса: {"base": [...], "rows": [{"level", "name", "role", "options": [3 id]}]} — в spells/<класс>.gd.
## Выбор героя — {номер ряда: id}. Пока игрок не выбрал, в ряду действует вариант по умолчанию —
## заклинание, которое было у класса до книги (если оно в этом ряду есть).
var BOOKS: Dictionary = _collect_books()

func _collect_books() -> Dictionary:
	var out := {}
	for f in SPELL_FILES:
		var consts: Dictionary = f.get_script_constant_map()
		if consts.has("BOOK") and consts.has("CLASS"):
			out[consts["CLASS"]] = consts["BOOK"]
	return out

func book_default(class_id: String, row: int) -> String:
	for sid in BOOKS[class_id]["rows"][row]["options"]:
		if CLASSES[class_id]["spells"].has(sid):
			return sid
	return ""

func book_choice(class_id: String, row: int, choices: Dictionary) -> String:
	if not BOOKS.has(class_id) or row < 0 or row >= BOOKS[class_id]["rows"].size():
		return ""
	var c: String = str(choices.get(row, ""))
	if BOOKS[class_id]["rows"][row]["options"].has(c):
		return c
	return book_default(class_id, row)

func book_row_of(class_id: String, sid: String) -> int:
	if not BOOKS.has(class_id):
		return -1
	var rows: Array = BOOKS[class_id]["rows"]
	for i in rows.size():
		if rows[i]["options"].has(sid):
			return i
	return -1

func talent_trees(class_id: String) -> Array:
	return TalentData.TREES.get(class_id, [])

func find_talent(class_id: String, tid: String) -> Dictionary:
	if not _talent_index.has(class_id):
		var idx := {}
		var trees := talent_trees(class_id)
		for i in trees.size():
			for t in trees[i]["talents"]:
				idx[t["id"]] = {"t": t, "tree": i}
		_talent_index[class_id] = idx
	return _talent_index[class_id].get(tid, {})

## Очки талантов: по одному за каждый уровень начиная со 2-го.
func talent_points_total(level: int) -> int:
	return maxi(0, level - 1)

func talent_points_spent(ranks: Dictionary) -> int:
	var n := 0
	for tid in ranks:
		n += int(ranks[tid])
	return n

func tree_points(class_id: String, ranks: Dictionary, tree_idx: int) -> int:
	var n := 0
	for t in talent_trees(class_id)[tree_idx]["talents"]:
		n += int(ranks.get(t["id"], 0))
	return n

## Пустая строка — можно изучить; иначе причина отказа.
func can_learn(class_id: String, ranks: Dictionary, level: int, tid: String) -> String:
	var info := find_talent(class_id, tid)
	if info.is_empty():
		return "Нет такого таланта"
	var t: Dictionary = info["t"]
	if int(ranks.get(tid, 0)) >= int(t["max"]):
		return "Талант уже изучен полностью"
	if talent_points_spent(ranks) >= talent_points_total(level):
		return "Нет свободных очков талантов"
	var tree: Dictionary = talent_trees(class_id)[info["tree"]]
	var need := int(t["row"]) * TalentData.POINTS_PER_ROW
	if tree_points(class_id, ranks, info["tree"]) < need:
		return "Нужно вложить %d очков в ветку «%s»" % [need, tree["name"]]
	var need_lvl := talent_level(class_id, t)
	if level < need_lvl:
		return "Доступно с %d уровня" % need_lvl
	if t.has("req"):
		var req := find_talent(class_id, t["req"])
		if int(ranks.get(t["req"], 0)) < int(req["t"]["max"]):
			return "Сначала изучите «%s»" % req["t"]["name"]
	return ""

## Ряд книги, на заклинание которого действует талант (область «spell:» из ряда или «row:N»), иначе -1.
func talent_book_row(class_id: String, t: Dictionary) -> int:
	var best := -1
	for md in t.get("mods", []):
		var scope: String = md[0]
		var row := -1
		if scope.begins_with("row:"):
			row = int(scope.trim_prefix("row:"))
		elif scope.begins_with("spell:"):
			row = book_row_of(class_id, scope.trim_prefix("spell:"))
		if row >= 0 and (best < 0 or row < best):
			best = row
	return best

## Талант на заклинание из ряда книги открывается не раньше уровня этого ряда.
func talent_level(class_id: String, t: Dictionary) -> int:
	var row := talent_book_row(class_id, t)
	return int(BOOKS[class_id]["rows"][row]["level"]) if row >= 0 else 1

## Сводит изученные таланты в модификаторы: {global, school, spell, flags}.
## Модификаторы героя: таланты (ранги) и пассивные варианты книги заклинаний (choices).
## Область «row:N» — «ваше заклинание ряда N книги»: применяется к тому, что выбрано в этом ряду,
## и при смене выбора переходит на новый вариант сам.
func compute_mods(class_id: String, ranks: Dictionary, choices: Dictionary = {}, extra: Array = []) -> Dictionary:
	var m := {"global": {}, "school": {}, "spell": {}, "flags": {}, "procs": []}
	var sources: Array = []      # [данные с mods/flags/proc, ранг, id]
	for tid in ranks:
		var info := find_talent(class_id, tid)
		if int(ranks[tid]) > 0 and not info.is_empty():
			sources.append([info["t"], int(ranks[tid]), tid])
	if BOOKS.has(class_id):
		for i in BOOKS[class_id]["rows"].size():
			var c := book_choice(class_id, i, choices)
			if c != "" and SPELLS[c].get("passive", false):
				sources.append([SPELLS[c], 1, c])
	sources.append_array(extra)      # бонусы сетов и эффекты легендарок (gear_sources)
	for src in sources:
		var t: Dictionary = src[0]
		var r: int = src[1]
		var tid: String = src[2]
		for md in t.get("mods", []):
			var scope: String = md[0]
			# талант на заклинание из ряда книги усиливает любой выбранный вариант этого ряда
			if scope.begins_with("spell:") and book_row_of(class_id, scope.trim_prefix("spell:")) >= 0:
				scope = "row:%d" % book_row_of(class_id, scope.trim_prefix("spell:"))
			if scope.begins_with("row:"):
				var chosen := book_choice(class_id, int(scope.trim_prefix("row:")), choices)
				if chosen == "":
					continue
				scope = "spell:" + chosen
			var key: String = md[1]
			var val: float = float(md[2]) * r
			var bucket: Dictionary = m["global"]
			if scope.begins_with("school:"):
				var s := scope.trim_prefix("school:")
				if not m["school"].has(s):
					m["school"][s] = {}
				bucket = m["school"][s]
			elif scope.begins_with("spell:"):
				var s := scope.trim_prefix("spell:")
				if not m["spell"].has(s):
					m["spell"][s] = {}
				bucket = m["spell"][s]
			bucket[key] = float(bucket.get(key, 0.0)) + val
		if t.has("proc"):
			var pd: Dictionary = t["proc"].duplicate()
			pd["chance"] = float(pd.get("chance", 1.0)) * r      # у проков «каждое N-е» шанса нет
			pd["id"] = tid
			m["procs"].append(pd)
		for fl in t.get("flags", []):
			m["flags"][fl[0]] = float(m["flags"].get(fl[0], 0.0)) + float(fl[1]) * r
	return m

## Заклинания-вершины, полученные из талантов (в порядке веток).
func talent_spells(class_id: String, ranks: Dictionary) -> Array:
	var out: Array = []
	for tree in talent_trees(class_id):
		for t in tree["talents"]:
			if t.has("spell") and int(ranks.get(t["id"], 0)) > 0:
				out.append(t["spell"])
	return out

## Заклинания героя: базовые книги + выбранные в рядах (кроме пассивных) + вершины талантов.
## Уровень здесь не проверяется — закрытые показываются на панели с замком.
func hero_spells(class_id: String, ranks: Dictionary, choices: Dictionary = {}) -> Array:
	if not BOOKS.has(class_id):
		return CLASSES[class_id]["spells"] + talent_spells(class_id, ranks)
	var out: Array = BOOKS[class_id]["base"].duplicate()
	for i in BOOKS[class_id]["rows"].size():
		var c := book_choice(class_id, i, choices)
		if c != "" and not SPELLS[c].get("passive", false):
			out.append(c)
	return out + talent_spells(class_id, ranks)

func talent_desc(t: Dictionary, rank: int) -> String:
	var r := maxi(rank, 1)
	var v = t.get("v", 0)
	var v1: float = float(v[0]) if v is Array else float(v)
	var v2: float = float(v[1]) if v is Array and v.size() > 1 else 0.0
	return str(t["desc"]).replace("{v2}", _fmt(v2 * r)).replace("{v}", _fmt(v1 * r))

func _fmt(x: float) -> String:
	if is_equal_approx(x, round(x)):
		return str(int(round(x)))
	return ("%.2f" % x).rstrip("0").rstrip(".")

# ---------------------------------------------------------------- Итоговые параметры заклинаний (с талантами)

## Активный прок, который действует на это заклинание: {key, data} или пустой словарь.
func active_proc(u: Unit, sid: String) -> Dictionary:
	for b in u.buffs:
		var pd: Dictionary = PROC_BUFFS.get(b["key"], {})
		if not pd.is_empty() and pd["spells"].has(sid):
			return {"key": b["key"], "data": pd}
	return {}

func eff_mana(u: Unit, sid: String) -> float:
	var sp: Dictionary = SPELLS[sid]
	if u.has_buff("clearcasting") and float(sp["mana"]) > 0.0 and u.resource == "mana":
		return 0.0
	var pr := active_proc(u, sid)
	if not pr.is_empty() and pr["data"].get("free", false):
		return 0.0
	return spell_cost(u, sid)

## Стоимость заклинания без учёта проков: растёт с уровнем героя (доля базового запаса маны),
## таланты на экономию маны её снижают. Ярость не растёт с уровнем.
func spell_cost(u: Unit, sid: String) -> float:
	var sp: Dictionary = SPELLS[sid]
	var cost := float(sp["mana"]) * maxf(0.0, 1.0 + u.mod("mana", sid, sp["school"]))
	if u.resource == "mana" and u.kind == "hero" and CLASSES.has(u.type_id):
		cost *= mana_scale(u.type_id, u.level)
	return cost

func eff_cast(u: Unit, sid: String) -> float:
	var sp: Dictionary = SPELLS[sid]
	var base := float(sp["cast"])
	if base <= 0.0:
		return 0.0
	var pr := active_proc(u, sid)
	if not pr.is_empty() and pr["data"].get("instant", false):
		return 0.0
	return maxf(0.3, base + u.mod("cast_add", sid, sp["school"])) * maxf(0.4, 1.0 - u.mod("haste"))

func eff_cd(u: Unit, sid: String) -> float:
	var sp: Dictionary = SPELLS[sid]
	return maxf(0.0, float(sp["cd"]) + u.mod("cd_add", sid, sp["school"]))

func eff_range(u: Unit, sid: String) -> float:
	return float(SPELLS[sid]["range"]) * (1.0 + u.mod("range"))

# ---------------------------------------------------------------- Предметы

const ItemData := preload("res://scripts/data/item_data.gd")
var _items: Dictionary = {}

## Описание предмета по id: {id, name, kind (gear/consumable), slot, stats, level, price, q, icon, classes, use, proc…}.
## Снаряжение — экземпляр в строке (ItemData.encode), описание строится при первом обращении и кэшируется.
func item(id: String) -> Dictionary:
	if _items.has(id):
		return _items[id]
	var it := {}
	if ItemData.is_gear_id(id):
		it = ItemData.describe(id)
	elif ItemData.CONSUMABLES.has(id):
		var c: Dictionary = ItemData.CONSUMABLES[id]
		it = {"id": id, "name": c["name"], "kind": "consumable", "level": c["level"], "price": c["price"],
			"q": c["q"], "icon": c["icon"], "use": c["use"], "desc": c.get("desc", ""), "elixir": c.get("elixir", false)}
	if not it.is_empty():
		_items[id] = it
	return it

## Сервер: новая вещь шаблона base уровня ilvl и качества q (свойства и прок — случайно).
func make_gear(base: String, ilvl: int, q: int, seed: int = -1) -> String:
	if seed < 0:
		seed = randi() % 1000000
	return ItemData.encode(ItemData.roll(base, ilvl, q, seed))

## Ассортимент лавки для героя уровня level. Кузнец: каждый шаблон белым и зелёным на уровне героя и
## на 3 уровня ниже, плюс изредка одна-две синие вещи — дорого. Фиолетового и легендарного не продают.
## Ассортимент детерминирован по (уровень, rotation): сервер пересчитывает его и проверяет покупку.
func vendor_stock(kind: String, level: int, rotation: int) -> Array:
	var out: Array = []
	if kind == "consumable":
		var ids: Array = ItemData.CONSUMABLES.keys()
		ids.sort_custom(func(a, b): return [ItemData.CONSUMABLES[a]["level"], a] < [ItemData.CONSUMABLES[b]["level"], b])
		return ids
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([level, rotation])
	var bases: Array = ItemData.TEMPLATES.keys()
	for base in bases:
		for lv in [maxi(1, level - 3), level]:
			for q in [0, 1]:
				var id := make_gear(base, lv, q, (rng.randi() % 1000000) if q > 0 else 0)
				if not out.has(id):
					out.append(id)
	# аксессуары: четыре шаблона по очереди (rotation), белые и зелёные на уровне героя
	var tr: Array = ItemData.TRINKETS.keys()
	for i in 4:
		var base: String = tr[(rotation * 4 + i) % tr.size()]
		out.append(make_gear(base, level, i % 2, rng.randi() % 1000000))
	# синее — не каждый раз: с 5-го уровня, одна-две вещи
	if level >= 5 and rng.randf() < 0.6:
		for i in 1 + int(rng.randf() < 0.3):
			out.append(make_gear(bases[rng.randi() % bases.size()], level, 2, rng.randi() % 1000000))
	return out

## Цена в лавке: синее с наценкой.
func shop_price(id: String) -> int:
	var it := item(id)
	var p := float(it.get("price", 0))
	if it.get("kind", "") == "gear" and int(it["q"]) >= 2:
		p *= ItemData.SHOP_BLUE_MARKUP
	return int(p)

func item_color(id: String) -> Color:
	return ItemData.QUALITY[clampi(int(item(id).get("q", 0)), 0, ItemData.QUALITY.size() - 1)]

## Текст подсказки предмета.
## Снаряжение героя, для которого строится подсказка (сколько частей сета надето, сравнение с надетым).
## Ставят окно персонажа, лавка и обмен; в меню — пусто.
var tooltip_equip: Dictionary = {}

func item_tooltip(id: String, hero_class: String = "", hero_level: int = 99, price: int = -1) -> String:
	var it := item(id)
	if it.is_empty():
		return ""
	var lines := [it["name"]]
	if it["kind"] == "gear":
		lines.append("%s · %s · уровень предмета %d" % [ItemData.QUALITY_NAMES[it["q"]], ItemData.SLOTS[it["slot"]], it["ilvl"]])
		for k in ItemData.STAT_ORDER:
			if it["stats"].has(k):
				if ItemData.PCT_STATS.has(k):
					lines.append("+%.1f%% %s" % [it["stats"][k] * 100.0, ItemData.STAT_NAMES[k]])
				else:
					lines.append("+%d %s" % [int(it["stats"][k]), ItemData.STAT_NAMES[k]])
		if it.get("use", "") != "":
			var ud: Dictionary = ItemData.ITEM_PROCS[it["use"]]
			lines.append("%s. %s" % [ud["name"], ud["desc"]])
			lines.append("Перетащите на панель заклинаний.")
		if it["proc"] != "":
			var pr: Dictionary = ItemData.ITEM_PROCS[it["proc"]]
			lines.append("%s: %s" % [pr["name"], pr["desc"]])
		lines.append_array(set_tooltip_lines(it, tooltip_equip))
		if not it["classes"].is_empty():
			var names := []
			for c in it["classes"]:
				names.append(CLASSES[c]["name"])
			var ok: bool = hero_class == "" or it["classes"].has(hero_class)
			lines.append(("Классы: " if ok else "✗ Только: ") + ", ".join(names))
	else:
		var u: Dictionary = it["use"]
		if u.has("heal_pct"):
			lines.append("Восстанавливает %d%% здоровья." % roundi(float(u["heal_pct"]) * 100.0))
		if u.has("mana_pct"):
			lines.append("Восстанавливает %d%% маны (воину — ярости)." % roundi(float(u["mana_pct"]) * 100.0))
		if it["desc"] != "":
			lines.append(it["desc"])
		lines.append("Общая перезарядка зелий: %d сек." % int(POTION_CD))
	if hero_level >= int(it["level"]):
		lines.append("Требуется уровень %d" % it["level"])
	else:
		lines.append("✗ Требуется уровень %d — у вас %d" % [it["level"], hero_level])
	lines.append("Цена: %d золота" % (price if price >= 0 else int(it["price"])))
	if it["kind"] == "gear":
		lines.append_array(compare_lines(id, tooltip_equip))
	return "\n".join(lines)

## Сравнение вещи с надетой в той же ячейке (аксессуар — с обоими): разница характеристик ▲/▼.
## Для надетой вещи и без снаряжения (tooltip_equip пуст) — ничего.
func compare_lines(id: String, equip: Dictionary) -> Array:
	var it := item(id)
	if equip.is_empty() or equip.values().has(id):
		return []
	var slots: Array = ItemData.TRINKET_SLOTS if it["slot"] == "trinket" else [it["slot"]]
	var free: Array = slots.filter(func(s): return str(equip.get(s, "")) == "")
	if not free.is_empty():
		slots = [free[0]]       # есть свободная ячейка аксессуара — вещь встанет туда
	var out: Array = []
	for slot in slots:
		var worn := str(equip.get(slot, ""))
		out.append("")
		if worn == "" or item(worn).is_empty():
			out.append("Сравнение: ячейка «%s» пуста — всё прибавится." % ItemData.SLOTS[slot])
			continue
		var w := item(worn)
		out.append("Сравнение с надетым: %s" % w["name"])
		var diff := false
		for k in ItemData.STAT_ORDER:
			var d := float(it["stats"].get(k, 0.0)) - float(w["stats"].get(k, 0.0))
			if absf(d) < 0.0005:
				continue
			diff = true
			var mark := "▲ +" if d > 0.0 else "▼ −"
			if ItemData.PCT_STATS.has(k):
				out.append("%s%.1f%% %s" % [mark, absf(d) * 100.0, ItemData.STAT_NAMES[k]])
			else:
				out.append("%s%d %s" % [mark, int(round(absf(d))), ItemData.STAT_NAMES[k]])
		if not diff:
			out.append("Характеристики те же.")
		var w_special: String = str(w.get("proc", "")) + str(w.get("use", "")) + str(w.get("set_id", "")) + str(w.get("unique_id", ""))
		if w_special != "":
			out.append("У надетого есть особое свойство (прок, сет или легендарный эффект) — см. его подсказку.")
	return out

# ---------------------------------------------------------------- сеты и именные легендарки (сессия 07б)
const SetData := preload("res://scripts/data/set_data.gd")

## Сервер: часть сета set_id в ячейке slot — фиолетовая, со свойствами сета, без прока.
func make_set_piece(set_id: String, slot: String, ilvl: int, seed: int = -1) -> String:
	var sd: Dictionary = SetData.SETS[set_id]
	var base: String = SetData.BASES[sd["armor"]][slot]
	if seed < 0:
		seed = randi() % 1000000
	var d: Dictionary = ItemData.roll(base, ilvl, 3, seed)
	d["affixes"] = sd["affixes"].duplicate()
	d["proc"] = ""
	d["set_id"] = set_id
	return ItemData.encode(d)

## Сервер: именная легендарка (оранжевая, свойства по шаблону, эффект — из SetData.LEGENDARIES).
func make_legendary(lid: String, ilvl: int, seed: int = -1) -> String:
	var ld: Dictionary = SetData.LEGENDARIES[lid]
	if seed < 0:
		seed = randi() % 1000000
	var d: Dictionary = ItemData.roll(ld["base"], ilvl, 3, seed)
	d["q"] = 4
	d["proc"] = ""
	d["unique_id"] = lid
	return ItemData.encode(d)

## Сколько частей каждого сета надето: {set_id: число}.
func set_counts(equip: Dictionary) -> Dictionary:
	var out := {}
	for slot in equip:
		var sid := str(item(str(equip[slot])).get("set_id", ""))
		if SetData.SETS.has(sid):
			out[sid] = int(out.get(sid, 0)) + 1
	return out

## Источники модификаторов от снаряжения для compute_mods: действующие бонусы сетов и эффекты легендарок.
## [данные с mods / flags / proc, ранг 1, id]
func gear_sources(equip: Dictionary) -> Array:
	var out: Array = []
	var counts := set_counts(equip)
	for sid in counts:
		var bonuses: Dictionary = SetData.SETS[sid]["bonuses"]
		for need in bonuses:
			if int(counts[sid]) >= int(need):
				out.append([bonuses[need], 1, "set:%s:%d" % [sid, int(need)]])
	for slot in equip:
		var lid := str(item(str(equip[slot])).get("unique_id", ""))
		if SetData.LEGENDARIES.has(lid):
			out.append([SetData.LEGENDARIES[lid]["effect"], 1, "leg:%s:%s" % [lid, slot]])
	return out

## Характеристики от бонусов сетов (бонус «2 части» и т.п.).
func set_stats(equip: Dictionary) -> Dictionary:
	var st := {}
	var counts := set_counts(equip)
	for sid in counts:
		var bonuses: Dictionary = SetData.SETS[sid]["bonuses"]
		for need in bonuses:
			if int(counts[sid]) >= int(need):
				for k in bonuses[need].get("stats", {}):
					st[k] = float(st.get(k, 0.0)) + float(bonuses[need]["stats"][k])
	return st

## Строки подсказки: сет (надето N из 6, бонусы — действующие отмечены) или эффект легендарки.
func set_tooltip_lines(it: Dictionary, equip: Dictionary = {}) -> Array:
	var lines: Array = []
	var sid := str(it.get("set_id", ""))
	if SetData.SETS.has(sid):
		var sd: Dictionary = SetData.SETS[sid]
		var n := int(set_counts(equip).get(sid, 0))
		lines.append("Сет «%s» (%s): надето %d из 6" % [sd["name"], CLASSES[sd["class"]]["name"], n])
		var keys: Array = sd["bonuses"].keys()
		keys.sort()
		for need in keys:
			lines.append("%s(%d) %s" % ["✔ " if n >= int(need) else "   ", int(need), sd["bonuses"][need]["desc"]])
	var lid := str(it.get("unique_id", ""))
	if SetData.LEGENDARIES.has(lid):
		lines.append("Легендарный эффект: " + str(SetData.LEGENDARIES[lid]["desc"]))
	return lines
