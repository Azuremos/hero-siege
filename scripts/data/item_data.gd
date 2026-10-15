extends RefCounted
## Предметы. Снаряжение — экземпляр: шаблон (base) + уровень предмета (ilvl) + качество (q) + свойства.
## Экземпляр хранится и ходит по сети компактной строкой (см. encode/decode), в сумке и снаряжении — она же.
## Расходники — постоянные id (potion_heal_2, elixir_power…).

const SLOTS := {"weapon": "Оружие", "offhand": "Левая рука", "helm": "Голова", "chest": "Доспех", "boots": "Обувь", "ring": "Кольцо", "amulet": "Амулет",
	"trinket": "Аксессуар", "trinket1": "Аксессуар", "trinket2": "Аксессуар"}
const SLOT_ORDER := ["weapon", "offhand", "helm", "chest", "boots", "ring", "amulet", "trinket1", "trinket2"]
## Аксессуар (шаблон со slot "trinket") надевается в одну из двух ячеек.
const TRINKET_SLOTS := ["trinket1", "trinket2"]
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

## Аксессуары (как в WoW): две ячейки, без материала в названии. Белые и зелёные — только характеристики,
## синие — сильнее характеристики (+1 свойство) или слабый прок, фиолетовые — прок или используемый эффект.
## procs — пул проков шаблона (ITEM_PROCS): tier "weak" — с синего, "acc" и "use" — с фиолетового.
## tag — к чему привязан: огонь, лёд, лечение, танк, ярость, прерывание… Сетов у аксессуаров нет (сессия 07б).
const TRINKETS := {
	"tr_ember": {"name": "Тлеющий уголь", "g": 0, "icon": "tr_ember", "role": "caster", "tag": "огонь",
		"stats": {"int": 2, "sp": 3}, "procs": ["a_ember", "a_firestorm", "u_fire_power"]},
	"tr_frost": {"name": "Осколок вечного льда", "g": 0, "icon": "tr_frost", "role": "caster", "tag": "лёд",
		"stats": {"int": 2, "spi": 1, "sp": 2}, "procs": ["a_frostbite", "a_last_stand", "u_ice_barrier"]},
	"tr_naaru": {"name": "Слеза наару", "g": 1, "icon": "tr_naaru", "role": "caster", "tag": "лечение",
		"stats": {"int": 2, "spi": 2, "sp": 1}, "procs": ["a_mend", "a_sanctify", "u_hymn"]},
	"tr_beads": {"name": "Чётки паломника", "g": 3, "icon": "tr_beads", "role": "caster", "tag": "лечение",
		"stats": {"spi": 3, "regen": 0.03}, "procs": ["p_clarity", "a_inspire", "u_hymn"]},
	"tr_guard": {"name": "Знак стража", "g": 0, "icon": "tr_guard", "role": "phys", "tag": "танк",
		"stats": {"sta": 3, "armor": 0.004}, "procs": ["p_guard", "a_last_stand", "u_fortify"]},
	"tr_knight": {"name": "Медальон рыцаря", "g": 0, "icon": "tr_knight", "role": "phys", "tag": "танк",
		"stats": {"str": 2, "sta": 2}, "procs": ["p_power", "a_holy_strike", "u_fortify"]},
	"tr_fang": {"name": "Клык берсерка", "g": 0, "icon": "tr_fang", "role": "phys", "tag": "ярость",
		"stats": {"str": 2, "ap": 3}, "procs": ["a_frenzy", "a_bloodlust", "u_berserk"]},
	"tr_horn": {"name": "Рог предков", "g": 0, "icon": "tr_horn", "role": "phys", "tag": "ярость",
		"stats": {"ap": 3, "sta": 1}, "procs": ["a_frenzy", "a_bloodlust", "u_war_horn"]},
	"tr_seal": {"name": "Печать безмолвия", "g": 1, "icon": "tr_seal", "role": "any", "tag": "прерывание",
		"stats": {"sta": 1, "crit": 0.003}, "procs": ["a_silencer", "a_mana_tap", "u_sprint"]},
	"tr_thunder": {"name": "Громовой камень", "g": 0, "icon": "tr_thunder", "role": "any", "tag": "молнии",
		"stats": {"agi": 1, "int": 1, "crit": 0.003}, "procs": ["a_static", "a_thunder", "u_berserk"]},
	"tr_feather": {"name": "Перо грифона", "g": 2, "icon": "tr_feather", "role": "any", "tag": "скорость",
		"stats": {"agi": 2, "haste": 0.004}, "procs": ["a_swift", "a_thunder", "u_sprint"]},
	"tr_managem": {"name": "Кристалл маны", "g": 0, "icon": "tr_managem", "role": "caster", "tag": "мана",
		"stats": {"int": 3, "regen": 0.02}, "procs": ["p_clarity", "a_mana_tap", "u_mana_gem"]},
	"tr_ward": {"name": "Оберег чародеев", "g": 0, "icon": "tr_ward", "role": "any", "tag": "защита от магии",
		"stats": {"sta": 2, "res": 0.01}, "procs": ["a_ward", "a_last_stand", "u_spell_ward"]},
	"tr_flask": {"name": "Склянка жизни", "g": 1, "icon": "tr_flask", "role": "any", "tag": "выживание",
		"stats": {"sta": 2, "spi": 1}, "procs": ["p_guard", "a_second_wind", "u_heal_flask"]},
	"tr_dragon": {"name": "Глаз дракона", "g": 0, "icon": "tr_dragon", "role": "caster", "tag": "огонь",
		"stats": {"sp": 3, "crit": 0.002}, "procs": ["p_power", "a_firestorm", "u_arcane_power"]},
	"tr_shadow": {"name": "Талисман теней", "g": 0, "icon": "tr_shadow", "role": "any", "tag": "крит",
		"stats": {"agi": 2, "crit": 0.003}, "procs": ["a_shadow", "a_thunder", "u_berserk"]},
	"tr_rune": {"name": "Руна вечности", "g": 1, "icon": "tr_rune", "role": "caster", "tag": "тайная магия",
		"stats": {"int": 2, "sp": 2, "regen": 0.01}, "procs": ["p_haste", "a_mana_tap", "u_arcane_power"]},
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

	# --- проки аксессуаров (сессия 05). Условия: school, crit, magic (урон не физический), below (здоровье ниже доли),
	# every (каждое N-е событие вместо шанса). Действия: buff, spell, absorb_pct, heal_pct, mana_pct (воину — ярость).
	# Слабые (weak) — с синего качества, сильные (acc) — с фиолетового.
	"a_ember": {"tier": "weak", "role": "caster", "name": "Тлеющий жар",
		"on": "spell_hit", "school": "fire", "chance": 0.15, "icd": 15.0, "buff": "proc_ember", "dur": 10.0, "mods": {"amount@fire": 0.12},
		"desc": "Иногда при огненном заклинании: +12% к урону огнём на 10 сек."},
	"a_frostbite": {"tier": "weak", "role": "caster", "name": "Стужа",
		"on": "spell_hit", "school": "frost", "chance": 0.15, "icd": 15.0, "buff": "proc_frostbite", "dur": 10.0, "mods": {"amount@frost": 0.12},
		"desc": "Иногда при ледяном заклинании: +12% к урону льдом на 10 сек."},
	"a_mend": {"tier": "weak", "role": "caster", "name": "Милосердие",
		"on": "heal", "chance": 0.12, "icd": 15.0, "buff": "proc_mend", "dur": 10.0, "mods": {"heal": 0.12},
		"desc": "Иногда при лечении: +12% к лечению на 10 сек."},
	"a_frenzy": {"tier": "weak", "role": "phys", "name": "Неистовство",
		"on": ["auto", "spell_hit"], "crit": true, "chance": 0.2, "icd": 20.0, "buff": "proc_frenzy", "dur": 10.0, "mods": {"haste": 0.15},
		"desc": "При критическом ударе с шансом 20%: +15% к скорости атак и заклинаний на 10 сек."},
	"a_static": {"tier": "weak", "role": "any", "name": "Статический заряд",
		"on": ["auto", "spell_hit"], "crit": true, "chance": 0.2, "icd": 20.0, "buff": "proc_static", "dur": 10.0, "mods": {"crit": 0.05},
		"desc": "При критическом ударе с шансом 20%: +5% к шансу крит. удара на 10 сек."},
	"a_swift": {"tier": "weak", "role": "any", "name": "Попутный ветер",
		"on": ["auto", "spell_hit", "heal"], "crit": true, "chance": 0.1, "icd": 20.0, "buff": "proc_swift", "dur": 10.0, "mods": {"speed": 0.2},
		"desc": "При критическом эффекте с шансом 10%: +20% к скорости бега на 10 сек."},
	"a_silencer": {"tier": "weak", "role": "any", "name": "Каратель магов",
		"on": "interrupt", "chance": 1.0, "icd": 10.0, "buff": "proc_silencer", "dur": 8.0, "mods": {"dmg": 0.15},
		"desc": "После прерывания: +15% к урону на 8 сек."},
	"a_ward": {"tier": "weak", "role": "any", "name": "Оберег",
		"on": "hit_taken", "magic": true, "chance": 0.15, "icd": 20.0, "buff": "proc_ward", "dur": 8.0, "mods": {"magic_taken": -0.2},
		"desc": "Иногда при получении урона от магии: −20% урона от магии на 8 сек."},
	"a_shadow": {"tier": "weak", "role": "any", "name": "Тень",
		"on": ["auto", "spell_hit"], "crit": true, "chance": 0.15, "icd": 20.0, "buff": "proc_shadow", "dur": 10.0, "mods": {"dmg": 0.1},
		"desc": "При критическом ударе с шансом 15%: +10% к урону на 10 сек."},
	"a_firestorm": {"tier": "acc", "role": "caster", "name": "Огненная буря",
		"on": "spell_hit", "school": "fire", "every": 5, "icd": 2.0, "spell": "flame_burst",
		"desc": "Каждое 5-е попадание огнём — взрыв пламени вокруг цели."},
	"a_thunder": {"tier": "acc", "role": "any", "name": "Гроза",
		"on": ["auto", "spell_hit"], "every": 5, "icd": 2.0, "spell": "chain_spark",
		"desc": "Каждый 5-й удар — молния по врагам вокруг цели."},
	"a_last_stand": {"tier": "acc", "role": "any", "name": "Последний рубеж",
		"on": "hit_taken", "below": 0.3, "chance": 1.0, "icd": 60.0, "absorb_pct": 0.25, "dur": 10.0,
		"desc": "При здоровье ниже 30%: щит, поглощающий 25% здоровья на 10 сек. Не чаще раза в 60 сек."},
	"a_second_wind": {"tier": "acc", "role": "any", "name": "Второе дыхание",
		"on": "hit_taken", "below": 0.3, "chance": 1.0, "icd": 90.0, "heal_pct": 0.25,
		"desc": "При здоровье ниже 30%: мгновенно восполняет 25% здоровья. Не чаще раза в 90 сек."},
	"a_sanctify": {"tier": "acc", "role": "caster", "name": "Благодать наару",
		"on": "heal", "chance": 0.1, "icd": 12.0, "spell": "holy_word_sanctify",
		"desc": "Иногда при лечении: Слово Света: Освящение у цели — лечит союзников и ранит врагов."},
	"a_inspire": {"tier": "acc", "role": "caster", "name": "Озарение",
		"on": "heal", "crit": true, "chance": 0.5, "icd": 10.0, "mana_pct": 0.04,
		"desc": "Критическое лечение с шансом 50% восполняет 4% маны. Не чаще раза в 10 сек."},
	"a_holy_strike": {"tier": "acc", "role": "phys", "name": "Удар Света",
		"on": "auto", "chance": 0.12, "icd": 5.0, "spell": "divine_burst",
		"desc": "Удары оружием иногда вызывают взрыв Света вокруг героя."},
	"a_bloodlust": {"tier": "acc", "role": "phys", "name": "Жажда боя",
		"on": "hit_taken", "chance": 0.15, "icd": 15.0, "mana_pct": 0.15, "buff": "proc_bloodlust", "dur": 8.0, "mods": {"dmg": 0.1},
		"desc": "Иногда при получении удара: +15 ярости (или 15% маны) и +10% к урону на 8 сек."},
	"a_mana_tap": {"tier": "acc", "role": "any", "name": "Похищение силы",
		"on": "interrupt", "chance": 1.0, "icd": 10.0, "mana_pct": 0.08,
		"desc": "После прерывания: восполняет 8% маны (воину — 8 ярости)."},

	# --- используемые эффекты аксессуаров (с фиолетового): своя кнопка, своя перезарядка cd.
	"u_fire_power": {"tier": "use", "role": "caster", "name": "Сердце пламени", "on": "use", "cd": 90.0,
		"buff": "use_fire_power", "dur": 15.0, "mods": {"amount@fire": 0.25},
		"desc": "Использование: +25% к урону огнём на 15 сек. Перезарядка 90 сек."},
	"u_ice_barrier": {"tier": "use", "role": "caster", "name": "Ледяная преграда", "on": "use", "cd": 90.0,
		"absorb_pct": 0.3, "dur": 15.0,
		"desc": "Использование: щит, поглощающий 30% здоровья на 15 сек. Перезарядка 90 сек."},
	"u_hymn": {"tier": "use", "role": "caster", "name": "Гимн наару", "on": "use", "cd": 120.0, "spell": "hymn",
		"desc": "Использование: лечит всех союзников в радиусе 12 м. Перезарядка 120 сек."},
	"u_fortify": {"tier": "use", "role": "phys", "name": "Несокрушимость", "on": "use", "cd": 120.0,
		"buff": "use_fortify", "dur": 12.0, "mods": {"dmg_taken": -0.3},
		"desc": "Использование: −30% получаемого урона на 12 сек. Перезарядка 120 сек."},
	"u_berserk": {"tier": "use", "role": "any", "name": "Боевое безумие", "on": "use", "cd": 120.0,
		"buff": "use_berserk", "dur": 15.0, "mods": {"dmg": 0.2, "haste": 0.1, "dmg_taken": 0.1},
		"desc": "Использование: +20% к урону и +10% к скорости, но +10% получаемого урона на 15 сек. Перезарядка 120 сек."},
	"u_war_horn": {"tier": "use", "role": "phys", "name": "Зов предков", "on": "use", "cd": 120.0, "party": 20.0,
		"buff": "use_war_horn", "dur": 15.0, "mods": {"dmg": 0.1},
		"desc": "Использование: +10% к урону герою и союзникам в радиусе 20 м на 15 сек. Перезарядка 120 сек."},
	"u_sprint": {"tier": "use", "role": "any", "name": "Полёт грифона", "on": "use", "cd": 60.0,
		"buff": "use_sprint", "dur": 8.0, "mods": {"speed": 0.4},
		"desc": "Использование: +40% к скорости бега на 8 сек. Перезарядка 60 сек."},
	"u_mana_gem": {"tier": "use", "role": "caster", "name": "Самоцвет маны", "on": "use", "cd": 120.0, "mana_pct": 0.25,
		"desc": "Использование: восполняет 25% маны. Перезарядка 120 сек., с зельями не делится."},
	"u_spell_ward": {"tier": "use", "role": "any", "name": "Антимагический покров", "on": "use", "cd": 90.0,
		"buff": "use_spell_ward", "dur": 10.0, "mods": {"magic_taken": -0.4},
		"desc": "Использование: −40% урона от магии на 10 сек. Перезарядка 90 сек."},
	"u_heal_flask": {"tier": "use", "role": "any", "name": "Глоток жизни", "on": "use", "cd": 90.0, "heal_pct": 0.3,
		"desc": "Использование: восполняет 30% здоровья. Перезарядка 90 сек., с зельями не делится."},
	"u_arcane_power": {"tier": "use", "role": "caster", "name": "Вечное пламя разума", "on": "use", "cd": 120.0,
		"buff": "use_arcane_power", "dur": 15.0, "mods": {"amount": 0.15},
		"desc": "Использование: +15% к урону и лечению заклинаний на 15 сек. Перезарядка 120 сек."},
}

