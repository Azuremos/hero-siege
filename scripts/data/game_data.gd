extends Node
## Все игровые данные в одном месте: классы, расы, заклинания, мобы, волны.
## Баланс правится здесь — без изменения логики.

const MAX_LEVEL := 30
const GCD := 1.25                 # глобальное время восстановления
const XP_SHARE_RADIUS := 45.0     # опыт за убийство получают все герои в этом радиусе
const RESPAWN_BASE := 8.0
const CASTLE_HP := 6000.0
const WAVE_COUNT := 20            # полная осада по умолчанию
const MAX_WAVES := 100            # 0 в настройках = бесконечная осада
const POTION_CD := 30.0           # общее восстановление зелий
const FIRST_WAVE_DELAY := 25.0
const WAVE_INTERVAL := 42.0

# ---------------------------------------------------------------- Школы магии
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

# ---------------------------------------------------------------- Заклинания
# target: enemy | ally | self | ground | wall
# delivery: projectile | instant | self_aoe | zone | wall
# effects: список эффектов на цель. Для ally/enemy-разделения — enemy_fx / ally_fx.
const SPELLS := {
	# ======================= МАГ =======================
	"frostbolt": {
		"name": "Ледяная стрела", "school": "frost", "icon": "ЛС",
		"desc": "Урон от льда, замедление на 40%. Три попадания подряд замораживают цель на 3 сек.",
		"target": "enemy", "delivery": "projectile", "speed": 26.0,
		"cast": 2.0, "cd": 0.0, "mana": 22.0, "range": 34.0,
		"effects": [{"type": "damage", "min": 34.0, "max": 40.0}, {"type": "slow", "pct": 0.4, "dur": 6.0}, {"type": "chill", "stacks": 3, "dur": 3.0}],
		"vfx": "bolt_frost", "anim": "cast",
	},
	"fireball": {
		"name": "Огненный шар", "school": "fire", "icon": "ОШ",
		"desc": "Огромный урон от огня и поджог цели (урон в течение 6 сек.).",
		"target": "enemy", "delivery": "projectile", "speed": 24.0,
		"cast": 2.5, "cd": 0.0, "mana": 30.0, "range": 35.0,
		"effects": [{"type": "damage", "min": 52.0, "max": 62.0}, {"type": "dot", "total": 18.0, "dur": 6.0, "tick": 2.0, "key": "ignite"}],
		"vfx": "bolt_fire", "anim": "cast",
	},
	"arcane_barrage": {
		"name": "Чародейский обстрел", "school": "arcane", "icon": "ЧО",
		"desc": "Мгновенный залп тайной магии. Перескакивает ещё на 2 врагов рядом с целью (50% урона).",
		"target": "enemy", "delivery": "projectile", "speed": 42.0,
		"cast": 0.0, "cd": 5.0, "mana": 24.0, "range": 30.0,
		"effects": [{"type": "damage", "min": 30.0, "max": 36.0}, {"type": "chain", "count": 2, "radius": 9.0, "mult": 0.5}],
		"vfx": "bolt_arcane", "anim": "shoot",
	},
	"blizzard": {
		"name": "Снежная буря", "school": "frost", "icon": "СБ",
		"desc": "Ледяной шторм в области 7 м на 6 сек.: урон каждую секунду и замедление на 50%. Кто простоит в буре 3 сек. — замерзает.",
		"target": "ground", "delivery": "zone", "radius": 7.0, "duration": 6.0, "tick": 1.0,
		"cast": 0.0, "cd": 12.0, "mana": 55.0, "range": 36.0,
		"enemy_fx": [{"type": "damage", "min": 13.0, "max": 16.0}, {"type": "slow", "pct": 0.5, "dur": 1.5}, {"type": "chill", "stacks": 3, "dur": 2.5}],
		"vfx": "zone_blizzard", "anim": "raise",
	},
	"ice_wall": {
		"name": "Ледяная стена", "school": "frost", "icon": "ЛСт",
		"desc": "Нарисуйте мышью стену льда (до 14 м) на 18 сек.: зажмите ЛКМ и протяните. Враги не пройдут, пока не сломают её.",
		"target": "wall", "delivery": "wall", "length": 14.0, "duration": 18.0, "wall_hp": 420.0,
		"cast": 0.0, "cd": 20.0, "mana": 45.0, "range": 30.0,
		"vfx": "wall_ice", "anim": "raise",
	},
	"fire_wall": {
		"name": "Стена огня", "school": "fire", "icon": "СО",
		"desc": "Нарисуйте мышью полосу пламени (до 16 м) на 10 сек.: зажмите ЛКМ и протяните. Сжигает всех, кто проходит сквозь неё.",
		"target": "wall", "delivery": "zone_line", "length": 16.0, "width": 2.2, "duration": 10.0, "tick": 0.5,
		"cast": 0.0, "cd": 16.0, "mana": 50.0, "range": 30.0,
		"enemy_fx": [{"type": "damage", "min": 9.0, "max": 11.0}, {"type": "dot", "total": 12.0, "dur": 4.0, "tick": 1.0, "key": "burn"}],
		"vfx": "wall_fire", "anim": "raise",
	},
	"frost_nova": {
		"name": "Кольцо льда", "school": "frost", "icon": "КЛ",
		"desc": "Замораживает всех врагов в радиусе 9 м на 4 сек.",
		"target": "self", "delivery": "self_aoe", "radius": 9.0,
		"cast": 0.0, "cd": 20.0, "mana": 35.0, "range": 0.0,
		"enemy_fx": [{"type": "damage", "min": 16.0, "max": 20.0}, {"type": "freeze", "dur": 4.0}],
		"vfx": "nova_frost", "anim": "raise",
	},
	"flamestrike": {
		"name": "Огненный столб", "school": "fire", "icon": "ОС",
		"desc": "Обрушивает столб огня (радиус 6 м). Земля горит ещё 6 сек.",
		"target": "ground", "delivery": "zone", "radius": 6.0, "duration": 6.0, "tick": 1.0,
		"cast": 2.0, "cd": 10.0, "mana": 55.0, "range": 36.0,
		"impact_fx": [{"type": "damage", "min": 58.0, "max": 70.0}],
		"enemy_fx": [{"type": "damage", "min": 7.0, "max": 9.0}],
		"vfx": "zone_flamestrike", "anim": "cast",
	},

	# --- тайная магия ---
	"arcane_missiles": {
		"name": "Чародейские стрелы", "school": "arcane", "icon": "ЧС",
		"desc": "Поток из 5 чародейских снарядов за 2.5 сек. Нужно стоять на месте.",
		"target": "enemy", "delivery": "channel", "speed": 34.0, "ticks": 5,
		"cast": 2.5, "cd": 0.0, "mana": 30.0, "range": 32.0,
		"effects": [{"type": "damage", "min": 13.0, "max": 16.0}],
		"vfx": "bolt_arcane", "anim": "shoot",
	},
	"arcane_explosion": {
		"name": "Чародейский взрыв", "school": "arcane", "icon": "ЧВ",
		"desc": "Волна тайной магии вокруг мага (8 м). Мало урона, но бьёт всех.",
		"target": "self", "delivery": "self_aoe", "radius": 8.0,
		"cast": 0.0, "cd": 0.0, "mana": 28.0, "range": 0.0,
		"enemy_fx": [{"type": "damage", "min": 18.0, "max": 22.0}],
		"vfx": "nova_arcane", "anim": "raise",
	},
	"blink": {
		"name": "Скачок", "school": "arcane", "icon": "Ск",
		"desc": "Мгновенно переносит мага на 15 м вперёд (стены и здания не пропустят).",
		"target": "self", "delivery": "blink", "distance": 15.0,
		"cast": 0.0, "cd": 15.0, "mana": 20.0, "range": 0.0,
		"effects": [],
		"vfx": "blink", "anim": "raise",
	},

	# ======================= ПАЛАДИН =======================
	"crusader_strike": {
		"name": "Удар воина Света", "school": "physical", "icon": "УВ",
		"desc": "Мощный удар оружием.",
		"target": "enemy", "delivery": "instant", "melee": true,
		"cast": 0.0, "cd": 5.0, "mana": 14.0, "range": 4.5,
		"effects": [{"type": "damage", "min": 46.0, "max": 54.0}],
		"vfx": "hit_holy", "anim": "melee",
	},
	"judgement": {
		"name": "Правосудие", "school": "holy", "icon": "Пр",
		"desc": "Обрушивает на врага кару Света с расстояния.",
		"target": "enemy", "delivery": "instant",
		"cast": 0.0, "cd": 8.0, "mana": 18.0, "range": 22.0,
		"effects": [{"type": "damage", "min": 38.0, "max": 45.0}],
		"vfx": "beam_holy", "anim": "shoot",
	},
	"consecration": {
		"name": "Освящение", "school": "holy", "icon": "Ос",
		"desc": "Освящает землю под ногами (радиус 7 м) на 8 сек. Враги на ней получают урон от Света.",
		"target": "self", "delivery": "zone", "radius": 7.0, "duration": 8.0, "tick": 1.0,
		"cast": 0.0, "cd": 12.0, "mana": 38.0, "range": 0.0,
		"enemy_fx": [{"type": "damage", "min": 9.0, "max": 11.0}],
		"vfx": "zone_consecration", "anim": "raise",
	},
	"holy_light": {
		"name": "Свет небес", "school": "holy", "icon": "СН",
		"desc": "Сильное исцеление союзника.",
		"target": "ally", "delivery": "instant",
		"cast": 2.0, "cd": 0.0, "mana": 34.0, "range": 35.0,
		"effects": [{"type": "heal", "min": 95.0, "max": 110.0}],
		"vfx": "heal_burst", "anim": "cast",
	},
	"hammer_of_justice": {
		"name": "Молот правосудия", "school": "holy", "icon": "МП",
		"desc": "Оглушает врага на 3 сек.",
		"target": "enemy", "delivery": "projectile", "speed": 30.0,
		"cast": 0.0, "cd": 25.0, "mana": 15.0, "range": 14.0,
		"effects": [{"type": "damage", "min": 10.0, "max": 12.0}, {"type": "stun", "dur": 3.0}],
		"vfx": "bolt_holy", "anim": "shoot",
	},
	"divine_shield": {
		"name": "Божественный щит", "school": "holy", "icon": "БЩ",
		"desc": "Неуязвимость на 8 сек.",
		"target": "self", "delivery": "instant",
		"cast": 0.0, "cd": 90.0, "mana": 20.0, "range": 0.0,
		"effects": [{"type": "immune", "dur": 8.0}],
		"vfx": "bubble", "anim": "raise",
	},
	"holy_wrath": {
		"name": "Гнев небес", "school": "holy", "icon": "ГН",
		"desc": "Волна Света в радиусе 9 м: урон и оглушение нежити на 1.5 сек.",
		"target": "self", "delivery": "self_aoe", "radius": 9.0,
		"cast": 0.0, "cd": 18.0, "mana": 35.0, "range": 0.0,
		"enemy_fx": [{"type": "damage", "min": 30.0, "max": 36.0}, {"type": "stun", "dur": 1.5}],
		"vfx": "nova_holy", "anim": "raise",
	},
	"lay_on_hands": {
		"name": "Возложение рук", "school": "holy", "icon": "ВР",
		"desc": "Полностью восстанавливает здоровье союзника.",
		"target": "ally", "delivery": "instant",
		"cast": 0.0, "cd": 150.0, "mana": 0.0, "range": 35.0,
		"effects": [{"type": "heal_pct", "pct": 1.0}],
		"vfx": "heal_burst", "anim": "raise",
	},

	# ======================= ЖРЕЦ =======================
	"smite": {
		"name": "Кара", "school": "holy", "icon": "Ка",
		"desc": "Поражает врага святым огнём с небес.",
		"target": "enemy", "delivery": "instant",
		"cast": 1.8, "cd": 0.0, "mana": 18.0, "range": 30.0,
		"effects": [{"type": "damage", "min": 30.0, "max": 36.0}],
		"vfx": "beam_holy", "anim": "cast",
	},
	"flash_heal": {
		"name": "Быстрое исцеление", "school": "holy", "icon": "БИ",
		"desc": "Быстро исцеляет союзника.",
		"target": "ally", "delivery": "instant",
		"cast": 1.5, "cd": 0.0, "mana": 26.0, "range": 36.0,
		"effects": [{"type": "heal", "min": 68.0, "max": 80.0}],
		"vfx": "heal_burst", "anim": "cast",
	},
	"renew": {
		"name": "Обновление", "school": "holy", "icon": "Об",
		"desc": "Исцеляет союзника каждые 3 сек. в течение 12 сек.",
		"target": "ally", "delivery": "instant",
		"cast": 0.0, "cd": 0.0, "mana": 20.0, "range": 36.0,
		"effects": [{"type": "hot", "total": 96.0, "dur": 12.0, "tick": 3.0, "key": "renew"}],
		"vfx": "heal_small", "anim": "shoot",
	},
	"pw_shield": {
		"name": "Слово силы: Щит", "school": "holy", "icon": "СЩ",
		"desc": "Окутывает союзника щитом, поглощающим урон (15 сек.).",
		"target": "ally", "delivery": "instant",
		"cast": 0.0, "cd": 4.0, "mana": 28.0, "range": 36.0,
		"effects": [{"type": "absorb", "amount": 85.0, "dur": 15.0}],
		"vfx": "shield", "anim": "shoot",
	},
	"circle_of_healing": {
		"name": "Круг исцеления", "school": "holy", "icon": "КИ",
		"desc": "Исцеляет до 5 союзников в радиусе 12 м от цели.",
		"target": "ally", "delivery": "ally_aoe", "radius": 12.0, "max_targets": 5,
		"cast": 0.0, "cd": 8.0, "mana": 40.0, "range": 36.0,
		"effects": [{"type": "heal", "min": 44.0, "max": 52.0}],
		"vfx": "heal_circle", "anim": "raise",
	},
	"light_barrier": {
		"name": "Барьер Света", "school": "holy", "icon": "БС",
		"desc": "Купол Света (радиус 7 м) на 10 сек.: союзники внутри получают на 40% меньше урона, враги замедлены и обжигаются.",
		"target": "ground", "delivery": "zone", "radius": 7.0, "duration": 10.0, "tick": 1.0, "ally_dr": 0.4,
		"cast": 0.0, "cd": 45.0, "mana": 60.0, "range": 30.0,
		"enemy_fx": [{"type": "damage", "min": 5.0, "max": 7.0}, {"type": "slow", "pct": 0.5, "dur": 1.5}],
		"vfx": "zone_barrier", "anim": "raise",
	},
	"holy_fire": {
		"name": "Священный огонь", "school": "holy", "icon": "СвО",
		"desc": "Сгусток священного огня: урон и горение в течение 6 сек.",
		"target": "enemy", "delivery": "projectile", "speed": 24.0,
		"cast": 2.0, "cd": 8.0, "mana": 28.0, "range": 30.0,
		"effects": [{"type": "damage", "min": 40.0, "max": 48.0}, {"type": "dot", "total": 24.0, "dur": 6.0, "tick": 2.0, "key": "holy_fire"}],
		"vfx": "bolt_holy", "anim": "cast",
	},
	"holy_nova": {
		"name": "Кольцо Света", "school": "holy", "icon": "КС",
		"desc": "Вспышка Света вокруг жреца (10 м): урон врагам и исцеление союзников.",
		"target": "self", "delivery": "self_aoe", "radius": 10.0,
		"cast": 0.0, "cd": 6.0, "mana": 42.0, "range": 0.0,
		"enemy_fx": [{"type": "damage", "min": 18.0, "max": 22.0}],
		"ally_fx": [{"type": "heal", "min": 24.0, "max": 28.0}],
		"vfx": "nova_holy", "anim": "raise",
	},

	"avenging_wrath": {
		"name": "Гнев карателя", "school": "holy", "icon": "ГК",
		"desc": "За спиной паладина раскрываются крылья Света: +25% к урону и лечению на 20 сек.",
		"target": "self", "delivery": "instant",
		"cast": 0.0, "cd": 120.0, "mana": 25.0, "range": 0.0,
		"effects": [{"type": "buff", "key": "avenging_wrath", "dur": 20.0, "mods": {"dmg": 0.25, "heal": 0.25}}],
		"vfx": "aura_holy", "anim": "raise",
	},
	"divine_guardian": {
		"name": "Божественный защитник", "school": "holy", "icon": "БЗ",
		"desc": "Все союзники в радиусе 30 м получают на 20% меньше урона в течение 8 сек.",
		"target": "self", "delivery": "party", "radius": 30.0,
		"cast": 0.0, "cd": 90.0, "mana": 30.0, "range": 0.0,
		"effects": [{"type": "buff", "key": "divine_guardian", "dur": 8.0, "mods": {"dmg_taken": -0.2}}],
		"vfx": "aura_holy", "anim": "raise",
	},
	"blessing_of_kings": {
		"name": "Благословение королей", "school": "holy", "icon": "БК",
		"desc": "Союзник получает +10% к здоровью, мане, урону и лечению на 10 минут.",
		"target": "ally", "delivery": "instant",
		"cast": 0.0, "cd": 0.0, "mana": 30.0, "range": 36.0,
		"effects": [{"type": "buff", "key": "kings", "dur": 600.0, "mods": {"hp_pct": 0.1, "mana_pct": 0.1, "dmg": 0.1, "heal": 0.1}}],
		"vfx": "heal_small", "anim": "shoot",
	},
	"pw_fortitude": {
		"name": "Слово силы: Стойкость", "school": "holy", "icon": "СС",
		"desc": "Союзник получает +15% к здоровью на 10 минут.",
		"target": "ally", "delivery": "instant",
		"cast": 0.0, "cd": 0.0, "mana": 30.0, "range": 36.0,
		"effects": [{"type": "buff", "key": "fortitude", "dur": 600.0, "mods": {"hp_pct": 0.15}}],
		"vfx": "heal_small", "anim": "shoot",
	},
	"divine_spirit": {
		"name": "Божественный дух", "school": "holy", "icon": "БД",
		"desc": "Союзник восполняет ману на 60% быстрее, запас маны +10% на 10 минут.",
		"target": "ally", "delivery": "instant",
		"cast": 0.0, "cd": 0.0, "mana": 30.0, "range": 36.0,
		"effects": [{"type": "buff", "key": "divine_spirit", "dur": 600.0, "mods": {"regen": 0.6, "mana_pct": 0.1}}],
		"vfx": "heal_small", "anim": "shoot",
	},
	"prayer_of_healing": {
		"name": "Молитва исцеления", "school": "holy", "icon": "МИ",
		"desc": "Исцеляет всех союзников в радиусе 30 м от жреца.",
		"target": "self", "delivery": "party", "radius": 30.0,
		"cast": 2.5, "cd": 0.0, "mana": 55.0, "range": 0.0,
		"effects": [{"type": "heal", "min": 55.0, "max": 65.0}],
		"vfx": "heal_circle", "anim": "cast",
	},

	# ======================= ВОИН (ярость вместо маны: поле mana = ярость) =======================
	"heroic_strike": {
		"name": "Удар героя", "school": "physical", "icon": "УГ",
		"desc": "Мощный удар оружием.",
		"target": "enemy", "delivery": "instant", "melee": true,
		"cast": 0.0, "cd": 3.0, "mana": 15.0, "range": 4.5,
		"effects": [{"type": "damage", "min": 40.0, "max": 48.0}],
		"vfx": "hit_phys", "anim": "melee",
	},
	"charge": {
		"name": "Рывок", "school": "physical", "icon": "Ры",
		"desc": "Рывок к врагу (6–25 м): оглушает на 1.5 сек. и даёт 20 ярости.",
		"target": "enemy", "delivery": "charge", "min_range": 6.0, "rage_gain": 20.0,
		"cast": 0.0, "cd": 15.0, "mana": 0.0, "range": 25.0,
		"effects": [{"type": "damage", "min": 10.0, "max": 12.0}, {"type": "stun", "dur": 1.5}],
		"vfx": "hit_phys", "anim": "melee",
	},
	"battle_shout": {
		"name": "Боевой крик", "school": "physical", "icon": "БК",
		"desc": "Вся группа в 30 м наносит на 10% больше урона 2 минуты.",
		"target": "self", "delivery": "party", "radius": 30.0,
		"cast": 0.0, "cd": 0.0, "mana": 10.0, "range": 0.0,
		"effects": [{"type": "buff", "key": "battle_shout", "dur": 120.0, "mods": {"dmg": 0.1}}],
		"vfx": "aura_war", "anim": "raise",
	},
	"thunder_clap": {
		"name": "Удар грома", "school": "physical", "icon": "УдГ",
		"desc": "Удар по земле: урон всем врагам в 8 м и замедление на 30%.",
		"target": "self", "delivery": "self_aoe", "radius": 8.0,
		"cast": 0.0, "cd": 6.0, "mana": 20.0, "range": 0.0,
		"enemy_fx": [{"type": "damage", "min": 28.0, "max": 34.0}, {"type": "slow", "pct": 0.3, "dur": 6.0}],
		"vfx": "nova_phys", "anim": "melee",
	},
	"taunt": {
		"name": "Провокация", "school": "physical", "icon": "Пр",
		"desc": "Враг бросается на воина и атакует только его 5 сек.",
		"target": "enemy", "delivery": "instant",
		"cast": 0.0, "cd": 8.0, "mana": 0.0, "range": 25.0,
		"effects": [{"type": "taunt", "dur": 5.0}],
		"vfx": "taunt", "anim": "raise",
	},
	"bloodthirst": {
		"name": "Жажда крови", "school": "physical", "icon": "ЖК",
		"desc": "Яростный удар: урон и лечение воина на 4% здоровья.",
		"target": "enemy", "delivery": "instant", "melee": true,
		"cast": 0.0, "cd": 5.0, "mana": 20.0, "range": 4.5,
		"effects": [{"type": "damage", "min": 55.0, "max": 65.0}, {"type": "heal_self_pct", "pct": 0.04}],
		"vfx": "hit_blood", "anim": "melee",
	},
	"whirlwind": {
		"name": "Вихрь", "school": "physical", "icon": "Ви",
		"desc": "Вращение с оружием: урон всем врагам в 7 м.",
		"target": "self", "delivery": "self_aoe", "radius": 7.0,
		"cast": 0.0, "cd": 8.0, "mana": 25.0, "range": 0.0,
		"enemy_fx": [{"type": "damage", "min": 45.0, "max": 52.0}],
		"vfx": "whirl", "anim": "spin",
	},
	"demoralizing_shout": {
		"name": "Деморализующий крик", "school": "physical", "icon": "ДК",
		"desc": "Враги в 10 м наносят на 20% меньше урона 15 сек.",
		"target": "self", "delivery": "self_aoe", "radius": 10.0,
		"cast": 0.0, "cd": 0.0, "mana": 10.0, "range": 0.0,
		"enemy_fx": [{"type": "buff", "key": "demoralized", "dur": 15.0, "mods": {"dmg": -0.2}}],
		"vfx": "aura_war", "anim": "raise",
	},
	"execute": {
		"name": "Казнь", "school": "physical", "icon": "Ка",
		"desc": "Добивающий удар огромной силы. Только по врагам с запасом здоровья ниже 25%.",
		"target": "enemy", "delivery": "instant", "melee": true, "execute": 0.25,
		"cast": 0.0, "cd": 0.0, "mana": 30.0, "range": 4.5,
		"effects": [{"type": "damage", "min": 120.0, "max": 140.0}],
		"vfx": "hit_blood", "anim": "melee",
	},
	"shield_wall": {
		"name": "Глухая оборона", "school": "physical", "icon": "ГО",
		"desc": "Получаемый урон снижен на 50% на 10 сек.",
		"target": "self", "delivery": "instant",
		"cast": 0.0, "cd": 120.0, "mana": 0.0, "range": 0.0,
		"effects": [{"type": "buff", "key": "shield_wall", "dur": 10.0, "mods": {"dmg_taken": -0.5}}],
		"vfx": "aura_war", "anim": "raise",
	},
	"recklessness": {
		"name": "Безрассудство", "school": "physical", "icon": "Бе",
		"desc": "Шанс критического удара +50% на 12 сек.",
		"target": "self", "delivery": "instant",
		"cast": 0.0, "cd": 180.0, "mana": 0.0, "range": 0.0,
		"effects": [{"type": "buff", "key": "recklessness", "dur": 12.0, "mods": {"crit": 0.5}}],
		"vfx": "aura_war", "anim": "raise",
	},
	"mortal_strike": {
		"name": "Смертельный удар", "school": "physical", "icon": "СУ", "talent": true,
		"desc": "Сокрушительный удар оружием.",
		"target": "enemy", "delivery": "instant", "melee": true,
		"cast": 0.0, "cd": 6.0, "mana": 25.0, "range": 4.5,
		"effects": [{"type": "damage", "min": 85.0, "max": 100.0}],
		"vfx": "hit_blood", "anim": "melee",
	},
	"rampage": {
		"name": "Буйство", "school": "physical", "icon": "Бу", "talent": true,
		"desc": "Урон +15% и скорость атак +15% на 20 сек.",
		"target": "self", "delivery": "instant",
		"cast": 0.0, "cd": 45.0, "mana": 0.0, "range": 0.0,
		"effects": [{"type": "buff", "key": "rampage", "dur": 20.0, "mods": {"dmg": 0.15, "haste": 0.15}}],
		"vfx": "aura_war", "anim": "raise",
	},
	"shockwave": {
		"name": "Ударная волна", "school": "physical", "icon": "УВ", "talent": true,
		"desc": "Волна от удара оглушает всех врагов в 9 м на 3 сек.",
		"target": "self", "delivery": "self_aoe", "radius": 9.0,
		"cast": 0.0, "cd": 20.0, "mana": 15.0, "range": 0.0,
		"enemy_fx": [{"type": "damage", "min": 40.0, "max": 48.0}, {"type": "stun", "dur": 3.0}],
		"vfx": "nova_phys", "anim": "melee",
	},
	"challenging_shout": {
		"name": "Вызывающий крик", "school": "physical", "icon": "ВК", "talent": true,
		"desc": "Все враги в 12 м бросаются на воина на 6 сек.",
		"target": "self", "delivery": "self_aoe", "radius": 12.0,
		"cast": 0.0, "cd": 20.0, "mana": 5.0, "range": 0.0,
		"enemy_fx": [{"type": "taunt", "dur": 6.0}],
		"vfx": "taunt_aoe", "anim": "raise",
	},
	# ======================= ЗАКЛИНАНИЯ ИЗ ТАЛАНТОВ =======================
	"arcane_power": {
		"name": "Чародейская мощь", "school": "arcane", "icon": "ЧМ", "talent": true,
		"desc": "На 15 сек. ваши заклинания наносят на 30% больше урона, но стоят на 20% больше маны.",
		"target": "self", "delivery": "instant",
		"cast": 0.0, "cd": 90.0, "mana": 0.0, "range": 0.0,
		"effects": [{"type": "buff", "key": "arcane_power", "dur": 15.0, "mods": {"dmg": 0.3, "mana": 0.2}}],
		"vfx": "aura_arcane", "anim": "raise",
	},
	"living_bomb": {
		"name": "Живая бомба", "school": "fire", "icon": "ЖБ", "talent": true,
		"desc": "Цель горит 12 сек., затем взрывается и ранит всех врагов в радиусе 6 м.",
		"target": "enemy", "delivery": "instant",
		"cast": 0.0, "cd": 0.0, "mana": 32.0, "range": 34.0,
		"effects": [{"type": "dot", "total": 48.0, "dur": 12.0, "tick": 3.0, "key": "living_bomb",
			"explode": {"radius": 6.0, "min": 55.0, "max": 65.0}}],
		"vfx": "hit_fire", "anim": "shoot",
	},
	"deep_freeze": {
		"name": "Глубокая заморозка", "school": "frost", "icon": "ГЗ", "talent": true,
		"desc": "Замораживает врага на 4 сек. По уже замороженным целям урон удваивается.",
		"target": "enemy", "delivery": "instant",
		"cast": 0.0, "cd": 30.0, "mana": 22.0, "range": 30.0,
		"effects": [{"type": "damage", "min": 55.0, "max": 65.0, "frozen_bonus": 1.0}, {"type": "freeze", "dur": 4.0}],
		"vfx": "ice_block", "anim": "shoot",
	},
	"beacon_of_light": {
		"name": "Частица Света", "school": "holy", "icon": "ЧС", "talent": true,
		"desc": "Отмечает союзника на 60 сек.: он получает 40% от лечения, которое вы дарите другим.",
		"target": "ally", "delivery": "instant",
		"cast": 0.0, "cd": 0.0, "mana": 35.0, "range": 40.0,
		"effects": [{"type": "beacon", "dur": 60.0}],
		"vfx": "heal_small", "anim": "raise",
	},
	"challenge": {
		"name": "Вызов Света", "school": "holy", "icon": "ВС", "talent": true,
		"desc": "Все враги в радиусе 12 м бросаются на паладина и атакуют только его 5 сек.",
		"target": "self", "delivery": "self_aoe", "radius": 12.0,
		"cast": 0.0, "cd": 12.0, "mana": 15.0, "range": 0.0,
		"enemy_fx": [{"type": "damage", "min": 8.0, "max": 10.0}, {"type": "taunt", "dur": 5.0}],
		"vfx": "nova_holy", "anim": "raise",
	},
	"avengers_shield": {
		"name": "Щит мстителя", "school": "holy", "icon": "ЩМ", "talent": true,
		"desc": "Бросок щита: урон, перескакивает ещё на 2 врагов, замедляет на 50% на 4 сек.",
		"target": "enemy", "delivery": "projectile", "speed": 34.0,
		"cast": 0.0, "cd": 15.0, "mana": 24.0, "range": 30.0,
		"effects": [{"type": "damage", "min": 45.0, "max": 55.0}, {"type": "slow", "pct": 0.5, "dur": 4.0},
			{"type": "chain", "count": 2, "radius": 10.0, "mult": 0.8}],
		"vfx": "bolt_holy", "anim": "shoot",
	},
	"divine_storm": {
		"name": "Божественная буря", "school": "holy", "icon": "ББ", "talent": true,
		"desc": "Вихрь Света: урон всем врагам в 7 м и лечение союзников рядом.",
		"target": "self", "delivery": "self_aoe", "radius": 7.0,
		"cast": 0.0, "cd": 10.0, "mana": 22.0, "range": 0.0,
		"enemy_fx": [{"type": "damage", "min": 40.0, "max": 48.0}],
		"ally_fx": [{"type": "heal", "min": 22.0, "max": 26.0}],
		"vfx": "nova_holy", "anim": "melee",
	},
	"pain_suppression": {
		"name": "Подавление боли", "school": "holy", "icon": "ПБ", "talent": true,
		"desc": "Союзник получает на 40% меньше урона в течение 8 сек.",
		"target": "ally", "delivery": "instant",
		"cast": 0.0, "cd": 60.0, "mana": 25.0, "range": 36.0,
		"effects": [{"type": "buff", "key": "pain_suppression", "dur": 8.0, "mods": {"dmg_taken": -0.4}}],
		"vfx": "aura_holy", "anim": "shoot",
	},
	"guardian_spirit": {
		"name": "Оберегающий дух", "school": "holy", "icon": "ОД", "talent": true,
		"desc": "10 сек.: лечение союзника +40%. Смертельный удар вместо гибели восстанавливает ему 50% здоровья.",
		"target": "ally", "delivery": "instant",
		"cast": 0.0, "cd": 90.0, "mana": 30.0, "range": 36.0,
		"effects": [{"type": "buff", "key": "guardian_spirit", "dur": 10.0, "mods": {"heal_taken": 0.4}}],
		"vfx": "aura_holy", "anim": "raise",
	},
	"halo": {
		"name": "Сияние небес", "school": "holy", "icon": "СН", "talent": true,
		"desc": "Вспышка Света в области 8 м: урон всем врагам и лечение всех союзников.",
		"target": "ground", "delivery": "ground_burst", "radius": 8.0,
		"cast": 0.0, "cd": 20.0, "mana": 50.0, "range": 32.0,
		"enemy_fx": [{"type": "damage", "min": 55.0, "max": 65.0}],
		"ally_fx": [{"type": "heal", "min": 45.0, "max": 55.0}],
		"vfx": "nova_holy", "anim": "raise",
	},
}

