extends RefCounted
## Предметы. Снаряжение — экземпляр: шаблон (base) + уровень предмета (ilvl) + качество (q) + свойства.
## Экземпляр хранится и ходит по сети компактной строкой (см. encode/decode), в сумке и снаряжении — она же.
## Расходники — постоянные id (potion_heal_2, elixir_power…).

const SLOTS := {"weapon": "Оружие", "offhand": "Левая рука", "helm": "Голова", "chest": "Доспех", "boots": "Обувь", "ring": "Кольцо", "amulet": "Амулет"}
const SLOT_ORDER := ["weapon", "offhand", "helm", "chest", "boots", "ring", "amulet"]
## Оружие в левой руке (только воин с талантом «Бой двумя руками») даёт эту долю характеристик.
const OFFHAND_RATIO := 0.6

# ---------------------------------------------------------------- качество

## Цвет названия по качеству (как в WoW): обычное, необычное, редкое, эпическое, легендарное.
const QUALITY := [Color(0.9, 0.9, 0.9), Color(0.35, 1.0, 0.35), Color(0.35, 0.6, 1.0), Color(0.75, 0.45, 1.0), Color(1.0, 0.6, 0.2)]
const QUALITY_NAMES := ["Обычное", "Необычное", "Редкое", "Эпическое", "Легендарное"]
## Множитель характеристик шаблона на том же уровне предмета.
const QUALITY_MULT := [1.0, 1.25, 1.55, 1.9, 2.4]
## Дополнительных свойств: у зелёного 1, у синего и выше 2.
const QUALITY_AFFIXES := [0, 1, 2, 2, 2]
## Цена от качества.
const QUALITY_PRICE := [1.0, 1.6, 2.6, 4.5, 8.0]
## Синее в лавке — дороже, чем стоит при продаже/выпадении.
const SHOP_BLUE_MARKUP := 1.8

## Шансы качества выпавшей вещи по уровню героев: [с уровня, зелёное, синее, фиолетовое, легендарное].
## Остальное — белое. Между строками — плавно. Подобраны симуляцией tools/loot_sim.gd (таблица в отчёте 04б).
const QUALITY_CHANCE := [
	[1, 0.30, 0.015, 0.0, 0.0],
	[5, 0.33, 0.04, 0.006, 0.0],
	[10, 0.35, 0.08, 0.015, 0.0],
	[15, 0.36, 0.11, 0.03, 0.003],
	[20, 0.36, 0.13, 0.045, 0.006],
	[30, 0.36, 0.16, 0.06, 0.012],
]
## Источник добычи повышает качество: множитель шансов синего и выше, прибавка к зелёному, «не ниже».
const SOURCE_BONUS := {
	"mob": {"mult": 1.0, "green": 0.0, "min_q": 0},
	"elite": {"mult": 3.0, "green": 0.15, "min_q": 1},
	"champion": {"mult": 5.0, "green": 0.2, "min_q": 1},
	"boss": {"mult": 7.0, "green": 0.2, "min_q": 2},
}

# ---------------------------------------------------------------- уровень предмета и материал

## Материал по уровню предмета: прилагательные (м, ж, с, мн) и с какого уровня.
const TIERS := [
	{"adj": ["Медный", "Медная", "Медное", "Медные"], "level": 1},
	{"adj": ["Железный", "Железная", "Железное", "Железные"], "level": 5},
	{"adj": ["Стальной", "Стальная", "Стальное", "Стальные"], "level": 10},
	{"adj": ["Мифриловый", "Мифриловая", "Мифриловое", "Мифриловые"], "level": 15},
	{"adj": ["Рунический", "Руническая", "Руническое", "Рунические"], "level": 20},
	{"adj": ["Драконий", "Драконья", "Драконье", "Драконьи"], "level": 25},
]
const MAX_ILVL := 30

## Характеристики шаблона растут с уровнем предмета: ×1 на 1-м, ×3 на 11-м, ×6,8 на 30-м.
static func ilvl_mult(ilvl: int) -> float:
	return 0.8 + 0.2 * float(ilvl)

## Базовая цена белой вещи уровня ilvl.
static func ilvl_price(ilvl: int) -> float:
	return 15.0 + 2.2 * float(ilvl * ilvl)

static func material(ilvl: int, gender: int) -> String:
	var adj: String = TIERS[0]["adj"][gender]
	for t in TIERS:
		if ilvl >= int(t["level"]):
			adj = t["adj"][gender]
	return adj

