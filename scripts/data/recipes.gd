extends RefCounted
## Сборка предметов (сессия 13) — у NPC «Мастер сборки» во всех режимах (в осаде — рядом с кузнецом, в «Линиях»
## и на Арене — на базе). Компоненты — шаблоны и качество, а не конкретные экземпляры: «любые 2 синих кольца
## ловкости». Результат — новый экземпляр по обычным правилам (ItemData.roll): уровень предмета — как у лучшего
## компонента, свойства и прок — случайные по качеству (фиолетовое — со слабым проком). Легендарку не собрать.
## Части сетов, именные и легендарные вещи компонентами не бывают. Проверяет и собирает сервер (economy.request_craft).
##
## Виды рецептов:
##   merge   — n одинаковых вещей (тот же шаблон и то же качество, до q_max) → тот же шаблон на ступень выше;
##   scroll  — вещь (качество до q_max) + свиток улучшения → та же вещь на ступень выше (новые свойства);
##   combine — набор компонентов разных шаблонов (base, q_min) → шаблон out_base качества out_q.
## Цена — доля gold_k цены результата (у scroll — плюс свиток).

const SCROLL := "scroll_upgrade"
const MAX_Q := 3            # выше фиолетового не собрать (легендарки — только добыча)

const RECIPES := {
	"merge": {"name": "Слияние", "kind": "merge", "n": 2, "q_max": 2, "gold_k": 0.35,
		"desc": "2 одинаковые вещи (тот же вид и качество) → та же вещь на ступень выше: белое → зелёное → синее → фиолетовое."},
	"scroll": {"name": "Улучшение свитком", "kind": "scroll", "q_max": 2, "gold_k": 0.25,
		"desc": "Вещь + Свиток улучшения → та же вещь на ступень выше, свойства — заново. До фиолетового."},
	"warlord_blade": {"name": "Клинок полководца", "kind": "combine", "out_base": "greatsword", "out_q": 3, "gold_k": 0.4,
		"parts": [{"base": "sword", "q_min": 2}, {"base": "shield", "q_min": 2}],
		"desc": "Меч и щит (синие или лучше) переплавляются в фиолетовый двуручный меч."},
	"archmage_staff": {"name": "Посох архимага", "kind": "combine", "out_base": "staff", "out_q": 3, "gold_k": 0.4,
		"parts": [{"base": "wand", "q_min": 2}, {"base": "orb", "q_min": 2}],
		"desc": "Жезл и сфера (синие или лучше) → фиолетовый посох."},
	"storm_staff": {"name": "Посох бури", "kind": "combine", "out_base": "storm_staff", "out_q": 3, "gold_k": 0.4,
		"parts": [{"base": "totem_hammer", "q_min": 2}, {"base": "totem_shield", "q_min": 2}],
		"desc": "Тотемный молот и щит предков (синие или лучше) → фиолетовый посох бури."},
	"wind_bow": {"name": "Лук ветра", "kind": "combine", "out_base": "bow", "out_q": 3, "gold_k": 0.4,
		"parts": [{"base": "crossbow", "q_min": 2}, {"base": "ring_agile", "q_min": 2}],
		"desc": "Арбалет и кольцо ловкости (синие или лучше) → фиолетовый лук."},
	"guardian_plate": {"name": "Доспех стража", "kind": "combine", "out_base": "plate", "out_q": 3, "gold_k": 0.45,
		"parts": [{"base": "plate", "q_min": 1}, {"base": "pads_plate", "q_min": 1}, {"base": "helm", "q_min": 1}],
		"desc": "Кираса, наплечники и шлем (зелёные или лучше) → фиолетовая кираса."},
	"sage_robe": {"name": "Облачение мудреца", "kind": "combine", "out_base": "robe", "out_q": 3, "gold_k": 0.45,
		"parts": [{"base": "robe", "q_min": 1}, {"base": "pads_cloth", "q_min": 1}, {"base": "hat", "q_min": 1}],
		"desc": "Мантия, оплечье и колпак (зелёные или лучше) → фиолетовая мантия."},
	"hunter_leather": {"name": "Снаряжение ловчего", "kind": "combine", "out_base": "leather", "out_q": 3, "gold_k": 0.45,
		"parts": [{"base": "leather", "q_min": 1}, {"base": "leather_hood", "q_min": 1}, {"base": "boots", "q_min": 1}],
		"desc": "Кожаный доспех, кожаная шапка и сапоги (зелёные или лучше) → фиолетовый кожаный доспех."},
	"elemental_mail": {"name": "Кольчуга стихий", "kind": "combine", "out_base": "mail_caster", "out_q": 3, "gold_k": 0.45,
		"parts": [{"base": "mail", "q_min": 1}, {"base": "spirit_hat", "q_min": 1}, {"base": "pads_mail", "q_min": 1}],
		"desc": "Кольчуга, шапка духов и кольчужные наплечники (зелёные или лучше) → фиолетовая кольчуга стихий."},
	"band_of_unity": {"name": "Амулет единства", "kind": "combine", "out_base": "amulet", "out_q": 2, "gold_k": 0.4,
		"parts": [{"base": "ring_mind", "q_min": 1}, {"base": "ring_might", "q_min": 1}],
		"desc": "Кольцо мудрости и кольцо силы (зелёные или лучше) → синий амулет."},
}

const ORDER := ["merge", "scroll", "warlord_blade", "archmage_staff", "storm_staff", "wind_bow", "guardian_plate", "sage_robe",
	"hunter_leather", "elemental_mail", "band_of_unity"]