## Уровень, на котором открывается заклинание (заклинания талантов — по таланту).
const SPELL_LEVELS := {
	"frostbolt": 1, "fireball": 1, "arcane_missiles": 2, "frost_nova": 3, "arcane_explosion": 4, "blizzard": 5, "blink": 6, "ice_wall": 7, "arcane_barrage": 8, "fire_wall": 9, "flamestrike": 11,
	"crusader_strike": 1, "holy_light": 1, "judgement": 2, "consecration": 3, "blessing_of_kings": 4, "hammer_of_justice": 5, "avenging_wrath": 6, "holy_wrath": 7, "divine_guardian": 8, "divine_shield": 9, "lay_on_hands": 11,
	"smite": 1, "flash_heal": 1, "renew": 2, "pw_shield": 3, "pw_fortitude": 4, "holy_fire": 5, "divine_spirit": 6, "circle_of_healing": 7, "prayer_of_healing": 8, "light_barrier": 9, "holy_nova": 11,
	"heroic_strike": 1, "charge": 1, "battle_shout": 2, "thunder_clap": 3, "taunt": 4, "bloodthirst": 5, "whirlwind": 6, "demoralizing_shout": 7, "execute": 8, "shield_wall": 9, "recklessness": 11,
}

# Иконки-подсказки для эффектов на героях (для рамок группы).
const BUFF_INFO := {
	"renew": {"name": "Обновление", "color": Color(0.5, 1.0, 0.5), "icon": "renew"},
	"absorb": {"name": "Щит", "color": Color(1.0, 0.95, 0.6), "icon": "pw_shield"},
	"immune": {"name": "Неуязвимость", "color": Color(1.0, 0.85, 0.3), "icon": "divine_shield"},
	"barrier": {"name": "Барьер Света", "color": Color(1.0, 0.9, 0.5), "icon": "light_barrier"},
	"arcane_power": {"name": "Чародейская мощь", "color": Color(0.8, 0.45, 1.0), "icon": "arcane_power"},
	"pain_suppression": {"name": "Подавление боли", "color": Color(0.85, 0.85, 1.0), "icon": "pain_suppression"},
	"guardian_spirit": {"name": "Оберегающий дух", "color": Color(1.0, 0.95, 0.6), "icon": "guardian_spirit"},
	"beacon": {"name": "Частица Света", "color": Color(1.0, 0.9, 0.4), "icon": "beacon_of_light"},
	"inspiration": {"name": "Вдохновение", "color": Color(0.6, 1.0, 0.6), "icon": "flash_heal"},
	"clearcasting": {"name": "Ясность мысли", "color": Color(0.7, 0.6, 1.0), "icon": "arcane_barrage"},
	"avenging_wrath": {"name": "Гнев карателя", "color": Color(1.0, 0.85, 0.3), "icon": "avenging_wrath"},
	"divine_guardian": {"name": "Божественный защитник", "color": Color(1.0, 0.9, 0.5), "icon": "divine_guardian"},
	"kings": {"name": "Благословение королей", "color": Color(0.9, 0.6, 1.0), "icon": "blessing_of_kings"},
	"fortitude": {"name": "Слово силы: Стойкость", "color": Color(1.0, 1.0, 1.0), "icon": "pw_fortitude"},
	"divine_spirit": {"name": "Божественный дух", "color": Color(0.7, 0.9, 1.0), "icon": "divine_spirit"},
	"battle_shout": {"name": "Боевой крик", "color": Color(0.9, 0.6, 0.4), "icon": "battle_shout"},
	"shield_wall": {"name": "Глухая оборона", "color": Color(0.8, 0.8, 0.9), "icon": "shield_wall"},
	"recklessness": {"name": "Безрассудство", "color": Color(1.0, 0.4, 0.3), "icon": "recklessness"},
	"rampage": {"name": "Буйство", "color": Color(1.0, 0.4, 0.3), "icon": "rampage"},
	"elixir_power": {"name": "Эликсир мощи", "color": Color(1.0, 0.5, 0.3), "icon": "item:elixir_power"},
	"elixir_fort": {"name": "Эликсир стойкости", "color": Color(0.5, 1.0, 0.5), "icon": "item:elixir_fort"},
	"elixir_wisdom": {"name": "Эликсир мудрости", "color": Color(0.5, 0.7, 1.0), "icon": "item:elixir_wisdom"},
	"fingers_of_frost": {"name": "Ледяные пальцы", "color": Color(0.5, 0.85, 1.0), "icon": "frostbolt"},
	"arcane_surge": {"name": "Всплеск тайной магии", "color": Color(0.8, 0.5, 1.0), "icon": "arcane_barrage"},
	"art_of_war": {"name": "Искусство войны", "color": Color(1.0, 0.85, 0.4), "icon": "judgement"},
	"infusion_of_light": {"name": "Прилив Света", "color": Color(1.0, 0.95, 0.6), "icon": "holy_light"},
	"surge_of_light": {"name": "Волна Света", "color": Color(1.0, 0.95, 0.6), "icon": "flash_heal"},
	"borrowed_time": {"name": "Взятое взаймы время", "color": Color(0.85, 0.85, 1.0), "icon": "pw_shield"},
	"sudden_death": {"name": "Внезапная смерть", "color": Color(1.0, 0.3, 0.3), "icon": "execute"},
	"bloodsurge": {"name": "Прилив крови", "color": Color(1.0, 0.3, 0.3), "icon": "heroic_strike"},
	"revenge": {"name": "Возмездие", "color": Color(0.9, 0.8, 0.6), "icon": "thunder_clap"},
}