# ---------------------------------------------------------------- шаблоны и свойства

## Шаблоны снаряжения: g — род (0 м, 1 ж, 2 с, 3 мн), stats — на 1-м уровне белого качества,
## role — какие дополнительные свойства подходят (phys / caster / any), suffix — добавлять ли «…медведя».
## models — модель в руке героя по ступени металла (TIERS), файлы из assets/weapons (KayKit Fantasy Weapons Bits).
const TEMPLATES := {
	"staff": {"name": "посох", "g": 0, "slot": "weapon", "classes": ["mage", "priest"], "icon": "staff", "role": "caster", "stats": {"int": 4, "spi": 2, "sp": 6}, "models": ["staff_A", "staff_A", "staff_B", "staff_B", "staff_B", "staff_B"]},
	"wand": {"name": "жезл", "g": 0, "slot": "weapon", "classes": ["mage", "priest"], "icon": "wand", "role": "caster", "stats": {"int": 3, "sp": 8}, "models": ["wand_A"]},
	"sword": {"name": "меч", "g": 0, "slot": "weapon", "classes": ["paladin", "warrior"], "icon": "sword", "role": "phys", "stats": {"str": 4, "sta": 2, "ap": 6}, "models": ["sword_A", "sword_A", "sword_B", "sword_C", "sword_D", "sword_E"]},
	"axe": {"name": "топор", "g": 0, "slot": "weapon", "classes": ["warrior"], "icon": "axe", "role": "phys", "stats": {"str": 5, "agi": 2, "ap": 6}, "models": ["axe_A", "axe_A", "axe_B", "axe_B", "axe_C", "axe_C"]},
	"mace": {"name": "булава", "g": 1, "slot": "weapon", "classes": ["paladin", "priest"], "icon": "mace", "role": "any", "stats": {"str": 2, "int": 3, "sp": 4, "ap": 3}, "models": ["hammer_A", "hammer_A", "hammer_B", "hammer_B", "hammer_C", "hammer_C"]},
	"robe": {"name": "мантия", "g": 1, "slot": "chest", "icon": "robe", "role": "caster", "stats": {"int": 3, "spi": 3, "sta": 2, "armor": 0.01}},
	"mail": {"name": "кольчуга", "g": 1, "slot": "chest", "icon": "mail", "role": "phys", "stats": {"str": 2, "agi": 2, "sta": 3, "armor": 0.02}},
	"plate": {"name": "кираса", "g": 1, "slot": "chest", "icon": "plate", "role": "phys", "stats": {"str": 3, "sta": 4, "armor": 0.03}},
	"helm": {"name": "шлем", "g": 0, "slot": "helm", "icon": "helm", "role": "phys", "stats": {"str": 1, "sta": 2, "armor": 0.01}},
	"hood": {"name": "капюшон", "g": 0, "slot": "helm", "icon": "hood", "role": "caster", "stats": {"int": 2, "spi": 2}},
	"boots": {"name": "сапоги", "g": 3, "slot": "boots", "icon": "boots", "role": "any", "stats": {"agi": 2, "sta": 2, "armor": 0.005}},
	"ring_mind": {"name": "кольцо мудрости", "g": 2, "slot": "ring", "icon": "ring", "role": "caster", "suffix": false, "stats": {"int": 2, "spi": 2, "sp": 2}},
	"ring_might": {"name": "кольцо силы", "g": 2, "slot": "ring", "icon": "ring", "role": "phys", "suffix": false, "stats": {"str": 2, "agi": 2, "ap": 2}},
	"amulet": {"name": "амулет", "g": 0, "slot": "amulet", "icon": "amulet", "role": "any", "stats": {"sta": 3, "sp": 2, "ap": 2}},
}

## Дополнительные свойства (зелёное и выше): прибавка на 1-м уровне белого, суффикс названия (как «…медведя» в WoW).
const AFFIXES := {
	"str": {"stat": "str", "base": 2.0, "suffix": "медведя", "role": "phys"},
	"agi": {"stat": "agi", "base": 2.0, "suffix": "рыси", "role": "phys"},
	"ap": {"stat": "ap", "base": 4.0, "suffix": "тигра", "role": "phys"},
	"sta": {"stat": "sta", "base": 2.5, "suffix": "кабана", "role": "any"},
	"int": {"stat": "int", "base": 2.0, "suffix": "совы", "role": "caster"},
	"spi": {"stat": "spi", "base": 2.0, "suffix": "ворона", "role": "caster"},
	"sp": {"stat": "sp", "base": 4.0, "suffix": "чародея", "role": "caster"},
	"crit": {"stat": "crit", "base": 0.004, "suffix": "сокола", "role": "any"},
}

