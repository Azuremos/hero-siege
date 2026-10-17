extends RefCounted
## Классы, расы, школы магии и атрибуты героев.

const SCHOOLS := {
	"physical": {"name": "Физический", "color": Color(0.95, 0.95, 0.9)},
	"frost":    {"name": "Лёд",        "color": Color(0.45, 0.8, 1.0)},
	"fire":     {"name": "Огонь",      "color": Color(1.0, 0.5, 0.15)},
	"arcane":   {"name": "Тайная магия", "color": Color(0.85, 0.45, 1.0)},
	"holy":     {"name": "Свет",       "color": Color(1.0, 0.88, 0.45)},
	"shadow":   {"name": "Тьма",       "color": Color(0.55, 0.3, 0.75)},
	"nature":   {"name": "Природа",    "color": Color(0.45, 0.9, 0.55)},
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
		"spells": ["frostbolt", "fireball", "arcane_missiles", "frost_nova", "arcane_explosion", "blizzard", "blink", "ice_wall", "arcane_barrage", "fire_wall", "flamestrike", "counterspell"],
	},
	"paladin": {
		"name": "Паладин", "color": Color(0.96, 0.55, 0.73),
		"desc": "Воин Света в латах. Держит удар, карает нежить и лечит союзников.",
		"model": "Knight", "show": ["1H_Sword", "Badge_Shield"], "hide": [], "recolor": "",
		"resource": "mana", "base_hp": 440.0, "base_mana": 150.0, "armor": 0.25, "dmg_mult": 1.0,
		"attrs": {"str": 20, "agi": 10, "sta": 20, "int": 14, "spi": 12}, "grow": {"str": 2.0, "agi": 0.8, "sta": 3.4, "int": 1.3, "spi": 0.9},
		"auto": {"range": 4.0, "min": 24.0, "max": 32.0, "speed": 2.2, "school": "physical", "ranged": false},
		"spells": ["crusader_strike", "holy_light", "judgement", "consecration", "blessing_of_kings", "hammer_of_justice", "avenging_wrath", "holy_wrath", "divine_guardian", "divine_shield", "lay_on_hands", "rebuke"],
	},
	"priest": {
		"name": "Жрец", "color": Color(1.0, 1.0, 1.0),
		"desc": "Маг Света и опора отряда: щиты, исцеление со временем, барьер Света на земле.",
		"model": "Mage", "show": ["1H_Wand", "Spellbook"], "hide": ["Mage_Hat"], "recolor": "priest",
		"resource": "mana", "base_hp": 280.0, "base_mana": 230.0, "armor": 0.0, "dmg_mult": 1.05,
		"attrs": {"str": 6, "agi": 8, "sta": 14, "int": 22, "spi": 22}, "grow": {"str": 0.5, "agi": 0.5, "sta": 2.4, "int": 2.5, "spi": 2.0},
		"auto": {"range": 24.0, "min": 11.0, "max": 15.0, "speed": 1.8, "school": "holy", "ranged": true},
		"spells": ["smite", "flash_heal", "renew", "pw_shield", "pw_fortitude", "holy_fire", "divine_spirit", "circle_of_healing", "prayer_of_healing", "light_barrier", "holy_nova", "silence"],
	},
	"warrior": {
		"name": "Воин", "color": Color(0.78, 0.61, 0.43),
		"desc": "Мастер ближнего боя и танк. Копит ярость в бою: Неистовство, Оружие и Защита.",
		"model": "Barbarian", "show": ["1H_Axe", "Barbarian_Round_Shield"], "hide": [], "recolor": "",
		"resource": "rage", "base_hp": 480.0, "base_mana": 100.0, "armor": 0.3, "dmg_mult": 1.0,
		"attrs": {"str": 24, "agi": 14, "sta": 22, "int": 4, "spi": 6}, "grow": {"str": 2.6, "agi": 1.2, "sta": 3.8, "int": 0.2, "spi": 0.4},
		"auto": {"range": 4.0, "min": 26.0, "max": 34.0, "speed": 2.4, "school": "physical", "ranged": false},
		"spells": ["heroic_strike", "charge", "battle_shout", "thunder_clap", "taunt", "bloodthirst", "whirlwind", "demoralizing_shout", "execute", "shield_wall", "recklessness", "pummel"],
	},
	# Охотник: концентрация вместо маны (100 ед., восполняется сама), питомец, ловушки. Модель — разбойник KayKit
	# в зелёно-коричневой перекраске, в руках арбалет (лук — по надетой вещи).
	"hunter": {
		"name": "Охотник", "color": Color(0.67, 0.83, 0.45),
		"desc": "Стрелок с питомцем. Ловушки перед волной, выстрелы издалека, зверь держит врагов на расстоянии.",
		"model": "Rogue", "show": ["2H_Crossbow"], "hide": [], "recolor": "hunter",
		"resource": "focus", "base_hp": 330.0, "base_mana": 100.0, "armor": 0.12, "dmg_mult": 1.0,
		"attrs": {"str": 8, "agi": 22, "sta": 18, "int": 8, "spi": 10}, "grow": {"str": 0.6, "agi": 2.6, "sta": 2.9, "int": 0.5, "spi": 0.7},
		"auto": {"range": 30.0, "min": 18.0, "max": 24.0, "speed": 2.2, "school": "physical", "ranged": true, "vfx": "arrow", "anim": "bow"},
		"cast_idle": "2H_Ranged_Aiming",     # произнесение (Верный и Прицельный выстрелы) — прицеливание
		"spells": ["steady_shot", "silencing_shot", "call_pet", "mend_pet", "revive_pet", "arcane_shot", "disengage", "multi_shot",
			"concussive_shot", "kill_shot", "hunters_mark", "feign_death", "rapid_fire", "barrage"],
		"ap_attr": "agi",     # сила атаки охотника — от ловкости
	},
	# Шаман (сессия 11): мана, тотемы стихий (зоны у ног, по одному на стихию), молнии, ближний бой и исцеление.
	# Модель — варвар KayKit в бирюзово-синей перекраске с круглым щитом (временная замена — нужен ассет); без оружия в руке —
	# тотемный молот (default_weapon — шаблон вещи). Носит булавы, посохи, щиты, топоры и мечи, плюс свои тотемный молот,
	# посох бури и щит предков: заклинатели берут вещи на интеллект и силу заклинаний, Совершенствование — на силу.
	# races — с какими расами доступен класс (как в WotLK/Cataclysm: дворф и дреней); без поля — с любыми.
	# melee_trees — ветки, в которых бот подходит к цели (Совершенствование); в остальных держится на расстоянии.
	"shaman": {
		"name": "Шаман", "color": Color(0.0, 0.44, 0.87),
		"desc": "Повелитель стихий. Тотемы у ног, молнии и лава, удары оружием, заряженным бурей, и исцеление волнами.",
		"model": "Barbarian", "show": ["Barbarian_Round_Shield"], "hide": [], "recolor": "shaman", "default_weapon": "totem_hammer",
		"resource": "mana", "base_hp": 360.0, "base_mana": 170.0, "armor": 0.15, "dmg_mult": 1.05,
		"attrs": {"str": 14, "agi": 10, "sta": 18, "int": 18, "spi": 16}, "grow": {"str": 1.4, "agi": 0.8, "sta": 2.9, "int": 2.2, "spi": 1.4},
		"auto": {"range": 4.0, "min": 22.0, "max": 30.0, "speed": 2.4, "school": "physical", "ranged": false},
		"spells": ["lightning_bolt", "healing_wave", "flame_shock", "wind_shear", "searing_totem", "lightning_shield",
			"lava_burst", "ghost_wolf", "chain_lightning", "frost_shock", "healing_stream_totem", "astral_shift", "earthquake", "heroism", "elemental_overload"],
		"races": ["dwarf", "draenei"],
		"melee_trees": [1],
	},
}

## Расы, с которыми доступен класс (поле races; без него — все).
static func class_races(class_id: String) -> Array:
	return CLASSES.get(class_id, {}).get("races", RACES.keys())

## Раса героя с учётом совместимости: недоступная классу заменяется первой доступной.
static func fix_race(class_id: String, race_id: String) -> String:
	var allowed := class_races(class_id)
	return race_id if allowed.has(race_id) else str(allowed[0])

## Атрибуты: названия и что дают.
const ATTRS := {
	"str": {"name": "Сила", "desc": "Сила атаки: +1% урона оружием и физическими приёмами за единицу."},
	"agi": {"name": "Ловкость", "desc": "+0.1% к шансу крита и немного брони за единицу."},
	"sta": {"name": "Выносливость", "desc": "+10 к здоровью за единицу."},
	"int": {"name": "Интеллект", "desc": "+15 к мане и +1% к силе заклинаний за единицу."},
	"spi": {"name": "Дух", "desc": "Восполнение маны и здоровья."},
}