## Именные вещи боссов (unique_id экземпляра): своё название, шаблон, качество не ниже q.
## Главные боссы — эпическое, лейтенанты — редкое. Аксессуары с уникальными проками — в сессии 05.
const UNIQUES := {
	"u_lich_staff": {"name": "Посох Вечной Зимы", "base": "staff", "q": 3, "boss": "Лич-некромант"},
	"u_lich_hood": {"name": "Капюшон Повелителя Костей", "base": "hood", "q": 3, "boss": "Лич-некромант"},
	"u_warlord_axe": {"name": "Топор Костяного Полководца", "base": "axe", "q": 2, "boss": "Костяной полководец"},
	"u_chief_axe": {"name": "Секира Вождя Орды", "base": "axe", "q": 3, "boss": "Вождь орды"},
	"u_chief_mail": {"name": "Кольчуга Лок'тар", "base": "mail", "q": 3, "boss": "Вождь орды"},
	"u_wolf_boots": {"name": "Сапоги Вожака Стаи", "base": "boots", "q": 2, "boss": "Вожак волчьей стаи"},
	"u_fel_wand": {"name": "Жезл Горящего Легиона", "base": "wand", "q": 3, "boss": "Владыка Скверны"},
	"u_fel_robe": {"name": "Мантия Владыки Скверны", "base": "robe", "q": 3, "boss": "Владыка Скверны"},
	"u_infernal_plate": {"name": "Кираса Раскалённого Камня", "base": "plate", "q": 2, "boss": "Инфернал-исполин"},
	"u_king_mace": {"name": "Скипетр Короля Огров", "base": "mace", "q": 3, "boss": "Король огров"},
	"u_king_ring": {"name": "Печатка Короля Огров", "base": "ring_might", "q": 3, "boss": "Король огров"},
	"u_ogre2_staff": {"name": "Посох Двух Голов", "base": "staff", "q": 2, "boss": "Двухголовый огр"},
}