# ---------------------------------------------------------------- Проки (срабатывания)
## Бафф-прок делает следующее заклинание из списка мгновенным/бесплатным/усиленным.
const PROC_BUFFS := {
	"fingers_of_frost": {"spells": ["frostbolt", "deep_freeze"], "instant": true, "free": true, "amp": 0.5},
	"arcane_surge": {"spells": ["arcane_barrage", "arcane_missiles"], "free": true, "amp": 0.5, "reset_cd": true},
	"art_of_war": {"spells": ["holy_light", "judgement"], "instant": true, "free": true, "amp": 0.3},
	"infusion_of_light": {"spells": ["holy_light"], "instant": true, "amp": 0.2},
	"surge_of_light": {"spells": ["flash_heal", "smite"], "instant": true, "free": true},
	"borrowed_time": {"spells": ["flash_heal", "holy_fire", "smite", "prayer_of_healing"], "instant": true},
	"sudden_death": {"spells": ["execute"], "free": true, "allow_execute": true},
	"bloodsurge": {"spells": ["heroic_strike"], "free": true, "amp": 0.5, "reset_cd": true},
	"revenge": {"spells": ["thunder_clap"], "free": true, "amp": 0.5, "reset_cd": true},
}

## Заклинания, которые срабатывают сами (от проков талантов).
const AUTO_SPELLS := {
	"meteor": {"name": "Огненная глыба", "school": "fire", "radius": 6.0, "delay": 0.7, "vfx": "meteor",
		"enemy_fx": [{"type": "damage", "min": 55.0, "max": 70.0}, {"type": "dot", "total": 24.0, "dur": 4.0, "tick": 1.0, "key": "meteor_burn"}]},
	"holy_star": {"name": "Звезда Света", "school": "holy", "radius": 6.0, "delay": 0.7, "vfx": "holy_star",
		"enemy_fx": [{"type": "damage", "min": 40.0, "max": 50.0}], "ally_fx": [{"type": "heal", "min": 30.0, "max": 36.0}]},
	"divine_burst": {"name": "Вспышка Света", "school": "holy", "radius": 6.0, "delay": 0.0, "vfx": "nova_holy", "around_caster": true,
		"enemy_fx": [{"type": "damage", "min": 28.0, "max": 34.0}]},
}