## Число слотов рецепта (вещи; свиток у scroll — отдельный, из сумки).
static func slots(rid: String) -> int:
	var r: Dictionary = RECIPES[rid]
	match r["kind"]:
		"merge":
			return int(r["n"])
		"scroll":
			return 1
	return (r["parts"] as Array).size()

## Годится ли вещь компонентом вообще: снаряжение без сета, именной и легендарной.
static func usable(it: Dictionary) -> bool:
	return it.get("kind", "") == "gear" and str(it.get("set_id", "")) == "" and str(it.get("unique_id", "")) == "" and int(it.get("q", 0)) < 4

## Годится ли вещь it в слот i рецепта rid, если в других слотах уже лежат chosen (описания вещей или {}).
static func fits(rid: String, i: int, it: Dictionary, chosen: Array) -> bool:
	if not usable(it):
		return false
	var r: Dictionary = RECIPES[rid]
	match r["kind"]:
		"merge":
			if int(it["q"]) > int(r["q_max"]):
				return false
			for c in chosen:
				if not c.is_empty() and (c["base"] != it["base"] or int(c["q"]) != int(it["q"])):
					return false
			return true
		"scroll":
			return int(it["q"]) <= int(r["q_max"])
	var part: Dictionary = r["parts"][i]
	return it["base"] == part["base"] and int(it["q"]) >= int(part["q_min"])

## Проверка набора: "" — можно собрать, иначе почему нельзя. items — описания вещей по слотам ({} — пусто).
## scrolls — сколько свитков улучшения в сумке.
static func check(rid: String, items: Array, scrolls: int) -> String:
	if not RECIPES.has(rid):
		return "Нет такого рецепта"
	if items.size() != slots(rid):
		return "Положите все компоненты"
	for i in items.size():
		if items[i].is_empty():
			return "Положите все компоненты"
		var others: Array = items.duplicate()
		others.remove_at(i)
		if not fits(rid, i, items[i], others):
			return "«%s» не подходит для этого рецепта" % items[i]["name"]
	if RECIPES[rid]["kind"] == "scroll" and scrolls <= 0:
		return "Нужен Свиток улучшения (продаёт Мастер сборки)"
	return ""

## Что получится: {base, q, ilvl}. Уровень предмета — как у лучшего компонента.
static func result(rid: String, items: Array) -> Dictionary:
	var r: Dictionary = RECIPES[rid]
	var ilvl := 1
	for it in items:
		if not it.is_empty():
			ilvl = maxi(ilvl, int(it.get("ilvl", it.get("level", 1))))
	match r["kind"]:
		"merge", "scroll":
			var first: Dictionary = items[0] if not items.is_empty() else {}
			if first.is_empty():
				return {}
			return {"base": first["base"], "q": mini(int(first["q"]) + 1, MAX_Q), "ilvl": ilvl}
	return {"base": r["out_base"], "q": int(r["out_q"]), "ilvl": ilvl}

## Подобрать компоненты из сумки: bag — [[индекс сумки, описание вещи], …]. Возвращает индексы по слотам (-1 — нет).
## Слияние — самая ценная пара одинаковых вещей, свиток — лучшая вещь, сборка — лучшая вещь под каждую часть.
static func auto_fill(rid: String, bag: Array) -> Array:
	var r: Dictionary = RECIPES[rid]
	var n := slots(rid)
	var out: Array = []
	out.resize(n)
	out.fill(-1)
	var cands: Array = bag.filter(func(e): return usable(e[1]))
	cands.sort_custom(func(a, b): return [int(a[1]["q"]), int(a[1]["ilvl"])] > [int(b[1]["q"]), int(b[1]["ilvl"])])
	match r["kind"]:
		"merge":
			var groups := {}
			for e in cands:
				if int(e[1]["q"]) > int(r["q_max"]):
					continue
				var key := "%s:%d" % [e[1]["base"], int(e[1]["q"])]
				if not groups.has(key):
					groups[key] = []
				groups[key].append(e[0])
			for e in cands:
				var key := "%s:%d" % [e[1]["base"], int(e[1]["q"])]
				if groups.has(key) and (groups[key] as Array).size() >= n:
					for i in n:
						out[i] = groups[key][i]
					return out
			return out
		"scroll":
			for e in cands:
				if int(e[1]["q"]) <= int(r["q_max"]):
					out[0] = e[0]
					return out
			return out
	var used := {}
	for i in n:
		for e in cands:
			if not used.has(e[0]) and fits(rid, i, e[1], []):
				out[i] = e[0]
				used[e[0]] = true
				break
	return out

## Чего не хватает (для окна сборки): «синий меч, синий щит» или «2 одинаковые вещи до синего».
static func need_text(rid: String, filled: Array, item_names: Dictionary) -> String:
	var r: Dictionary = RECIPES[rid]
	const QN := ["белое", "зелёное", "синее", "фиолетовое"]
	const QG := ["белого", "зелёного", "синего", "фиолетового"]
	match r["kind"]:
		"merge":
			return "%d одинаковые вещи (качество до %s)" % [int(r["n"]), QG[int(r["q_max"])]]
		"scroll":
			return "вещь качества до %s и Свиток улучшения" % QG[int(r["q_max"])]
	var miss: Array = []
	for i in (r["parts"] as Array).size():
		if i >= filled.size() or int(filled[i]) < 0:
			var part: Dictionary = r["parts"][i]
			miss.append("%s (%s и лучше)" % [item_names.get(part["base"], part["base"]), QN[int(part["q_min"])]])
	return ", ".join(miss)
