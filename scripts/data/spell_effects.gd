extends RefCounted
## Общие данные заклинаний: уровни открытия, баффы и их иконки, баффы-проки, автозаклинания от проков.

## Уровень, на котором открывается заклинание (заклинания талантов — по таланту).
const SPELL_LEVELS := {
	"counterspell": 3, "pummel": 3, "rebuke": 3, "silence": 3,    # прерывания — по одному на класс
	"frostbolt": 1, "fireball": 1, "arcane_missiles": 2, "frost_nova": 3, "arcane_explosion": 4, "blizzard": 5, "blink": 6, "ice_wall": 7, "arcane_barrage": 8, "fire_wall": 9, "flamestrike": 11,
	"crusader_strike": 1, "holy_light": 1, "judgement": 2, "consecration": 3, "blessing_of_kings": 4, "hammer_of_justice": 5, "avenging_wrath": 6, "holy_wrath": 7, "divine_guardian": 8, "divine_shield": 9, "lay_on_hands": 11,
	"smite": 1, "flash_heal": 1, "renew": 2, "pw_shield": 3, "pw_fortitude": 4, "holy_fire": 5, "divine_spirit": 6, "circle_of_healing": 7, "prayer_of_healing": 8, "light_barrier": 9, "holy_nova": 11,
	"heroic_strike": 1, "charge": 1, "battle_shout": 2, "thunder_clap": 3, "taunt": 4, "bloodthirst": 5, "whirlwind": 6, "demoralizing_shout": 7, "execute": 8, "shield_wall": 9, "recklessness": 11,
}

# Иконки-подсказки для эффектов на героях (для рамок группы).
const BUFF_INFO := {
	"renew": {"name": "Обновление", "color": Color(0.5, 1.0, 0.5), "icon": "renew"},
	"absorb": {"name": "Щит", "color": Color(1.0, 0.95, 0.6), "icon": "pw_shield"},
	"weakened_soul": {"name": "Ослабленная душа", "color": Color(0.6, 0.6, 0.78), "icon": "pw_shield", "debuff": true},
	# эффекты на врагах (рамка цели и ряд над головой); desc — для подсказки
	"ignite": {"name": "Горение", "color": Color(1.0, 0.5, 0.15), "icon": "fireball", "debuff": true, "desc": "Огненный шар: урон огнём со временем."},
	"burn": {"name": "Пламя стены", "color": Color(1.0, 0.5, 0.15), "icon": "fire_wall", "debuff": true, "desc": "Стена огня: урон огнём со временем."},
	"meteor_burn": {"name": "Огненная глыба", "color": Color(1.0, 0.45, 0.1), "icon": "flamestrike", "debuff": true, "desc": "Горит после удара глыбы."},
	"ignite_talent": {"name": "Возгорание", "color": Color(1.0, 0.4, 0.1), "icon": "fireball", "debuff": true, "desc": "После критического удара огнём цель догорает."},
	"holy_fire": {"name": "Священный огонь", "color": Color(1.0, 0.85, 0.4), "icon": "holy_fire", "debuff": true, "desc": "Урон Светом со временем."},
	"living_bomb": {"name": "Живая бомба", "color": Color(1.0, 0.45, 0.1), "icon": "living_bomb", "debuff": true, "desc": "Горит, а в конце взрывается и задевает врагов рядом."},
	"deep_wounds": {"name": "Глубокие раны", "color": Color(0.85, 0.1, 0.08), "icon": "mortal_strike", "debuff": true, "desc": "Кровотечение после критического удара."},
	"slowed": {"name": "Замедление", "color": Color(0.45, 0.8, 1.0), "icon": "frostbolt", "debuff": true, "desc": "Двигается медленнее."},
	"chill": {"name": "Холод", "color": Color(0.45, 0.8, 1.0), "icon": "blizzard", "debuff": true, "desc": "Копится от ледяных заклинаний: на третьем заряде цель замерзает."},
	"frozen": {"name": "Заморожен", "color": Color(0.6, 0.9, 1.0), "icon": "deep_freeze", "debuff": true, "desc": "Не двигается и не атакует."},
	"stunned": {"name": "Оглушение", "color": Color(1.0, 0.9, 0.5), "icon": "hammer_of_justice", "debuff": true, "desc": "Не двигается и не атакует."},
	"rooted": {"name": "Обездвиживание", "color": Color(0.45, 0.8, 1.0), "icon": "frost_nova", "debuff": true, "desc": "Не может сойти с места."},
	"taunted": {"name": "Провокация", "color": Color(1.0, 0.35, 0.25), "icon": "taunt", "debuff": true, "desc": "Атакует того, кто его спровоцировал."},
	"demoralized": {"name": "Деморализация", "color": Color(0.8, 0.5, 0.4), "icon": "demoralizing_shout", "debuff": true, "desc": "Наносит на 20% меньше урона."},
	"feared": {"name": "Страх", "color": Color(0.6, 0.3, 0.75), "icon": "taunt", "debuff": true, "desc": "Бежит прочь и не слушается управления."},
	"silenced": {"name": "Немота", "color": Color(0.6, 0.6, 0.9), "icon": "arcane_barrage", "debuff": true, "desc": "Не может произносить заклинания."},
	"charmed": {"name": "Очарован", "color": Color(0.95, 0.4, 0.8), "icon": "divine_spirit", "debuff": true, "desc": "Суккуба очаровала: не может двигаться и действовать."},
	"enraged": {"name": "Боевое безумие", "color": Color(1.0, 0.3, 0.2), "icon": "recklessness", "desc": "Наносит на 40% больше урона и бьёт быстрее."},
	"bloodlust": {"name": "Жажда крови", "color": Color(1.0, 0.35, 0.2), "icon": "bloodthirst", "desc": "Урон и скорость атаки +25%."},
	"war_drums": {"name": "Боевые барабаны", "color": Color(0.9, 0.6, 0.3), "icon": "battle_shout", "desc": "Двигается на 25% быстрее."},
	"ogre_haste": {"name": "Ускорение", "color": Color(0.7, 0.5, 1.0), "icon": "blink", "desc": "Двигается и бьёт быстрее."},
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