# ---------------------------------------------------------------- Враги
const MOBS := {
	"minion": {"name": "Скелет-прислужник", "model": "Skeleton_Minion", "weapons": {"r": "Skeleton_Blade"},
		"hp": 90.0, "min": 7.0, "max": 10.0, "atk_speed": 1.6, "range": 2.4, "speed": 4.4,
		"xp": 14, "gold": 2, "scale": 1.0, "radius": 0.6, "armor": 0.0},
	"warrior": {"name": "Скелет-воин", "model": "Skeleton_Warrior", "weapons": {"r": "Skeleton_Axe", "l": "Skeleton_Shield_Large_A"},
		"hp": 220.0, "min": 13.0, "max": 17.0, "atk_speed": 2.0, "range": 2.6, "speed": 3.5,
		"xp": 30, "gold": 4, "scale": 1.05, "radius": 0.75, "armor": 0.15},
	"rogue": {"name": "Скелет-разбойник", "model": "Skeleton_Rogue", "weapons": {"r": "Skeleton_Blade", "l": "Skeleton_Blade"},
		"hp": 120.0, "min": 11.0, "max": 14.0, "atk_speed": 1.2, "range": 2.4, "speed": 5.6,
		"xp": 20, "gold": 3, "scale": 1.0, "radius": 0.6, "armor": 0.0},
	"mage": {"name": "Скелет-маг", "model": "Skeleton_Mage", "weapons": {"r": "Skeleton_Staff"},
		"hp": 100.0, "min": 15.0, "max": 19.0, "atk_speed": 2.4, "range": 18.0, "speed": 3.7,
		"xp": 26, "gold": 4, "scale": 1.0, "radius": 0.6, "armor": 0.0, "ranged": true},
	"boss_warlord": {"name": "Костяной полководец", "model": "Skeleton_Warrior", "weapons": {"r": "Skeleton_Axe", "l": "Skeleton_Shield_Large_B"},
		"hp": 2400.0, "min": 40.0, "max": 55.0, "atk_speed": 2.4, "range": 4.0, "speed": 3.3,
		"xp": 420, "gold": 60, "scale": 1.9, "radius": 1.4, "armor": 0.3, "cleave": 4.0, "boss": true},
	"boss_lich": {"name": "Лич-некромант", "model": "Skeleton_Mage", "weapons": {"r": "Skeleton_Staff"},
		"hp": 1900.0, "min": 45.0, "max": 60.0, "atk_speed": 2.6, "range": 22.0, "speed": 3.2,
		"xp": 480, "gold": 70, "scale": 1.8, "radius": 1.3, "armor": 0.1, "ranged": true, "splash": 5.0, "boss": true},
}

