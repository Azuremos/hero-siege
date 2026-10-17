extends RefCounted
## Отправки врагов сопернику в «Войне линий» (лавка Вербовщика у базы).
## Каждая покупка — пачка врагов из mob_data.gd, которая выходит в начале линии соперника, и прибавка к доходу.
##
## Поля:
##   mob, count — кто и сколько; price — цена; income — прибавка к доходу (каждые 15 сек., навсегда);
##   minute — с какой минуты партии доступна; cd — перезарядка покупки (сек.);
##   team_cd — перезарядка общая на команду (дорогие отправки, против снежного кома);
##   target — подсказка в окне лавки: «opposite» — обычно на линию напротив, «any» — сильная отправка, её стоит направить
##   на самую слабую линию соперника. Линию для любой отправки игрок выбирает в окне («Куда»), по умолчанию — напротив;
##   elite — элитный (1–3 аффикса), pick_affix — один аффикс можно выбрать (иначе случайный);
##   champion — чемпион (3 аффикса), boss — босс (здоровье ×BOSS_HP_K, как у боссов общих волн).
## Ступени (tier): 1 — массовка, 2 — тяжёлые и быстрые, 3 — поддержка и элитные, 4 — чемпионы и боссы.

const TIERS := {
	1: "Массовка",
	2: "Тяжёлые и быстрые",
	3: "Поддержка и элитные",
	4: "Чемпионы и боссы",
}

