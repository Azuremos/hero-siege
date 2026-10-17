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
##
## Для боссов (движок — mob_manager.gd, раздел «боссы»):
##   target: enemy_random — случайный герой; cond.enemy_near — герой ближе N м
##   telegraph.shape: line (radius — длина, width — ширина) | ring (radius — внешний, inner — внутренний)
##   delivery: lines (веер полос: count, spread°) | charge (рывок по полосе) | barrage (круги под героями: count, spread) |
##     shockwave (волны от босса: waves {count, interval, speed, width, max} — перепрыгнуть) | tomb (гробница на героя) |
##     mark (метка: взрыв через delay по союзникам в radius) | share (урон делится на всех в круге) |
##     pack (стая бросается на самого раненого) | everyone (все герои в radius) | mines (мины: count, radius, mine {...})
##   ring — призыв по кругу вокруг босса; max_alive — не больше стольких призванных живыми
##   hazard — горящая земля после удара {r, dur, dps}; min_players — только при стольких героях и больше
##   solo — смягчение в одиночке: {mult — урон и лечение, count — число призванных}
##   hard — без рывка не уйти: у босса не чаще раза в BossData.HARD_GAP сек.

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

	# ======================= боссы (фазы — boss_data.gd) =======================
	# ---------------- Лич-некромант
	"lich_raise": {"name": "Поднять мёртвых", "cd": 16.0, "range": 0.0, "target": "self", "cast": 3.75, "interrupt": true,
		"school": "shadow", "delivery": "summon", "summon": "minion", "count": 3, "solo": {"count": 2}, "anim": "Spellcast_Summon"},
	"lich_tomb": {"name": "Ледяная гробница", "cd": 22.0, "range": 30.0, "target": "enemy_random", "cast": 1.5, "interrupt": false,
		"school": "frost", "delivery": "tomb", "tomb": "ice_tomb", "dur": 12.0, "dot_pct": 0.02, "anim": "Spellcast_Shoot"},
	"lich_cold_ring": {"name": "Кольцо холода", "cd": 15.0, "range": 0.0, "target": "self", "cast": 2.0, "interrupt": false,
		"school": "frost", "delivery": "area", "telegraph": {"shape": "ring", "radius": 14.0, "inner": 4.5},
		"effects": [{"type": "damage", "min": 45.0, "max": 55.0}, {"type": "slow", "pct": 0.5, "dur": 4.0}], "anim": "Spellcast_Raise"},
	"lich_shadow_waves": {"name": "Теневые волны", "cd": 7.0, "range": 30.0, "target": "enemy", "cast": 1.6, "interrupt": false,
		"school": "shadow", "delivery": "lines", "count": 3, "spread": 30.0, "telegraph": {"shape": "line", "radius": 26.0, "width": 3.0},
		"effects": [{"type": "damage", "min": 50.0, "max": 60.0}], "anim": "Spellcast_Shoot"},
	# ---------------- Костяной полководец
	"warlord_charge": {"name": "Рывок полководца", "cd": 12.0, "range": 18.0, "target": "enemy", "cast": 1.5, "interrupt": false,
		"school": "physical", "delivery": "charge", "cond": {"min_dist": 5.0}, "telegraph": {"shape": "line", "radius": 18.0, "width": 3.0},
		"effects": [{"type": "damage", "min": 45.0, "max": 55.0}, {"type": "knockback", "dist": 4.0}], "anim": "2H_Melee_Attack_Chop"},
	"warlord_whirl": {"name": "Вихрь клинков", "cd": 11.0, "range": 0.0, "target": "self", "cast": 1.6, "interrupt": false,
		"school": "physical", "delivery": "area", "cond": {"enemy_near": 7.0}, "telegraph": {"shape": "circle", "radius": 6.5},
		"effects": [{"type": "damage", "min": 40.0, "max": 50.0}], "anim": "2H_Melee_Attack_Spinning"},
	"warlord_shields": {"name": "Призыв щитоносцев", "cd": 20.0, "range": 0.0, "target": "self", "cast": 3.75, "interrupt": true,
		"school": "shadow", "delivery": "summon", "summon": "warrior", "count": 2, "solo": {"count": 1}, "anim": "Spellcast_Summon"},
	# ---------------- Вождь орды
	"chief_smash": {"name": "Тяжёлый удар", "cd": 9.0, "range": 6.0, "target": "enemy", "cast": 1.4, "interrupt": false,
		"school": "physical", "delivery": "cone", "telegraph": {"shape": "cone", "radius": 7.5, "angle": 100.0},
		"effects": [{"type": "damage", "min": 55.0, "max": 65.0}, {"type": "knockback", "dist": 4.0}], "anim": "2H_Melee_Attack_Spinning"},
	"chief_roar": {"name": "Боевой рёв", "cd": 18.0, "range": 0.0, "target": "self", "cast": 1.8, "interrupt": false,
		"school": "physical", "delivery": "area", "cond": {"enemy_near": 9.0}, "telegraph": {"shape": "circle", "radius": 9.0},
		"effects": [{"type": "damage", "min": 15.0, "max": 20.0}, {"type": "fear", "dur": 3.0}], "anim": "Cheer"},
	"chief_call": {"name": "Зов орды", "cd": 20.0, "range": 0.0, "target": "self", "cast": 3.75, "interrupt": true,
		"school": "nature", "delivery": "summon", "summon": "grunt", "count": 3, "solo": {"count": 2}, "anim": "Spellcast_Raise"},
	"chief_bloodlust": {"name": "Жажда крови", "cd": 20.0, "range": 0.0, "target": "self", "cast": 0.0, "interrupt": false,
		"school": "nature", "delivery": "allies", "radius": 16.0,
		"effects": [{"type": "buff", "key": "bloodlust", "dur": 12.0, "mods": {"dmg": 0.3, "haste": 0.3}}]},
	"chief_axes": {"name": "Веер топоров", "cd": 10.0, "range": 24.0, "target": "enemy", "cast": 1.5, "interrupt": false,
		"school": "physical", "delivery": "lines", "count": 5, "spread": 22.0, "telegraph": {"shape": "line", "radius": 22.0, "width": 2.2},
		"effects": [{"type": "damage", "min": 40.0, "max": 50.0}], "anim": "Throw"},
	"chief_quake": {"name": "Землетрясение", "cd": 16.0, "range": 0.0, "target": "self", "cast": 1.5, "interrupt": false,
		"school": "physical", "delivery": "shockwave", "cond": {"enemy_near": 26.0}, "telegraph": {"shape": "circle", "radius": 3.0},
		"waves": {"count": 3, "interval": 1.4, "speed": 8.0, "width": 1.4, "max": 26.0},
		"effects": [{"type": "damage", "min": 35.0, "max": 45.0}, {"type": "slow", "pct": 0.4, "dur": 3.0}], "anim": "2H_Melee_Attack_Chop"},
	# ---------------- Вожак волчьей стаи
	"pack_hunt": {"name": "Травля", "cd": 15.0, "range": 0.0, "target": "self", "cast": 0.0, "interrupt": false,
		"school": "physical", "delivery": "pack", "pack": "pack_wolf", "radius": 30.0, "dur": 6.0, "anim": "Cheer"},
	"pack_howl": {"name": "Вой стаи", "cd": 20.0, "range": 0.0, "target": "self", "cast": 3.75, "interrupt": true,
		"school": "nature", "delivery": "summon", "summon": "pack_wolf", "count": 3, "solo": {"count": 2}, "anim": "Spellcast_Raise"},
	"pack_leap": {"name": "Прыжок вожака", "cd": 12.0, "range": 20.0, "target": "enemy_point", "cast": 1.4, "interrupt": false,
		"school": "physical", "delivery": "leap", "cond": {"min_dist": 6.0}, "telegraph": {"shape": "circle", "radius": 4.0},
		"effects": [{"type": "damage", "min": 35.0, "max": 45.0}]},
	# ---------------- Владыка Скверны
	"fel_rain": {"name": "Огненный дождь", "cd": 9.0, "range": 40.0, "target": "enemy", "cast": 1.8, "interrupt": false,
		"school": "fire", "delivery": "barrage", "count": 6, "spread": 8.0, "telegraph": {"shape": "circle", "radius": 3.5},
		"effects": [{"type": "damage", "min": 40.0, "max": 50.0}], "anim": "Spellcast_Raise"},
	"fel_gate": {"name": "Врата легиона", "cd": 22.0, "range": 0.0, "target": "self", "cast": 4.5, "interrupt": true,
		"school": "fire", "delivery": "summon", "summon": "fel_portal", "count": 1, "ring": 10.0, "anim": "Spellcast_Summon"},
	"fel_cleave": {"name": "Рассечение Скверной", "cd": 8.0, "range": 5.5, "target": "enemy", "cast": 1.2, "interrupt": false,
		"school": "fire", "delivery": "cone", "telegraph": {"shape": "cone", "radius": 6.5, "angle": 90.0},
		"effects": [{"type": "damage", "min": 50.0, "max": 60.0}]},
	"fel_mark": {"name": "Метка Скверны", "cd": 20.0, "range": 40.0, "target": "enemy_random", "cast": 0.0, "interrupt": false,
		"school": "shadow", "delivery": "mark", "min_players": 2, "delay": 5.0, "radius": 7.0,
		"effects": [{"type": "damage", "min": 60.0, "max": 70.0}]},
	"fel_soulburn": {"name": "Выжигание души", "cd": 18.0, "range": 0.0, "target": "self", "cast": 3.0, "interrupt": true,
		"school": "shadow", "delivery": "everyone", "radius": 60.0, "solo": {"mult": 0.6},
		"effects": [{"type": "mana_burn_pct", "pct": 0.35}, {"type": "damage", "min": 40.0, "max": 50.0}], "anim": "Spellcast_Raise"},
	"portal_imps": {"name": "Бесы из портала", "cd": 8.0, "range": 0.0, "target": "self", "cast": 0.0, "interrupt": false,
		"school": "fire", "delivery": "summon", "summon": "imp", "count": 2, "solo": {"count": 1}, "max_alive": 6},
	# ---------------- Инфернал-исполин
	"giant_drop": {"name": "Падение с неба", "cd": 14.0, "range": 26.0, "target": "enemy_point", "cast": 1.8, "interrupt": false,
		"school": "fire", "delivery": "leap", "telegraph": {"shape": "circle", "radius": 5.0}, "hazard": {"r": 4.0, "dur": 8.0, "dps": 14.0},
		"effects": [{"type": "damage", "min": 50.0, "max": 60.0}, {"type": "stun", "dur": 1.0}], "anim": "Spellcast_Raise"},
	"giant_nova": {"name": "Огненный вал", "cd": 20.0, "range": 0.0, "target": "self", "cast": 3.0, "interrupt": true,
		"school": "fire", "delivery": "area", "cond": {"enemy_near": 16.0}, "telegraph": {"shape": "circle", "radius": 16.0}, "solo": {"mult": 0.6},
		"effects": [{"type": "damage", "min": 70.0, "max": 85.0}], "anim": "Spellcast_Raise"},
	# ---------------- Гоблинский механоогр
	"mecha_mines": {"name": "Минное поле", "cd": 16.0, "range": 0.0, "target": "self", "cast": 1.2, "interrupt": false,
		"school": "fire", "delivery": "mines", "count": 6, "radius": 14.0, "mine": {"trigger": 1.5, "blast": 3.5, "dur": 30.0, "fuse": 0.9},
		"effects": [{"type": "damage", "min": 45.0, "max": 55.0}, {"type": "knockback", "dist": 4.0}], "anim": "Throw"},
	"mecha_rockets": {"name": "Ракетный залп", "cd": 8.0, "range": 40.0, "target": "enemy", "cast": 1.6, "interrupt": false,
		"school": "fire", "delivery": "barrage", "count": 6, "spread": 7.0, "telegraph": {"shape": "circle", "radius": 3.2},
		"effects": [{"type": "damage", "min": 35.0, "max": 45.0}], "anim": "Spellcast_Shoot"},
	"mecha_repair": {"name": "Ремонт", "cd": 22.0, "range": 0.0, "target": "self", "cast": 3.0, "interrupt": true,
		"school": "arcane", "delivery": "target", "solo": {"mult": 0.6},
		"effects": [{"type": "heal_pct", "pct": 0.08}], "anim": "Interact"},
	"mecha_flame": {"name": "Огнемёт", "cd": 9.0, "range": 7.0, "target": "enemy", "cast": 1.2, "interrupt": false,
		"school": "fire", "delivery": "cone", "telegraph": {"shape": "cone", "radius": 8.0, "angle": 70.0},
		"effects": [{"type": "damage", "min": 45.0, "max": 55.0}]},
	# ---------------- Король огров
	"king_smash": {"name": "Сокрушение", "cd": 9.0, "range": 6.0, "target": "enemy", "cast": 1.4, "interrupt": false,
		"school": "physical", "delivery": "cone", "telegraph": {"shape": "cone", "radius": 8.0, "angle": 100.0},
		"effects": [{"type": "damage", "min": 55.0, "max": 65.0}, {"type": "knockback", "dist": 5.0}], "anim": "2H_Melee_Attack_Spinning"},
	"king_share": {"name": "Сокрушительный удар", "cd": 20.0, "range": 30.0, "target": "enemy_random", "cast": 2.5, "interrupt": false,
		"school": "physical", "delivery": "share", "min_players": 2, "telegraph": {"shape": "circle", "radius": 4.0},
		"effects": [{"type": "damage", "min": 160.0, "max": 180.0}], "anim": "2H_Melee_Attack_Chop"},
	"king_feast": {"name": "Пир", "cd": 22.0, "range": 0.0, "target": "self", "cast": 3.0, "interrupt": true,
		"school": "nature", "delivery": "target", "solo": {"mult": 0.6},
		"effects": [{"type": "heal_pct", "pct": 0.1}], "anim": "Interact"},
	"king_quake": {"name": "Сотрясение", "cd": 18.0, "range": 0.0, "target": "self", "cast": 1.5, "interrupt": false,
		"school": "physical", "delivery": "shockwave", "cond": {"enemy_near": 24.0}, "telegraph": {"shape": "circle", "radius": 3.0},
		"waves": {"count": 2, "interval": 1.5, "speed": 8.0, "width": 1.4, "max": 24.0},
		"effects": [{"type": "damage", "min": 35.0, "max": 45.0}], "anim": "2H_Melee_Attack_Chop"},
	# ---------------- Двухголовый огр
	"ogre2_smash": {"name": "Сокрушение левой головы", "cd": 8.0, "range": 6.0, "target": "enemy", "cast": 1.4, "interrupt": false,
		"school": "physical", "delivery": "cone", "telegraph": {"shape": "cone", "radius": 7.0, "angle": 100.0},
		"effects": [{"type": "damage", "min": 45.0, "max": 55.0}, {"type": "knockback", "dist": 4.0}], "anim": "2H_Melee_Attack_Spinning"},
	"ogre2_charge": {"name": "Таран", "cd": 12.0, "range": 18.0, "target": "enemy", "cast": 1.5, "interrupt": false,
		"school": "physical", "delivery": "charge", "cond": {"min_dist": 5.0}, "telegraph": {"shape": "line", "radius": 18.0, "width": 3.0},
		"effects": [{"type": "damage", "min": 40.0, "max": 50.0}, {"type": "knockback", "dist": 4.0}]},
	"ogre2_fireball": {"name": "Огненный шар", "cd": 7.0, "range": 28.0, "target": "enemy_point", "cast": 1.6, "interrupt": false,
		"school": "fire", "delivery": "area", "telegraph": {"shape": "circle", "radius": 4.0},
		"effects": [{"type": "damage", "min": 45.0, "max": 55.0}], "anim": "Spellcast_Shoot"},
	"ogre2_flames": {"name": "Пламя огров", "cd": 14.0, "range": 0.0, "target": "self", "cast": 2.5, "interrupt": true,
		"school": "fire", "delivery": "everyone", "radius": 30.0, "solo": {"mult": 0.6},
		"effects": [{"type": "damage", "min": 45.0, "max": 55.0}], "anim": "Spellcast_Raise"},

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