# ---------------------------------------------------------------- Формулы

func xp_to_next(level: int) -> int:
	return int(50.0 * pow(float(level), 1.45))

## Множитель силы эффектов (урон/лечение) героя от уровня. Вместе с атрибутами урон растёт заметно.
func level_power(level: int) -> float:
	return 1.0 + 0.05 * float(level - 1)

## Состав волны: список [тип_моба, полоса].
func wave_composition(wave: int, lanes: int, final_boss: bool = false) -> Array:
	var result: Array = []
	var per_lane := 3 + int(wave * 0.8)
	for lane in lanes:
		for i in per_lane:
			var t := "minion"
			var roll := float((i * 7 + wave * 3 + lane * 5) % 10) / 10.0
			if wave >= 3 and roll < 0.25:
				t = "warrior"
			elif wave >= 4 and roll < 0.45:
				t = "rogue"
			elif wave >= 5 and roll < 0.6:
				t = "mage"
			result.append([t, lane])
	if wave % 5 == 0 or final_boss:
		var boss := "boss_lich" if wave % 10 == 0 else "boss_warlord"
		result.append([boss, wave % lanes])
	return result

func mob_hp_mult(wave: int, players: int) -> float:
	return (1.0 + 0.17 * float(wave - 1)) * (1.0 + 0.4 * float(max(players, 1) - 1))