## Проки вещей: фиолетовое — слабый (weak), легендарное — уникальный (legend). Срабатывают в общей системе
## проков (spell_system._trigger_procs): on — событие или список, buff — бафф с mods на dur сек., spell — автозаклинание.
## icd — не чаще раза в столько секунд. role — кому подходит. Аксессуары (сессия 05) берут проки отсюда же.
const ITEM_PROCS := {
	"p_power": {"tier": "weak", "role": "any", "name": "Прилив сил", "suffix": "силы",
		"on": ["spell_hit", "auto"], "chance": 0.1, "icd": 20.0, "buff": "proc_power", "dur": 10.0, "mods": {"dmg": 0.08},
		"desc": "Иногда при ударе: +8% к урону на 10 сек."},
	"p_haste": {"tier": "weak", "role": "caster", "name": "Стремительность", "suffix": "ветра",
		"on": ["spell_hit", "heal"], "chance": 0.1, "icd": 20.0, "buff": "proc_haste", "dur": 10.0, "mods": {"haste": 0.1},
		"desc": "Иногда при заклинании: +10% к скорости произнесения на 10 сек."},
	"p_guard": {"tier": "weak", "role": "phys", "name": "Каменная кожа", "suffix": "скалы",
		"on": "hit_taken", "chance": 0.08, "icd": 20.0, "buff": "proc_guard", "dur": 8.0, "mods": {"dmg_taken": -0.1},
		"desc": "Иногда при получении удара: −10% получаемого урона на 8 сек."},
	"p_clarity": {"tier": "weak", "role": "caster", "name": "Ясность", "suffix": "ясности",
		"on": ["spell_hit", "heal"], "chance": 0.1, "icd": 25.0, "buff": "proc_clarity", "dur": 10.0, "mods": {"regen": 1.5},
		"desc": "Иногда при заклинании: мана восполняется на 150% быстрее 10 сек."},
	"l_meteor": {"tier": "legend", "role": "caster", "name": "Гнев пламени", "suffix": "Гнева пламени",
		"on": "spell_hit", "chance": 0.08, "icd": 6.0, "spell": "meteor",
		"desc": "Заклинания иногда обрушивают на врага огненную глыбу."},
	"l_star": {"tier": "legend", "role": "caster", "name": "Звёздный дар", "suffix": "Звёздного дара",
		"on": ["heal", "spell_hit"], "chance": 0.08, "icd": 6.0, "spell": "holy_star",
		"desc": "Заклинания иногда призывают Звезду Света: урон врагам, лечение союзникам рядом."},
	"l_burst": {"tier": "legend", "role": "phys", "name": "Освящённая сталь", "suffix": "Освящённой стали",
		"on": "auto", "chance": 0.12, "icd": 4.0, "spell": "divine_burst",
		"desc": "Удары оружием иногда вызывают взрыв Света вокруг героя."},
	"l_titan": {"tier": "legend", "role": "phys", "name": "Ярость титана", "suffix": "Ярости титана",
		"on": "hit_taken", "chance": 0.1, "icd": 20.0, "buff": "proc_titan", "dur": 8.0, "mods": {"dmg": 0.25, "haste": 0.15},
		"desc": "Иногда при получении удара: +25% к урону и +15% к скорости атак и заклинаний на 8 сек."},
}

const STAT_NAMES := {"str": "Сила", "agi": "Ловкость", "sta": "Выносливость", "int": "Интеллект", "spi": "Дух",
	"sp": "Сила заклинаний", "ap": "Сила атаки", "armor": "Броня", "crit": "Шанс крит. удара"}
## Порядок строк в подсказке.
const STAT_ORDER := ["str", "agi", "sta", "int", "spi", "sp", "ap", "crit", "armor"]
## Доли, а не единицы (в подсказке — проценты).
const PCT_STATS := ["armor", "crit"]

# ---------------------------------------------------------------- экземпляр

