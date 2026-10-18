extends RefCounted
## Режим «Арена» (по мотивам карты Warcraft 3 Angel Arena): числа и раскладка карты. Читают и режим
## (scripts/modes/arena_mode.gd), и генератор карты (tools/bake_map_arena.gd) — точки лагерей одни и те же.
## Осада и «Линии» эти константы не читают.
##
## Карта (вид сверху, север — минус Z): база команды 0 на юге, команды 1 — на севере (поворот на 180° вокруг
## центра). В центре — закрытая арена дуэлей. Лагеря монстров — по кольцам: у баз слабые, дальше средние,
## к середине сильные с элитными, по краям — боссы. Лагеря описаны для южной половины, северные — зеркально.

const MODE_NAME := "Арена"
const MAP_HALF := 125.0                # карта — квадрат ±125 м

const TEAMS := [
	{"name": "Рассвет", "full": "Орден Рассвета", "color": Color(0.35, 0.6, 1.0)},
	{"name": "Сумрак", "full": "Легион Сумрака", "color": Color(1.0, 0.4, 0.3)},
]
const MAX_TEAM := 3
const MAX_LANES := MAX_TEAM            # то же для общего лобби команд (как у «Линий»)

# ---------------------------------------------------------------- база (для команды 0; у команды 1 — зеркально)
const BASE := Vector2(0, 98)           # центр площади базы
const CASTLE_OFF := Vector2(0, 12)     # замок — за площадью (дальше от центра карты)
const SPAWN_OFF := Vector2(0, -2)      # точка воскрешения
const FOUNTAIN_OFF := Vector2(0, -14)  # фонтан восстановления
## Лавки: [вид торговца, смещение от BASE]. Кузнец, алхимик, Мастер сборки, Книжник.
const SHOPS := [["smith", Vector2(-22, 0)], ["alchemist", Vector2(22, 0)], ["crafter", Vector2(-13, 9)], ["bookseller", Vector2(13, 9)]]
const BASE_HP := 12000.0
const BASE_RADIUS := 6.5
## Фонтан: свои герои и питомцы в радиусе быстро восстанавливаются (доля запаса в секунду).
const FOUNTAIN := {"radius": 10.0, "hp": 0.06, "mana": 0.06}
## Башни базы бьют вражеских героев и их питомцев у базы (урон растёт с минутами партии).
const TOWER := {"radius": 26.0, "every": 1.2, "min": 60.0, "max": 80.0, "grow": 0.08}

# ---------------------------------------------------------------- лагеря
## Отряды фракций по ролям (типы — mob_data.gd).
const FACTION_MOBS := {
	"undead": {"swarm": "minion", "fast": "rogue", "heavy": "warrior", "ranged": "crossbow", "support": "necromancer"},
	"orcs": {"swarm": "grunt", "fast": "raider", "heavy": "berserker", "ranged": "axe_thrower", "support": "shaman"},
	"demons": {"swarm": "imp", "fast": "felhound", "heavy": "felguard", "ranged": "imp", "support": "succubus"},
	"goblins": {"swarm": "gunner", "fast": "gunner", "heavy": "ogre", "ranged": "gunner", "support": "ogre_mage"},
}
## Кольца сложности: состав по ролям, сила (волна для формул осады: base + per_min × минута), элитные,
## возрождение после зачистки, награда (множители опыта и золота), с какого уровня бот туда ходит.
const TIERS := {
	1: {"name": "слабый лагерь", "comp": [["swarm", 3], ["fast", 1]], "wave": 1.0, "per_min": 0.45, "elite": 0, "respawn": 45.0,
		"xp_k": 1.4, "gold_k": 1.2, "bot_level": 1},
	2: {"name": "лагерь", "comp": [["heavy", 1], ["swarm", 2], ["ranged", 1]], "wave": 4.0, "per_min": 0.5, "elite": 0, "respawn": 60.0,
		"xp_k": 1.5, "gold_k": 1.4, "bot_level": 6},
	3: {"name": "сильный лагерь", "comp": [["heavy", 2], ["ranged", 1], ["support", 1]], "wave": 9.0, "per_min": 0.55, "elite": 1, "respawn": 90.0,
		"xp_k": 1.6, "gold_k": 1.7, "bot_level": 12},
	4: {"name": "логово босса", "comp": [], "wave": 12.0, "per_min": 0.5, "elite": 0, "respawn": 300.0, "xp_k": 1.0, "gold_k": 1.5,
		"bot_level": 18, "boss_hp_k": 0.55},
}
const MAX_CAMP_WAVE := 40
const LEASH := 24.0                     # м от центра лагеря: дальше монстры бросают погоню и возвращаются
## Лейтенанты — в центре карты (бывшее место арены), главные боссы — в дальних углах.
## Лагеря южной половины: id, точка, кольцо, фракция (или босс), min_team — с какого размера команд лагерь открыт
## (1 — всегда; 2 — закрыт на 1×1: «половина лагерей у краёв»). Северные — зеркально (id с суффиксом _n).
const CAMPS := [
	{"id": "w1", "pos": Vector2(-30, 64), "tier": 1, "faction": "undead", "min_team": 1},
	{"id": "w2", "pos": Vector2(30, 64), "tier": 1, "faction": "orcs", "min_team": 1},
	{"id": "w3", "pos": Vector2(-62, 82), "tier": 1, "faction": "goblins", "min_team": 2},
	{"id": "w4", "pos": Vector2(62, 82), "tier": 1, "faction": "demons", "min_team": 2},
	{"id": "m1", "pos": Vector2(-46, 38), "tier": 2, "faction": "demons", "min_team": 1},
	{"id": "m2", "pos": Vector2(46, 38), "tier": 2, "faction": "undead", "min_team": 1},
	{"id": "m3", "pos": Vector2(-88, 52), "tier": 2, "faction": "orcs", "min_team": 2},
	{"id": "m4", "pos": Vector2(88, 52), "tier": 2, "faction": "goblins", "min_team": 2},
	{"id": "s1", "pos": Vector2(-50, 12), "tier": 3, "faction": "orcs", "min_team": 1},
	{"id": "s2", "pos": Vector2(50, 12), "tier": 3, "faction": "goblins", "min_team": 1},
	{"id": "b1", "pos": Vector2(-18, 0), "tier": 4, "boss": "lieutenant", "faction": "undead", "min_team": 1},
	{"id": "b2", "pos": Vector2(-100, 96), "tier": 4, "boss": "main", "faction": "demons", "min_team": 1},
]