func mob_dmg_mult(wave: int) -> float:
	return 1.0 + 0.09 * float(wave - 1)

# ---------------------------------------------------------------- Таланты

const TalentData := preload("res://scripts/data/talent_data.gd")
var _talent_index: Dictionary = {}   # class -> tid -> {"t": талант, "tree": индекс ветки}

func spell_level(sid: String) -> int:
	return int(SPELL_LEVELS.get(sid, 1))

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
	if t.has("req"):
		var req := find_talent(class_id, t["req"])
		if int(ranks.get(t["req"], 0)) < int(req["t"]["max"]):
			return "Сначала изучите «%s»" % req["t"]["name"]
	return ""

## Сводит изученные таланты в модификаторы: {global, school, spell, flags}.
func compute_mods(class_id: String, ranks: Dictionary) -> Dictionary:
	var m := {"global": {}, "school": {}, "spell": {}, "flags": {}, "procs": []}
	for tid in ranks:
		var r := int(ranks[tid])
		var info := find_talent(class_id, tid)
		if r <= 0 or info.is_empty():
			continue
		var t: Dictionary = info["t"]
		for md in t.get("mods", []):
			var scope: String = md[0]
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
			pd["chance"] = float(pd["chance"]) * r
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

func hero_spells(class_id: String, ranks: Dictionary) -> Array:
	return CLASSES[class_id]["spells"] + talent_spells(class_id, ranks)

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
	if u.has_buff("clearcasting") and float(sp["mana"]) > 0.0 and u.resource != "rage":
		return 0.0
	var pr := active_proc(u, sid)
	if not pr.is_empty() and pr["data"].get("free", false):
		return 0.0
	return float(sp["mana"]) * maxf(0.0, 1.0 + u.mod("mana", sid, sp["school"]))

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

