extends RefCounted
## Способности врагов (и будущих боссов). Мобы ссылаются на них по id в поле abilities.
## Решение о способности принимается в mob_manager._think (2–3 раза в секунду), а не в каждом тике.
##
## Поля:
##   name, cd — перезарядка, range — дальность выбора цели
##   target: enemy (герой) | enemy_point (точка под героем) | self | ally_hurt (раненый союзник) |
##           ally (союзник в бою) | corpse (труп рядом) | wall_or_enemy (стена льда или герой вплотную)
##   cond: hp_below (своё здоровье ниже доли), min_dist (цель не ближе), once (один раз за жизнь)
##   cast — время произнесения (0 — сразу); interrupt — можно ли сбить; school — школа (блокируется при сбитии)
##   telegraph: {shape: circle|cone|line, radius, angle (для конуса, градусы), width (для линии)} — показ
##     на земле на всё время произнесения; удар — в конце, по тем, кто остался внутри
##   delivery: target (по цели) | projectile | chain | area (в точке или вокруг себя) | cone | leap |
##             summon | self_explode | allies (на союзников в радиусе)
##   effects — те же эффекты, что у заклинаний героев, плюс общие mana_burn, knockback, fear,
##     silence, steal_gold, summon, devour
##   anim — анимация произнесения