## Экземпляр снаряжения: {base, ilvl, q, affixes: [ключи AFFIXES], proc, seed, set_id, unique_id}.
## Строка: «base:ilvl:q:affix.affix:proc:seed:set_id:unique_id» — компактно для сети и сохранений (сессия 07).
## set_id и unique_id — заготовка для сетов и именных легендарок (сессия 07б), пока пустые.
static func encode(d: Dictionary) -> String:
	return "%s:%d:%d:%s:%s:%d:%s:%s" % [d["base"], int(d["ilvl"]), int(d["q"]), ".".join(PackedStringArray(d.get("affixes", []))),
		d.get("proc", ""), int(d.get("seed", 0)), d.get("set_id", ""), d.get("unique_id", "")]

static func is_gear_id(id: String) -> bool:
	return id.contains(":")

## Строка -> словарь; пустой словарь, если строка битая (клиенту не доверяем — сервер проверит и это).
static func decode(id: String) -> Dictionary:
	var p := id.split(":")
	if p.size() != 8 or not TEMPLATES.has(p[0]) or not p[1].is_valid_int() or not p[2].is_valid_int() or not p[5].is_valid_int():
		return {}
	var affixes: Array = []
	for a in p[3].split(".", false):
		if not AFFIXES.has(a):
			return {}
		affixes.append(a)
	if p[4] != "" and not ITEM_PROCS.has(p[4]):
		return {}
	return {"base": p[0], "ilvl": clampi(int(p[1]), 1, MAX_ILVL), "q": clampi(int(p[2]), 0, QUALITY.size() - 1),
		"affixes": affixes, "proc": p[4], "seed": int(p[5]), "set_id": p[6], "unique_id": p[7]}

