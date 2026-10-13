extends RefCounted
## Предметы: снаряжение (6 ячеек) и расходники. Снаряжение строится из шаблонов и 6 ступеней качества.

const SLOTS := {"weapon": "Оружие", "offhand": "Левая рука", "helm": "Голова", "chest": "Доспех", "boots": "Обувь", "ring": "Кольцо", "amulet": "Амулет"}
const SLOT_ORDER := ["weapon", "offhand", "helm", "chest", "boots", "ring", "amulet"]
## Оружие в левой руке (только воин с талантом «Бой двумя руками») даёт эту долю характеристик.
const OFFHAND_RATIO := 0.6

## Цвет названия по качеству (как в WoW): обычное, необычное, редкое, эпическое, легендарное.
const QUALITY := [Color(0.9, 0.9, 0.9), Color(0.35, 1.0, 0.35), Color(0.35, 0.6, 1.0), Color(0.75, 0.45, 1.0), Color(1.0, 0.6, 0.2)]

## Ступени: прилагательные (м, ж, с, мн), уровень, цена, качество.
const TIERS := [
	{"adj": ["Медный", "Медная", "Медное", "Медные"], "level": 1, "price": 25, "q": 0},
	{"adj": ["Железный", "Железная", "Железное", "Железные"], "level": 5, "price": 80, "q": 1},
	{"adj": ["Стальной", "Стальная", "Стальное", "Стальные"], "level": 10, "price": 200, "q": 1},
	{"adj": ["Мифриловый", "Мифриловая", "Мифриловое", "Мифриловые"], "level": 15, "price": 420, "q": 2},
	{"adj": ["Рунический", "Руническая", "Руническое", "Рунические"], "level": 20, "price": 800, "q": 3},
	{"adj": ["Драконий", "Драконья", "Драконье", "Драконьи"], "level": 25, "price": 1400, "q": 4},
]

## Шаблоны снаряжения: g — род (0 м, 1 ж, 2 с, 3 мн), stats — прибавка за ступень.
const TEMPLATES := {
	"staff": {"name": "посох", "g": 0, "slot": "weapon", "classes": ["mage", "priest"], "icon": "staff", "stats": {"int": 4, "spi": 2, "sp": 6}},
	"wand": {"name": "жезл", "g": 0, "slot": "weapon", "classes": ["mage", "priest"], "icon": "wand", "stats": {"int": 3, "sp": 8}},
	"sword": {"name": "меч", "g": 0, "slot": "weapon", "classes": ["paladin", "warrior"], "icon": "sword", "stats": {"str": 4, "sta": 2, "ap": 6}},
	"axe": {"name": "топор", "g": 0, "slot": "weapon", "classes": ["warrior"], "icon": "axe", "stats": {"str": 5, "agi": 2, "ap": 6}},
	"mace": {"name": "булава", "g": 1, "slot": "weapon", "classes": ["paladin", "priest"], "icon": "mace", "stats": {"str": 2, "int": 3, "sp": 4, "ap": 3}},
	"robe": {"name": "мантия", "g": 1, "slot": "chest", "icon": "robe", "stats": {"int": 3, "spi": 3, "sta": 2, "armor": 0.01}},
	"mail": {"name": "кольчуга", "g": 1, "slot": "chest", "icon": "mail", "stats": {"str": 2, "agi": 2, "sta": 3, "armor": 0.02}},
	"plate": {"name": "кираса", "g": 1, "slot": "chest", "icon": "plate", "stats": {"str": 3, "sta": 4, "armor": 0.03}},
	"helm": {"name": "шлем", "g": 0, "slot": "helm", "icon": "helm", "stats": {"str": 1, "sta": 2, "armor": 0.01}},
	"hood": {"name": "капюшон", "g": 0, "slot": "helm", "icon": "hood", "stats": {"int": 2, "spi": 2}},
	"boots": {"name": "сапоги", "g": 3, "slot": "boots", "icon": "boots", "stats": {"agi": 2, "sta": 2, "armor": 0.005}},
	"ring_mind": {"name": "кольцо мудрости", "g": 2, "slot": "ring", "icon": "ring", "stats": {"int": 2, "spi": 2, "sp": 2}},
	"ring_might": {"name": "кольцо силы", "g": 2, "slot": "ring", "icon": "ring", "stats": {"str": 2, "agi": 2, "ap": 2}},
	"amulet": {"name": "амулет", "g": 0, "slot": "amulet", "icon": "amulet", "stats": {"sta": 3, "sp": 2, "ap": 2}},
}

## Расходники (продаёт алхимик).
const CONSUMABLES := {
	"potion_heal_1": {"name": "Малое зелье лечения", "level": 1, "price": 15, "q": 0, "icon": "potion_heal", "use": {"heal": 150.0}},
	"potion_heal_2": {"name": "Зелье лечения", "level": 8, "price": 45, "q": 1, "icon": "potion_heal", "use": {"heal": 420.0}},
	"potion_heal_3": {"name": "Большое зелье лечения", "level": 16, "price": 110, "q": 2, "icon": "potion_heal", "use": {"heal": 1000.0}},
	"potion_mana_1": {"name": "Малое зелье маны", "level": 1, "price": 15, "q": 0, "icon": "potion_mana", "use": {"mana": 150.0}},
	"potion_mana_2": {"name": "Зелье маны", "level": 8, "price": 45, "q": 1, "icon": "potion_mana", "use": {"mana": 420.0}},
	"potion_mana_3": {"name": "Большое зелье маны", "level": 16, "price": 110, "q": 2, "icon": "potion_mana", "use": {"mana": 1000.0}},
	"elixir_power": {"name": "Эликсир мощи", "level": 5, "price": 60, "q": 1, "icon": "elixir_power",
		"use": {"buff": "elixir_power", "dur": 180.0, "mods": {"dmg": 0.1}}, "desc": "+10% к урону на 3 минуты."},
	"elixir_fort": {"name": "Эликсир стойкости", "level": 5, "price": 60, "q": 1, "icon": "elixir_fort",
		"use": {"buff": "elixir_fort", "dur": 180.0, "mods": {"hp_pct": 0.1}}, "desc": "+10% к здоровью на 3 минуты."},
	"elixir_wisdom": {"name": "Эликсир мудрости", "level": 5, "price": 60, "q": 1, "icon": "elixir_wisdom",
		"use": {"buff": "elixir_wisdom", "dur": 180.0, "mods": {"regen": 0.5, "mana_pct": 0.05}}, "desc": "Мана восполняется на 50% быстрее, +5% маны на 3 минуты."},
}

const STAT_NAMES := {"str": "Сила", "agi": "Ловкость", "sta": "Выносливость", "int": "Интеллект", "spi": "Дух",
	"sp": "Сила заклинаний", "ap": "Сила атаки", "armor": "Броня"}

const STACK := 20
const SELL_RATIO := 0.25