## Описание предмета по id: {id, name, kind (gear/consumable), slot, stats, level, price, q, icon, classes, use}
func item(id: String) -> Dictionary:
	if _items.is_empty():
		_build_items()
	return _items.get(id, {})

func all_items() -> Array:
	if _items.is_empty():
		_build_items()
	return _items.keys()

func _build_items() -> void:
	for tid in ItemData.TEMPLATES:
		var tp: Dictionary = ItemData.TEMPLATES[tid]
		for i in ItemData.TIERS.size():
			var tier: Dictionary = ItemData.TIERS[i]
			var st := {}
			for k in tp["stats"]:
				st[k] = float(tp["stats"][k]) * (i + 1)
			var id := "%s_%d" % [tid, i + 1]
			_items[id] = {"id": id, "name": "%s %s" % [tier["adj"][tp["g"]], tp["name"]], "kind": "gear", "slot": tp["slot"],
				"stats": st, "level": tier["level"], "price": int(tier["price"] * (0.6 if tp["slot"] in ["ring", "amulet", "boots", "helm"] else 1.0)),
				"q": tier["q"], "icon": tp["icon"], "classes": tp.get("classes", []), "tier": i + 1}
	for cid in ItemData.CONSUMABLES:
		var c: Dictionary = ItemData.CONSUMABLES[cid]
		_items[cid] = {"id": cid, "name": c["name"], "kind": "consumable", "level": c["level"], "price": c["price"],
			"q": c["q"], "icon": c["icon"], "use": c["use"], "desc": c.get("desc", "")}