const STAT_NAMES := {"str": "Сила", "agi": "Ловкость", "sta": "Выносливость", "int": "Интеллект", "spi": "Дух",
	"res": "Сопротивление магии", "regen": "к восполнению маны", "haste": "к скорости атак и заклинаний",
	"sp": "Сила заклинаний", "ap": "Сила атаки", "armor": "Броня", "crit": "Шанс крит. удара"}
## Порядок строк в подсказке.
const STAT_ORDER := ["str", "agi", "sta", "int", "spi", "sp", "ap", "crit", "haste", "regen", "res", "armor"]
## Доли, а не единицы (в подсказке — проценты).
const PCT_STATS := ["armor", "crit", "haste", "regen", "res"]
## Характеристики аксессуаров, которые идут не в атрибуты, а в модификаторы героя (unit.gear_mods): ключ модификатора и знак.
const MOD_STATS := {"res": ["magic_taken", -1.0], "regen": ["regen", 1.0], "haste": ["haste", 1.0]}

# ---------------------------------------------------------------- экземпляр

## Экземпляр снаряжения: {base, ilvl, q, affixes: [ключи AFFIXES], proc, seed, set_id, unique_id}.
## Строка: «base:ilvl:q:affix.affix:proc:seed:set_id:unique_id» — компактно для сети и сохранений (сессия 07).
## set_id и unique_id — заготовка для сетов и именных легендарок (сессия 07б), пока пустые.
static func encode(d: Dictionary) -> String:
	return "%s:%d:%d:%s:%s:%d:%s:%s" % [d["base"], int(d["ilvl"]), int(d["q"]), ".".join(PackedStringArray(d.get("affixes", []))),
		d.get("proc", ""), int(d.get("seed", 0)), d.get("set_id", ""), d.get("unique_id", "")]