## Сервер: создать экземпляр. Свойства и прок выбираются по seed и роли шаблона.
static func roll(base: String, ilvl: int, q: int, seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var tp: Dictionary = TEMPLATES[base]
	var pool: Array = []
	for a in AFFIXES:
		var r: String = AFFIXES[a]["role"]
		if r == "any" or tp["role"] == "any" or r == tp["role"]:
			pool.append(a)
	var affixes: Array = []
	for i in QUALITY_AFFIXES[q]:
		var a: String = pool[rng.randi() % pool.size()]
		pool.erase(a)
		affixes.append(a)
	var proc := ""
	if q >= 3:
		var tier := "legend" if q >= 4 else "weak"
		var procs: Array = []
		for pid in ITEM_PROCS:
			var pr: Dictionary = ITEM_PROCS[pid]
			if pr["tier"] == tier and (pr["role"] == "any" or tp["role"] == "any" or pr["role"] == tp["role"]):
				procs.append(pid)
		proc = procs[rng.randi() % procs.size()]
	return {"base": base, "ilvl": clampi(ilvl, 1, MAX_ILVL), "q": q, "affixes": affixes, "proc": proc, "seed": seed, "set_id": "", "unique_id": ""}

## Описание экземпляра для интерфейса и расчёта: {id, name, kind, slot, stats, level, price, q, icon, classes, proc…}.
static func describe(id: String) -> Dictionary:
	var d := decode(id)
	if d.is_empty():
		return {}
	var tp: Dictionary = TEMPLATES[d["base"]]
	var ilvl: int = d["ilvl"]
	var q: int = d["q"]
	# разброс ±6% по seed: две вещи одного уровня и качества чуть различаются
	var spread := 0.94 + 0.12 * float(posmod(int(d["seed"]) * 7919, 1000)) / 1000.0
	var k := ilvl_mult(ilvl) * float(QUALITY_MULT[q]) * spread
	var st := {}
	for s in tp["stats"]:
		st[s] = float(tp["stats"][s]) * k
	for a in d["affixes"]:
		var ad: Dictionary = AFFIXES[a]
		st[ad["stat"]] = float(st.get(ad["stat"], 0.0)) + float(ad["base"]) * k
	for s in st:
		if not PCT_STATS.has(s):
			st[s] = maxf(1.0, roundf(st[s]))
	var name := "%s %s" % [material(ilvl, tp["g"]), tp["name"]]
	if d["proc"] != "" and q >= 4:
		name += " " + str(ITEM_PROCS[d["proc"]]["suffix"])
	elif not d["affixes"].is_empty() and tp.get("suffix", true):
		name += " " + str(AFFIXES[d["affixes"][0]]["suffix"])
	var small: bool = tp["slot"] in ["ring", "amulet", "boots", "helm"]
	var price := int(ilvl_price(ilvl) * float(QUALITY_PRICE[q]) * (0.6 if small else 1.0))
	return {"id": id, "name": name, "kind": "gear", "slot": tp["slot"], "stats": st, "level": ilvl, "ilvl": ilvl, "price": price,
		"q": q, "icon": tp["icon"], "classes": tp.get("classes", []), "base": d["base"], "affixes": d["affixes"],
		"proc": d["proc"], "set_id": d["set_id"], "unique_id": d["unique_id"]}

## Шансы качества [белое, зелёное, синее, фиолетовое, легендарное] для уровня героев и источника.
static func quality_weights(level: int, source: String = "mob") -> Array:
	var lo: Array = QUALITY_CHANCE[0]
	var hi: Array = QUALITY_CHANCE[QUALITY_CHANCE.size() - 1]
	for i in QUALITY_CHANCE.size() - 1:
		if level >= int(QUALITY_CHANCE[i][0]) and level < int(QUALITY_CHANCE[i + 1][0]):
			lo = QUALITY_CHANCE[i]
			hi = QUALITY_CHANCE[i + 1]
			break
	var f := 0.0 if int(hi[0]) == int(lo[0]) else clampf(float(level - int(lo[0])) / float(int(hi[0]) - int(lo[0])), 0.0, 1.0)
	var b: Dictionary = SOURCE_BONUS.get(source, SOURCE_BONUS["mob"])
	var w := [0.0, 0.0, 0.0, 0.0, 0.0]
	for q in range(1, 5):
		w[q] = lerpf(float(lo[q]), float(hi[q]), f)
		if q >= 2:
			w[q] *= float(b["mult"])
	w[1] += float(b["green"])
	# не ниже min_q: доли худших качеств переходят к min_q
	for q in int(b["min_q"]):
		w[q] = 0.0
	var rest := 1.0
	for q in range(1, 5):
		rest -= w[q]
	w[0] = maxf(0.0, rest)
	if int(b["min_q"]) > 0:
		var s := 0.0
		for q in range(int(b["min_q"]) + 1, 5):
			s += w[q]
		w[int(b["min_q"])] = maxf(0.0, 1.0 - s)
	return w

static func roll_quality(level: int, source: String, r: float) -> int:
	var w := quality_weights(level, source)
	for q in range(4, -1, -1):
		if r < w[q]:
			return q
		r -= w[q]
	return 0

# ---------------------------------------------------------------- расходники

## Зелья восполняют долю запаса (heal_pct / mana_pct), чтобы не обесцениваться с уровнем.
## Ступень выпадающего зелья — по уровню героев: drop_level — с какого уровня падает.
const CONSUMABLES := {
	"potion_heal_1": {"name": "Малое зелье лечения", "level": 1, "drop_level": 1, "price": 15, "q": 0, "icon": "potion_heal", "use": {"heal_pct": 0.2}},
	"potion_heal_2": {"name": "Зелье лечения", "level": 8, "drop_level": 8, "price": 45, "q": 1, "icon": "potion_heal", "use": {"heal_pct": 0.35}},
	"potion_heal_3": {"name": "Большое зелье лечения", "level": 15, "drop_level": 15, "price": 110, "q": 2, "icon": "potion_heal", "use": {"heal_pct": 0.5}},
	"potion_heal_4": {"name": "Превосходное зелье лечения", "level": 22, "drop_level": 22, "price": 220, "q": 3, "icon": "potion_heal", "use": {"heal_pct": 0.6}},
	"potion_mana_1": {"name": "Малое зелье маны", "level": 1, "drop_level": 1, "price": 15, "q": 0, "icon": "potion_mana", "use": {"mana_pct": 0.2}},
	"potion_mana_2": {"name": "Зелье маны", "level": 8, "drop_level": 8, "price": 45, "q": 1, "icon": "potion_mana", "use": {"mana_pct": 0.35}},
	"potion_mana_3": {"name": "Большое зелье маны", "level": 15, "drop_level": 15, "price": 110, "q": 2, "icon": "potion_mana", "use": {"mana_pct": 0.5}},
	"potion_mana_4": {"name": "Превосходное зелье маны", "level": 22, "drop_level": 22, "price": 220, "q": 3, "icon": "potion_mana", "use": {"mana_pct": 0.6}},
	"elixir_power": {"name": "Эликсир мощи", "level": 5, "price": 60, "q": 1, "icon": "elixir_power", "elixir": true,
		"use": {"buff": "elixir_power", "dur": 180.0, "mods": {"dmg": 0.1}}, "desc": "+10% к урону на 3 минуты."},
	"elixir_fort": {"name": "Эликсир стойкости", "level": 5, "price": 60, "q": 1, "icon": "elixir_fort", "elixir": true,
		"use": {"buff": "elixir_fort", "dur": 180.0, "mods": {"hp_pct": 0.1}}, "desc": "+10% к здоровью на 3 минуты."},
	"elixir_wisdom": {"name": "Эликсир мудрости", "level": 5, "price": 60, "q": 1, "icon": "elixir_wisdom", "elixir": true,
		"use": {"buff": "elixir_wisdom", "dur": 180.0, "mods": {"regen": 0.5, "mana_pct": 0.05}}, "desc": "Мана восполняется на 50% быстрее, +5% маны на 3 минуты."},
	"elixir_haste": {"name": "Эликсир быстроты", "level": 8, "price": 80, "q": 1, "icon": "elixir_haste", "elixir": true,
		"use": {"buff": "elixir_haste", "dur": 180.0, "mods": {"haste": 0.08}}, "desc": "+8% к скорости произнесения и атак на 3 минуты."},
	"elixir_crit": {"name": "Эликсир меткости", "level": 8, "price": 80, "q": 1, "icon": "elixir_crit", "elixir": true,
		"use": {"buff": "elixir_crit", "dur": 180.0, "mods": {"crit": 0.05}}, "desc": "+5% к шансу критического удара на 3 минуты."},
	"elixir_warding": {"name": "Эликсир защиты от магии", "level": 10, "price": 90, "q": 1, "icon": "elixir_warding", "elixir": true,
		"use": {"buff": "elixir_warding", "dur": 180.0, "mods": {"magic_taken": -0.2}}, "desc": "−20% урона от магии (огонь, лёд, тьма, Скверна…) на 3 минуты."},
	"elixir_swift": {"name": "Эликсир стремительности", "level": 3, "price": 50, "q": 1, "icon": "elixir_swift", "elixir": true,
		"use": {"buff": "elixir_swift", "dur": 180.0, "mods": {"speed": 0.15}}, "desc": "+15% к скорости бега на 3 минуты."},
}

const STACK := 20
const SELL_RATIO := 0.25

# ---------------------------------------------------------------- облик вещи на герое

## Оттенок металла по ступени (TIERS): медь, железо, сталь, мифрил, руны, драконья.
const TIER_TINT := [Color(0.95, 0.62, 0.42), Color(0.72, 0.72, 0.75), Color(1.0, 1.0, 1.0),
	Color(0.78, 0.92, 1.05), Color(0.75, 0.8, 1.15), Color(1.1, 0.7, 0.5)]
## Двуручные модели: левая рука пуста (без щита, книги и второго оружия), удары — двуручные.
const TWO_HANDED := ["sword_D", "sword_E", "axe_C", "hammer_C", "staff_A", "staff_B", "halberd", "spear_A"]

## Свечение по качеству: фиолетовое мерцает, легендарное светится (и искрит).
const QUALITY_GLOW := {3: Color(0.42, 0.18, 1.0), 4: Color(1.0, 0.55, 0.15)}

static func tier_index(ilvl: int) -> int:
	var idx := 0
	for i in TIERS.size():
		if ilvl >= int(TIERS[i]["level"]):
			idx = i
	return idx

## Как выглядит вещь в руке: модель, оттенок металла, качество. {} — у вещи нет модели.
static func look(id: String) -> Dictionary:
	if id == "" or not is_gear_id(id):
		return {}
	var it := describe(id)
	if it.is_empty():
		return {}
	var tp: Dictionary = TEMPLATES.get(it["base"], {})
	if not tp.has("models"):
		return {}
	var ti := tier_index(int(it["ilvl"]))
	var models: Array = tp["models"]
	var mdl: String = models[mini(ti, models.size() - 1)]
	return {"model": mdl, "tint": TIER_TINT[ti], "q": int(it["q"]), "two_hand": TWO_HANDED.has(mdl)}

## Двуручная ли вещь (по её модели).
static func is_two_handed(id: String) -> bool:
	return bool(look(id).get("two_hand", false))