func item_color(id: String) -> Color:
	return ItemData.QUALITY[clampi(int(item(id).get("q", 0)), 0, ItemData.QUALITY.size() - 1)]

## Текст подсказки предмета.
func item_tooltip(id: String, hero_class: String = "", hero_level: int = 99) -> String:
	var it := item(id)
	if it.is_empty():
		return ""
	var lines := [it["name"]]
	if it["kind"] == "gear":
		lines.append(ItemData.SLOTS[it["slot"]])
		for k in ["str", "agi", "sta", "int", "spi", "sp", "ap"]:
			if it["stats"].has(k):
				lines.append("+%d %s" % [int(it["stats"][k]), ItemData.STAT_NAMES[k]])
		if it["stats"].has("armor"):
			lines.append("+%.1f%% %s" % [it["stats"]["armor"] * 100.0, ItemData.STAT_NAMES["armor"]])
		if not it["classes"].is_empty():
			var names := []
			for c in it["classes"]:
				names.append(CLASSES[c]["name"])
			var ok: bool = hero_class == "" or it["classes"].has(hero_class)
			lines.append(("Классы: " if ok else "✗ Только: ") + ", ".join(names))
	else:
		var u: Dictionary = it["use"]
		if u.has("heal"):
			lines.append("Восстанавливает %d здоровья." % int(u["heal"]))
		if u.has("mana"):
			lines.append("Восстанавливает %d маны (воину — ярость)." % int(u["mana"]))
		if it["desc"] != "":
			lines.append(it["desc"])
		lines.append("Общее восстановление зелий: %d сек." % int(POTION_CD))
	lines.append(("Требуется уровень %d" if hero_level >= it["level"] else "✗ Требуется уровень %d") % it["level"])
	lines.append("Цена: %d золота" % it["price"])
	return "\n".join(lines)