const SENDS := {
	# ---------- 1. массовка
	"s_minion": {"tier": 1, "mob": "minion", "count": 4, "price": 30, "income": 1, "minute": 0, "cd": 3.0, "target": "opposite"},
	"s_grunt": {"tier": 1, "mob": "grunt", "count": 3, "price": 32, "income": 1, "minute": 0, "cd": 3.0, "target": "opposite"},
	"s_imp": {"tier": 1, "mob": "imp", "count": 5, "price": 30, "income": 1, "minute": 0, "cd": 3.0, "target": "opposite"},
	"s_gunner": {"tier": 1, "mob": "gunner", "count": 3, "price": 34, "income": 1, "minute": 0, "cd": 3.0, "target": "opposite"},
	# ---------- 2. тяжёлые и быстрые
	"s_warrior": {"tier": 2, "mob": "warrior", "count": 2, "price": 60, "income": 2, "minute": 3, "cd": 8.0, "target": "opposite"},
	"s_rogue": {"tier": 2, "mob": "rogue", "count": 3, "price": 55, "income": 2, "minute": 3, "cd": 8.0, "target": "opposite"},
	"s_crossbow": {"tier": 2, "mob": "crossbow", "count": 3, "price": 55, "income": 2, "minute": 3, "cd": 8.0, "target": "opposite"},
	"s_berserker": {"tier": 2, "mob": "berserker", "count": 2, "price": 70, "income": 2, "minute": 4, "cd": 8.0, "target": "opposite"},
	"s_raider": {"tier": 2, "mob": "raider", "count": 3, "price": 65, "income": 2, "minute": 4, "cd": 8.0, "target": "opposite"},
	"s_axe_thrower": {"tier": 2, "mob": "axe_thrower", "count": 3, "price": 60, "income": 2, "minute": 4, "cd": 8.0, "target": "opposite"},
	"s_felhound": {"tier": 2, "mob": "felhound", "count": 3, "price": 65, "income": 2, "minute": 4, "cd": 8.0, "target": "opposite"},
	"s_thief": {"tier": 2, "mob": "thief", "count": 3, "price": 60, "income": 2, "minute": 4, "cd": 10.0, "target": "opposite"},
	"s_felguard": {"tier": 2, "mob": "felguard", "count": 2, "price": 80, "income": 3, "minute": 5, "cd": 10.0, "target": "opposite"},
	"s_ogre": {"tier": 2, "mob": "ogre", "count": 2, "price": 80, "income": 3, "minute": 5, "cd": 10.0, "target": "opposite"},
	# ---------- 3. поддержка и элитные
	"s_ghoul": {"tier": 3, "mob": "ghoul", "count": 3, "price": 95, "income": 3, "minute": 7, "cd": 12.0, "target": "any"},
	"s_shaman": {"tier": 3, "mob": "shaman", "count": 1, "price": 115, "income": 3, "minute": 8, "cd": 15.0, "target": "any"},
	"s_succubus": {"tier": 3, "mob": "succubus", "count": 1, "price": 115, "income": 3, "minute": 8, "cd": 15.0, "target": "any"},
	"s_necromancer": {"tier": 3, "mob": "necromancer", "count": 1, "price": 125, "income": 4, "minute": 8, "cd": 15.0, "target": "any"},
	"s_ogre_mage": {"tier": 3, "mob": "ogre_mage", "count": 1, "price": 125, "income": 4, "minute": 8, "cd": 15.0, "target": "any"},
	"s_banshee": {"tier": 3, "mob": "banshee", "count": 2, "price": 135, "income": 4, "minute": 10, "cd": 15.0, "target": "any"},
	"s_infernal": {"tier": 3, "mob": "infernal", "count": 1, "price": 170, "income": 5, "minute": 10, "cd": 20.0, "target": "any"},
	"e_warrior": {"tier": 3, "mob": "warrior", "count": 1, "price": 220, "income": 6, "minute": 10, "cd": 25.0, "target": "any", "elite": true, "pick_affix": true},
	"e_berserker": {"tier": 3, "mob": "berserker", "count": 1, "price": 230, "income": 6, "minute": 10, "cd": 25.0, "target": "any", "elite": true, "pick_affix": true},
	"e_felguard": {"tier": 3, "mob": "felguard", "count": 1, "price": 240, "income": 7, "minute": 11, "cd": 25.0, "target": "any", "elite": true, "pick_affix": true},
	"e_ogre": {"tier": 3, "mob": "ogre", "count": 1, "price": 240, "income": 7, "minute": 11, "cd": 25.0, "target": "any", "elite": true, "pick_affix": true},
	# ---------- 4. чемпионы и боссы (дорого, поздно, перезарядка общая на команду)
	"c_warrior": {"tier": 4, "mob": "warrior", "count": 1, "price": 450, "income": 12, "minute": 14, "cd": 60.0, "target": "any", "champion": true},
	"c_berserker": {"tier": 4, "mob": "berserker", "count": 1, "price": 450, "income": 12, "minute": 14, "cd": 60.0, "target": "any", "champion": true},
	"c_felguard": {"tier": 4, "mob": "felguard", "count": 1, "price": 480, "income": 13, "minute": 15, "cd": 60.0, "target": "any", "champion": true},
	"c_ogre": {"tier": 4, "mob": "ogre", "count": 1, "price": 480, "income": 13, "minute": 15, "cd": 60.0, "target": "any", "champion": true},
	"b_warlord": {"tier": 4, "mob": "boss_warlord", "count": 1, "price": 900, "income": 22, "minute": 18, "cd": 180.0, "team_cd": true, "target": "any", "boss": true},
	"b_wolf_leader": {"tier": 4, "mob": "boss_wolf_leader", "count": 1, "price": 900, "income": 22, "minute": 18, "cd": 180.0, "team_cd": true, "target": "any", "boss": true},
	"b_infernal": {"tier": 4, "mob": "boss_infernal", "count": 1, "price": 950, "income": 23, "minute": 18, "cd": 180.0, "team_cd": true, "target": "any", "boss": true},
	"b_two_headed": {"tier": 4, "mob": "boss_two_headed", "count": 1, "price": 950, "income": 23, "minute": 18, "cd": 180.0, "team_cd": true, "target": "any", "boss": true},
	"b_lich": {"tier": 4, "mob": "boss_lich", "count": 1, "price": 1800, "income": 42, "minute": 25, "cd": 300.0, "team_cd": true, "target": "any", "boss": true},
	"b_warchief": {"tier": 4, "mob": "boss_warchief", "count": 1, "price": 1800, "income": 42, "minute": 25, "cd": 300.0, "team_cd": true, "target": "any", "boss": true},
	"b_fel_lord": {"tier": 4, "mob": "boss_fel_lord", "count": 1, "price": 1800, "income": 42, "minute": 25, "cd": 300.0, "team_cd": true, "target": "any", "boss": true},
	"b_mecha": {"tier": 4, "mob": "boss_mecha", "count": 1, "price": 1900, "income": 44, "minute": 25, "cd": 300.0, "team_cd": true, "target": "any", "boss": true},
}

## Порядок в окне лавки: по ступени, внутри — по цене.
static func ordered() -> Array:
	var ids: Array = SENDS.keys()
	ids.sort_custom(func(a, b): return [int(SENDS[a]["tier"]), int(SENDS[a]["price"]), a] < [int(SENDS[b]["tier"]), int(SENDS[b]["price"]), b])
	return ids

## Название отправки: «Огр-громила ×2», «★ Скелет-воин (элитный)», «Чемпион: …».
static func title(sid: String, mobs: Dictionary) -> String:
	var s: Dictionary = SENDS[sid]
	var n: String = mobs[s["mob"]]["name"]
	if s.get("champion", false):
		return "Чемпион: %s" % n
	if s.get("elite", false):
		return "★ %s (элитный)" % n
	if int(s["count"]) > 1:
		return "%s ×%d" % [n, int(s["count"])]
	return n
