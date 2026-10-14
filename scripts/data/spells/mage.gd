extends RefCounted
## Заклинания: Маг. Формат полей — в начале scripts/data/game_data.gd (раздел «Заклинания»).
## Здесь же заклинания, которые класс получает из талантов.

const SPELLS := {
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
		"cast": 0.0, "cd": 15.0, "mana": 48.0, "range": 36.0,
		"enemy_fx": [{"type": "damage", "min": 13.0, "max": 16.0}, {"type": "slow", "pct": 0.5, "dur": 1.5}, {"type": "chill", "stacks": 3, "dur": 2.5}],
		"vfx": "zone_blizzard", "anim": "raise",
	},
	"ice_wall": {
		"name": "Ледяная стена", "school": "frost", "icon": "ЛСт",
		"desc": "Нарисуйте мышью стену льда (до 14 м) на 18 сек.: зажмите ЛКМ и протяните. Враги не пройдут, пока не сломают её — по трещинам видно, сколько она ещё продержится.",
		"target": "wall", "delivery": "wall", "length": 14.0, "duration": 18.0, "wall_hp": 340.0,
		"cast": 0.0, "cd": 30.0, "mana": 40.0, "range": 30.0,
		"vfx": "wall_ice", "anim": "raise",
	},
	"fire_wall": {
		"name": "Стена огня", "school": "fire", "icon": "СО",
		"desc": "Нарисуйте мышью полосу пламени (до 16 м) на 10 сек.: зажмите ЛКМ и протяните. Сжигает всех, кто проходит сквозь неё.",
		"target": "wall", "delivery": "zone_line", "length": 16.0, "width": 2.2, "duration": 10.0, "tick": 0.5,
		"cast": 0.0, "cd": 20.0, "mana": 44.0, "range": 30.0,
		"enemy_fx": [{"type": "damage", "min": 9.0, "max": 11.0}, {"type": "dot", "total": 12.0, "dur": 4.0, "tick": 1.0, "key": "burn"}],
		"vfx": "wall_fire", "anim": "raise",
	},
	"frost_nova": {
		"name": "Кольцо льда", "school": "frost", "icon": "КЛ",
		"desc": "Замораживает всех врагов в радиусе 9 м на 4 сек.",
		"target": "self", "delivery": "self_aoe", "radius": 9.0,
		"cast": 0.0, "cd": 25.0, "mana": 35.0, "range": 0.0,
		"enemy_fx": [{"type": "damage", "min": 16.0, "max": 20.0}, {"type": "freeze", "dur": 4.0}],
		"vfx": "nova_frost", "anim": "raise",
	},
	"flamestrike": {
		"name": "Огненный столб", "school": "fire", "icon": "ОС",
		"desc": "Обрушивает столб огня (радиус 6 м). Земля горит ещё 6 сек.",
		"target": "ground", "delivery": "zone", "radius": 6.0, "duration": 6.0, "tick": 1.0,
		"cast": 2.0, "cd": 14.0, "mana": 48.0, "range": 36.0,
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
		"cast": 0.0, "cd": 0.0, "mana": 34.0, "range": 0.0,
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

	# --- из талантов ---
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
		"cast": 0.0, "cd": 6.0, "mana": 32.0, "range": 34.0,
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
	# --- прерывание (сессия 02)
	"counterspell": {
		"name": "Антимагия", "school": "arcane", "icon": "АМ", "no_gcd": true,
		"desc": "Сбивает заклинание врага. 4 сек. он не может произносить заклинания этой школы. Не тратит общую перезарядку.",
		"target": "enemy", "delivery": "instant",
		"cast": 0.0, "cd": 20.0, "mana": 12.0, "range": 30.0,
		"effects": [{"type": "interrupt", "lock": 4.0}],
		"vfx": "hit_arcane", "anim": "shoot",
	},
}