const ABILITIES := {
	# ---------------- нежить
	"raise_dead": {"name": "Поднять мёртвых", "cd": 14.0, "range": 16.0, "target": "corpse", "cast": 2.5,
		"interrupt": true, "school": "shadow", "delivery": "summon", "summon": "minion", "count": 2, "anim": "Spellcast_Summon"},
	"devour": {"name": "Пожирание", "cd": 8.0, "range": 3.5, "target": "corpse", "cast": 1.5, "interrupt": true,
		"school": "physical", "delivery": "devour", "heal_pct": 0.35, "cond": {"hp_below": 0.9}, "anim": "Interact"},
	"wail": {"name": "Вой банши", "cd": 16.0, "range": 14.0, "target": "enemy", "cast": 1.6, "interrupt": true,
		"school": "shadow", "delivery": "target", "effects": [{"type": "fear", "dur": 2.5}], "anim": "Spellcast_Raise"},

	# ---------------- орки
	"enrage": {"name": "Боевое безумие", "cd": 999.0, "range": 0.0, "target": "self", "cast": 0.0, "interrupt": false,
		"school": "physical", "delivery": "target", "cond": {"hp_below": 0.4, "once": true},
		"effects": [{"type": "buff", "key": "enraged", "dur": 12.0, "mods": {"dmg": 0.4, "haste": 0.3}}], "anim": "Cheer"},
	"raider_charge": {"name": "Налёт", "cd": 10.0, "range": 18.0, "target": "enemy", "cast": 0.0, "interrupt": false,
		"school": "physical", "delivery": "leap", "cond": {"min_dist": 7.0},
		"effects": [{"type": "damage", "min": 12.0, "max": 16.0}, {"type": "slow", "pct": 0.4, "dur": 3.0}]},
	"chain_lightning": {"name": "Цепная молния", "cd": 9.0, "range": 18.0, "target": "enemy", "cast": 2.0, "interrupt": true,
		"school": "nature", "delivery": "chain", "jumps": 3, "jump_range": 9.0,
		"effects": [{"type": "damage", "min": 22.0, "max": 28.0}], "anim": "Spellcast_Shoot"},
	"bloodlust": {"name": "Жажда крови", "cd": 20.0, "range": 12.0, "target": "ally", "cast": 1.5, "interrupt": true,
		"school": "nature", "delivery": "allies", "radius": 10.0,
		"effects": [{"type": "buff", "key": "bloodlust", "dur": 10.0, "mods": {"dmg": 0.25, "haste": 0.25}}], "anim": "Spellcast_Raise"},
	"war_drums": {"name": "Боевые барабаны", "cd": 4.0, "range": 0.0, "target": "self", "cast": 0.0, "interrupt": false,
		"school": "physical", "delivery": "allies", "radius": 12.0, "silent": true,
		"effects": [{"type": "buff", "key": "war_drums", "dur": 5.0, "mods": {"speed": 0.25}}]},

	# ---------------- демоны
	"seduce": {"name": "Соблазн", "cd": 15.0, "range": 12.0, "target": "enemy", "cast": 2.0, "interrupt": true,
		"school": "shadow", "delivery": "target", "effects": [{"type": "stun", "dur": 3.0, "key": "charmed"}], "anim": "Spellcast_Shoot"},
	"infernal_drop": {"name": "Падение инфернала", "cd": 18.0, "range": 28.0, "target": "enemy_point", "cast": 1.6, "interrupt": false,
		"school": "fire", "delivery": "leap", "telegraph": {"shape": "circle", "radius": 4.0},
		"effects": [{"type": "damage", "min": 30.0, "max": 38.0}, {"type": "stun", "dur": 1.5}], "anim": "Spellcast_Raise"},

	# ---------------- гоблины и огры
	"goblin_explode": {"name": "Подрыв", "cd": 1.0, "range": 2.6, "target": "wall_or_enemy", "cast": 1.0, "interrupt": true,
		"school": "fire", "delivery": "self_explode", "telegraph": {"shape": "circle", "radius": 4.0},
		"effects": [{"type": "damage", "min": 40.0, "max": 50.0}], "wall_damage": 220.0, "anim": "Throw"},
	"goblin_mine": {"name": "Мина", "cd": 12.0, "range": 16.0, "target": "enemy_point", "cast": 2.2, "interrupt": true,
		"school": "fire", "delivery": "area", "telegraph": {"shape": "circle", "radius": 3.2},
		"effects": [{"type": "damage", "min": 28.0, "max": 34.0}, {"type": "knockback", "dist": 5.0}], "anim": "Interact"},
	"ogre_smash": {"name": "Сокрушение", "cd": 10.0, "range": 5.5, "target": "enemy", "cast": 1.3, "interrupt": false,
		"school": "physical", "delivery": "cone", "telegraph": {"shape": "cone", "radius": 6.5, "angle": 100.0},
		"effects": [{"type": "damage", "min": 30.0, "max": 38.0}, {"type": "knockback", "dist": 6.0}], "anim": "2H_Melee_Attack_Spinning"},
	"ogre_shield": {"name": "Магический щит", "cd": 12.0, "range": 16.0, "target": "ally_hurt", "cast": 1.5, "interrupt": true,
		"school": "arcane", "delivery": "target", "effects": [{"type": "absorb", "amount": 140.0, "dur": 10.0}], "anim": "Spellcast_Shoot"},
	"ogre_haste": {"name": "Ускорение", "cd": 15.0, "range": 14.0, "target": "ally", "cast": 1.5, "interrupt": true,
		"school": "arcane", "delivery": "target",
		"effects": [{"type": "buff", "key": "ogre_haste", "dur": 8.0, "mods": {"speed": 0.4, "haste": 0.2}}], "anim": "Spellcast_Raise"},

	# ---------------- элитные аффиксы (общие для всех фракций)
	"affix_summon": {"name": "Призыв подмоги", "cd": 12.0, "range": 0.0, "target": "self", "cast": 1.5, "interrupt": true,
		"school": "shadow", "delivery": "summon", "summon": "", "count": 2, "anim": "Spellcast_Summon"},

	"affix_inspire": {"name": "Вдохновение", "cd": 3.0, "range": 0.0, "target": "self", "cast": 0.0, "interrupt": false,
		"school": "physical", "delivery": "allies", "radius": 10.0, "silent": true,
		"effects": [{"type": "buff", "key": "inspired", "dur": 4.0, "mods": {"dmg": 0.2, "speed": 0.15}}]},

	# ---------------- проверка (--casttest)
	"test_cast": {"name": "Учебная огненная глыба", "cd": 0.5, "range": 40.0, "target": "enemy", "cast": 3.0, "interrupt": true,
		"school": "fire", "delivery": "target", "effects": [], "anim": "Spellcasting"},
}