# ---------------------------------------------------------------- дуэли
const DUEL_FIRST := 180.0               # первая дуэль — на 3-й минуте
const DUEL_EVERY := 210.0               # дальше — раз в 3,5 минуты
const DUEL_WARN := 10.0                 # объявление заранее
const DUEL_TIME := 90.0                 # бой до смерти или 90 сек. (дальше — у кого больше доля здоровья)
## Арена — на восточном краю карты (пользователь), не в центре; круг побольше, дуэлянты — в 24 м друг от друга.
const DUEL_CENTER := Vector2(96, -4)
const DUEL_RADIUS := 21.0               # круг арены (стены — генератор карты)
const DUEL_SPOT := 12.0                 # места дуэлянтов: ± от центра по Z
const DUEL_GOLD := 250                  # победителю: + DUEL_GOLD_MIN за минуту партии
const DUEL_GOLD_MIN := 25

# ---------------------------------------------------------------- экономика и победа
const START_GOLD := 150
const KILL_GOLD := 120                  # за вражеского героя: + KILL_GOLD_LVL × его уровень
const KILL_GOLD_LVL := 12
const KILL_XP_LVL := 40                 # опыт за вражеского героя: × его уровень
## Томики у Книжника: +stat навсегда; цена растёт с каждой покупкой (любого томика) — главный способ тратить золото.
const TOMES := {
	"tome_str": {"name": "Томик силы", "stat": "str", "amount": 4},
	"tome_agi": {"name": "Томик ловкости", "stat": "agi", "amount": 4},
	"tome_sta": {"name": "Томик выносливости", "stat": "sta", "amount": 4},
	"tome_int": {"name": "Томик интеллекта", "stat": "int", "amount": 4},
	"tome_spi": {"name": "Томик духа", "stat": "spi", "amount": 4},
}
const TOME_ORDER := ["tome_str", "tome_agi", "tome_sta", "tome_int", "tome_spi"]
const TOME_PRICE := 120
const TOME_STEP := 30                   # +к цене за каждый уже купленный томик

## Цель партии (выбирает хост): убийства героев, победы в дуэлях или разрушить базу (база — победа в любой цели).
const GOAL_KILLS := {1: 20, 2: 30, 3: 40}
const GOAL_DUELS := 5
const HARD_END_MIN := 60.0              # не достигли цели за 60 минут — побеждает команда с большим счётом

## Боты на хосте (как в «Линиях»): классы и имена.
const BOT_SHOP_EVERY := 60.0            # бот ходит на базу за покупками
const BOT_TOME_SHARE := 0.6             # доля золота на томики (остальное — вещи и сборка)

static func tome_price(bought: int) -> int:
	return TOME_PRICE + TOME_STEP * bought

## Точка для команды: команда 1 — поворот на 180° вокруг центра карты.
static func mirror(p: Vector2, team: int) -> Vector2:
	return p if team == 0 else -p

## Все лагеря обеих половин: [{id, pos, tier, faction, boss, min_team, team_half}].
static func all_camps() -> Array:
	var out: Array = []
	for team in 2:
		for c in CAMPS:
			var d: Dictionary = c.duplicate()
			d["pos"] = mirror(c["pos"], team)
			d["half"] = team
			if team == 1:
				d["id"] = str(c["id"]) + "_n"
			out.append(d)
	return out

static func goal_default(kind: String, team_size: int) -> int:
	if kind == "duels":
		return GOAL_DUELS
	return int(GOAL_KILLS.get(clampi(team_size, 1, 3), 20))