static func is_gear_id(id: String) -> bool:
	return id.contains(":")

## Шаблон по ключу: снаряжение (TEMPLATES) или аксессуар (TRINKETS, slot "trinket"). {} — нет такого.
static func tpl(base: String) -> Dictionary:
	if TEMPLATES.has(base):
		return TEMPLATES[base]
	if TRINKETS.has(base):
		return TRINKETS[base]
	return {}

static func is_trinket_base(base: String) -> bool:
	return TRINKETS.has(base)

## Используемый эффект вещи (id прока с on == "use") или "".
static func use_of(id: String) -> String:
	if id == "" or not is_gear_id(id):
		return ""
	var d := decode(id)
	if d.is_empty() or d["proc"] == "":
		return ""
	return d["proc"] if str(ITEM_PROCS[d["proc"]]["on"]) == "use" else ""

## Строка -> словарь; пустой словарь, если строка битая (клиенту не доверяем — сервер проверит и это).
static func decode(id: String) -> Dictionary:
	var p := id.split(":")
	if p.size() != 8 or tpl(p[0]).is_empty() or not p[1].is_valid_int() or not p[2].is_valid_int() or not p[5].is_valid_int():
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
## Аксессуар: синий — +1 свойство или слабый прок (пополам), фиолетовый — прок или используемый эффект;
## легендарных аксессуаров пока нет (именные — сессия 07б), такой бросок становится фиолетовым.
static func roll(base: String, ilvl: int, q: int, seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var tp := tpl(base)
	var trinket := is_trinket_base(base)
	if trinket:
		q = mini(q, 3)
	var pool: Array = []
	for a in AFFIXES:
		var r: String = AFFIXES[a]["role"]
		if r == "any" or tp["role"] == "any" or r == tp["role"]:
			pool.append(a)
	var n_aff: int = QUALITY_AFFIXES[q]
	var proc := ""
	if trinket and q >= 2:
		var tiers: Array = ["weak"] if q == 2 else ["acc", "use"]
		var own: Array = tp["procs"].filter(func(pid): return tiers.has(ITEM_PROCS[pid]["tier"]))
		if q == 3 or rng.randf() < 0.5:
			proc = own[rng.randi() % own.size()]
		else:
			n_aff += 1          # синий без прока — характеристики сильнее
	elif q >= 3:
		var tier := "legend" if q >= 4 else "weak"
		var procs: Array = []
		for pid in ITEM_PROCS:
			var pr: Dictionary = ITEM_PROCS[pid]
			if pr["tier"] == tier and (pr["role"] == "any" or tp["role"] == "any" or pr["role"] == tp["role"]):
				procs.append(pid)
		proc = procs[rng.randi() % procs.size()]
	var affixes: Array = []
	for i in n_aff:
		var a: String = pool[rng.randi() % pool.size()]
		pool.erase(a)
		affixes.append(a)
	return {"base": base, "ilvl": clampi(ilvl, 1, MAX_ILVL), "q": q, "affixes": affixes, "proc": proc, "seed": seed, "set_id": "", "unique_id": ""}

## Описание экземпляра для интерфейса и расчёта: {id, name, kind, slot, stats, level, price, q, icon, classes, proc, use…}.
static func describe(id: String) -> Dictionary:
	var d := decode(id)
	if d.is_empty():
		return {}
	var tp := tpl(d["base"])
	var trinket := is_trinket_base(d["base"])
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
	# у аксессуаров нет материала: «Тлеющий уголь совы»
	var name: String = tp["name"] if trinket else "%s %s" % [material(ilvl, tp["g"]), tp["name"]]
	if d["proc"] != "" and q >= 4:
		name += " " + str(ITEM_PROCS[d["proc"]]["suffix"])
	elif not d["affixes"].is_empty() and tp.get("suffix", true):
		name += " " + str(AFFIXES[d["affixes"][0]]["suffix"])
	if UNIQUES.has(d["unique_id"]):
		name = UNIQUES[d["unique_id"]]["name"]
	var slot: String = tp.get("slot", "trinket")
	var small: bool = slot in ["ring", "amulet", "boots", "helm", "trinket"]
	var price := int(ilvl_price(ilvl) * float(QUALITY_PRICE[q]) * (0.6 if small else 1.0))
	var is_use: bool = d["proc"] != "" and str(ITEM_PROCS[d["proc"]]["on"]) == "use"
	return {"id": id, "name": name, "kind": "gear", "slot": slot, "stats": st, "level": ilvl, "ilvl": ilvl, "price": price,
		"q": q, "icon": tp["icon"], "classes": tp.get("classes", []), "base": d["base"], "affixes": d["affixes"],
		"proc": "" if is_use else d["proc"], "use": d["proc"] if is_use else "", "trinket": trinket,
		"set_id": d["set_id"], "unique_id": d["unique_id"]}

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
	var tp := tpl(it["base"])
	if not tp.has("models"):
		return {}
	var ti := tier_index(int(it["ilvl"]))
	var models: Array = tp["models"]
	var mdl: String = models[mini(ti, models.size() - 1)]
	return {"model": mdl, "tint": TIER_TINT[ti], "q": int(it["q"]), "two_hand": TWO_HANDED.has(mdl)}

## Двуручная ли вещь (по её модели).
static func is_two_handed(id: String) -> bool:
	return bool(look(id).get("two_hand", false))
