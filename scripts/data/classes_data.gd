extends RefCounted
## Классы, расы, школы магии и атрибуты героев.

const SCHOOLS := {
	"physical": {"name": "Физический", "color": Color(0.95, 0.95, 0.9)},
	"frost":    {"name": "Лёд",        "color": Color(0.45, 0.8, 1.0)},
	"fire":     {"name": "Огонь",      "color": Color(1.0, 0.5, 0.15)},
	"arcane":   {"name": "Тайная магия", "color": Color(0.85, 0.45, 1.0)},
	"holy":     {"name": "Свет",       "color": Color(1.0, 0.88, 0.45)},
	"shadow":   {"name": "Тьма",       "color": Color(0.55, 0.3, 0.75)},
}

# ---------------------------------------------------------------- Расы
const RACES := {
	"human":   {"name": "Человек",      "desc": "+10% к получаемому опыту.",
				"xp_mult": 1.10, "scale": Vector3(1, 1, 1), "skin": ""},
	"dwarf":   {"name": "Дворф",        "desc": "+10% к здоровью. Коренастый и крепкий.",
				"hp_mult": 1.10, "scale": Vector3(1.08, 0.86, 1.08), "skin": ""},
	"elf":     {"name": "Высший эльф",  "desc": "+10% к мане, +5% к силе заклинаний.",
				"mana_mult": 1.10, "power_mult": 1.05, "scale": Vector3(0.96, 1.06, 0.96), "skin": "pale"},
	"draenei": {"name": "Дреней",       "desc": "+10% к исходящему исцелению.",
				"heal_mult": 1.10, "scale": Vector3(1.02, 1.08, 1.02), "skin": "blue"},
}

# ---------------------------------------------------------------- Классы
# model — файл из assets/heroes, show — какие предметы в руках оставить видимыми.
const CLASSES := {
	"mage": {
		"name": "Маг", "color": Color(0.41, 0.8, 0.94),
		"desc": "Повелитель льда, огня и тайной магии. Стены изо льда и пламени, заклинания по площади.",
		"model": "Mage", "show": ["2H_Staff"], "hide": [], "recolor": "",
		"resource": "mana", "base_hp": 260.0, "base_mana": 160.0, "armor": 0.0, "dmg_mult": 1.2,
		"attrs": {"str": 6, "agi": 8, "sta": 12, "int": 24, "spi": 18}, "grow": {"str": 0.5, "agi": 0.6, "sta": 2.2, "int": 2.9, "spi": 1.6},
		"auto": {"range": 24.0, "min": 12.0, "max": 17.0, "speed": 1.8, "school": "arcane", "ranged": true},
		"spells": ["frostbolt", "fireball", "arcane_missiles", "frost_nova", "arcane_explosion", "blizzard", "blink", "ice_wall", "arcane_barrage", "fire_wall", "flamestrike"],
	},
	"paladin": {
		"name": "Паладин", "color": Color(0.96, 0.55, 0.73),
		"desc": "Воин Света в латах. Держит удар, карает нежить и лечит союзников.",
		"model": "Knight", "show": ["1H_Sword", "Badge_Shield"], "hide": [], "recolor": "",
		"resource": "mana", "base_hp": 440.0, "base_mana": 150.0, "armor": 0.25, "dmg_mult": 1.0,
		"attrs": {"str": 20, "agi": 10, "sta": 20, "int": 14, "spi": 12}, "grow": {"str": 2.0, "agi": 0.8, "sta": 3.4, "int": 1.3, "spi": 0.9},
		"auto": {"range": 4.0, "min": 24.0, "max": 32.0, "speed": 2.2, "school": "physical", "ranged": false},
		"spells": ["crusader_strike", "holy_light", "judgement", "consecration", "blessing_of_kings", "hammer_of_justice", "avenging_wrath", "holy_wrath", "divine_guardian", "divine_shield", "lay_on_hands"],
	},
	"priest": {
		"name": "Жрец", "color": Color(1.0, 1.0, 1.0),
		"desc": "Маг Света и опора отряда: щиты, исцеление со временем, барьер Света на земле.",
		"model": "Mage", "show": ["1H_Wand", "Spellbook_open"], "hide": ["Mage_Hat"], "recolor": "priest",
		"resource": "mana", "base_hp": 280.0, "base_mana": 230.0, "armor": 0.0, "dmg_mult": 1.05,
		"attrs": {"str": 6, "agi": 8, "sta": 14, "int": 22, "spi": 22}, "grow": {"str": 0.5, "agi": 0.5, "sta": 2.4, "int": 2.5, "spi": 2.0},
		"auto": {"range": 24.0, "min": 11.0, "max": 15.0, "speed": 1.8, "school": "holy", "ranged": true},
		"spells": ["smite", "flash_heal", "renew", "pw_shield", "pw_fortitude", "holy_fire", "divine_spirit", "circle_of_healing", "prayer_of_healing", "light_barrier", "holy_nova"],
	},
	"warrior": {
		"name": "Воин", "color": Color(0.78, 0.61, 0.43),
		"desc": "Мастер ближнего боя и танк. Копит ярость в бою: Неистовство, Оружие и Защита.",
		"model": "Barbarian", "show": ["1H_Axe", "Barbarian_Round_Shield"], "hide": [], "recolor": "",
		"resource": "rage", "base_hp": 480.0, "base_mana": 100.0, "armor": 0.3, "dmg_mult": 1.0,
		"attrs": {"str": 24, "agi": 14, "sta": 22, "int": 4, "spi": 6}, "grow": {"str": 2.6, "agi": 1.2, "sta": 3.8, "int": 0.2, "spi": 0.4},
		"auto": {"range": 4.0, "min": 26.0, "max": 34.0, "speed": 2.4, "school": "physical", "ranged": false},
		"spells": ["heroic_strike", "charge", "battle_shout", "thunder_clap", "taunt", "bloodthirst", "whirlwind", "demoralizing_shout", "execute", "shield_wall", "recklessness"],
	},
}

## Атрибуты: названия и что дают.
const ATTRS := {
	"str": {"name": "Сила", "desc": "Сила атаки: +1% урона оружием и физическими приёмами за единицу."},
	"agi": {"name": "Ловкость", "desc": "+0.1% к шансу крита и немного брони за единицу."},
	"sta": {"name": "Выносливость", "desc": "+10 к здоровью за единицу."},
	"int": {"name": "Интеллект", "desc": "+15 к мане и +1% к силе заклинаний за единицу."},
	"spi": {"name": "Дух", "desc": "Восполнение маны и здоровья."},
}
