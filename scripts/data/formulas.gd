extends RefCounted
## Формулы баланса: опыт, рост силы героя, состав волн, сила врагов.
## Вызываются через GameData.* (GameData.xp_to_next и т.п.).

static func xp_to_next(level: int) -> int:
	return int(50.0 * pow(float(level), 1.45))

## Множитель силы эффектов (урон/лечение) героя от уровня. Вместе с атрибутами урон растёт заметно.
static func level_power(level: int) -> float:
	return 1.0 + 0.05 * float(level - 1)

## Бюджет волны на одну полосу: растёт с номером волны и (немного) с числом игроков.
static func wave_budget(wave: int, players: int) -> float:
	return (3.0 + 1.25 * float(wave)) * (1.0 + 0.15 * float(maxi(players, 1) - 1))

## Состав волны из бюджета. lane_factions — фракция для каждой открытой полосы (по индексу).
## Возвращает {"list": [[тип, индекс полосы, "" | "champion"], …], "special": "" | "scout" | "siege" | "arcane"}.
## Случайность — от зерна волны и полосы: хост и тесты получают одну и ту же волну.
## Босс-волна — каждая BOSS_EVERY-я (совпадает с передышкой), главный босс — каждая вторая из них.
const BOSS_EVERY := 3

static func wave_plan(wave: int, lane_factions: Array, players: int, final_boss: bool = false) -> Dictionary:
	var Factions = load("res://scripts/data/factions.gd")
	var Mobs = load("res://scripts/data/mob_data.gd")
	var wrng := RandomNumberGenerator.new()
	wrng.seed = wave * 7919 + 17
	var special := ""
	if wave >= 6 and wrng.randf() < 0.2:
		special = ["scout", "siege", "arcane"][wrng.randi() % 3]
	var list: Array = []
	for li in lane_factions.size():
		var f: String = lane_factions[li]
		var rng := RandomNumberGenerator.new()
		rng.seed = wave * 7919 + li * 104729 + f.hash()
		var roster: Array = []
		for id in Mobs.MOBS:
			var d: Dictionary = Mobs.MOBS[id]
			if d.get("faction", "") == f and not d["role"] in ["boss", "test", "summon"] and int(d["min_wave"]) <= wave:
				roster.append(id)
		var budget := wave_budget(wave, players)
		var support_cap := 1 + wave / 6
		var supports := 0
		var guard := 0
		while budget >= 0.8 and guard < 200:
			guard += 1
			# роль по весам (особая волна усиливает свои роли)
			var weights: Dictionary = {}
			var total := 0.0
			for id in roster:
				var d: Dictionary = Mobs.MOBS[id]
				var role: String = d["role"]
				if float(d["cost"]) > budget or (role == "support" and supports >= support_cap):
					continue
				var w: float = float(Factions.ROLE_WEIGHTS.get(role, 1.0))
				if special != "":
					w *= float(Factions.SPECIAL_WAVES[special]["roles"].get(role, 0.4))
				# внутри роли — поровну между видами
				var same := roster.filter(func(o): return Mobs.MOBS[o]["role"] == role).size()
				weights[id] = w / float(maxi(same, 1))
				total += weights[id]
			if weights.is_empty():
				break
			var roll := rng.randf() * total
			var pick: String = weights.keys()[0]
			for id in weights:
				roll -= weights[id]
				if roll <= 0.0:
					pick = id
					break
			budget -= float(Mobs.MOBS[pick]["cost"])
			if Mobs.MOBS[pick]["role"] == "support":
				supports += 1
			list.append([pick, li, ""])
	# босс-волна (каждая 3-я — перед передышкой): лейтенант одной из сторон по очереди; каждая 6-я и финальная — главный босс.
	# Остальные стороны выводят чемпиона (элитный с тремя аффиксами).
	if wave % BOSS_EVERY == 0 or final_boss:
		var Bosses = load("res://scripts/data/boss_data.gd")
		var main := wave % (BOSS_EVERY * 2) == 0 or final_boss
		var boss_lane: int = (maxi(wave / (BOSS_EVERY * 2 if main else BOSS_EVERY), 1) - 1) % maxi(lane_factions.size(), 1)
		for li in lane_factions.size():
			var f: String = lane_factions[li]
			if li == boss_lane:
				list.append([Bosses.BY_FACTION[f]["main" if main else "lieutenant"], li, ""])
			elif Factions.FACTIONS[f]["champion"] != "":
				list.append([Factions.FACTIONS[f]["champion"], li, "champion"])
	return {"list": list, "special": special}

static func mob_hp_mult(wave: int, players: int) -> float:
	# число игроков частично учтено в бюджете волны (больше врагов), остальное — в здоровье
	return (1.0 + 0.18 * float(wave - 1)) * (1.0 + 0.35 * float(max(players, 1) - 1))

static func mob_dmg_mult(wave: int) -> float:
	return 1.0 + 0.10 * float(wave - 1)


## Множитель стоимости заклинаний от уровня, как в WoW: стоимость — доля базового запаса маны класса.
## Базовый запас — без снаряжения и талантов: base_mana + 15 × Интеллект класса на этом уровне.
## Так заклинание на любом уровне стоит ту же долю «голого» запаса, а Интеллект со снаряжения,
## эликсиры и таланты на запас маны дают реальный выигрыш.
static func mana_scale(cls: Dictionary, level: int) -> float:
	var int0: float = float(cls["attrs"]["int"])
	var grow: float = float(cls["grow"]["int"])
	var base0: float = float(cls["base_mana"]) + 15.0 * int0
	var base_l: float = float(cls["base_mana"]) + 15.0 * (int0 + grow * float(level - 1))
	return base_l / maxf(base0, 1.0)

const ItemData := preload("res://scripts/data/item_data.gd")

## «Типичный» уровень героев рядом: медиана, но не выше самого младшего + 3, чтобы в группе вещь не ждала его долго.
static func typical_level(levels: Array) -> int:
	var sorted := levels.duplicate()
	sorted.sort()
	if sorted.is_empty():
		return 1
	return mini(int(sorted[sorted.size() / 2]), int(sorted[0]) + 3)

## Уровень выпавшей вещи: около типичного уровня героев (−2…0, элитные и боссы +1), чтобы почти всё
## можно было надеть сразу или через 1–2 уровня. Волна ограничивает сверху: на первых волнах высоких вещей нет.
static func gear_ilvl(wave: int, levels: Array, source: String = "mob") -> int:
	var lvl := typical_level(levels)
	var ilvl := lvl + randi_range(-2, 0) + (1 if source != "mob" else 0)
	var by_wave := 3 + int(float(wave) * 1.3)
	return clampi(mini(ilvl, by_wave), 1, ItemData.MAX_ILVL)

# ---------------------------------------------------------------- «Поход» (сессия 07)
## Сила врагов в «Походе» — от наивысшего уровня героя в отряде: волна считается не меньше той, на которой
## обычный отряд дорастает до этого уровня (уровень ≈ 1,3 × волна). Слабый друг врагов не ослабляет.
static func campaign_wave(wave: int, max_level: int) -> int:
	return maxi(wave, int(round(float(max_level) / 1.3)))

## Уровень угрозы (растёт после каждой победы в «Походе»): здоровье врагов +25%, урон +12% за ступень.
static func threat_hp(threat: int) -> float:
	return 1.0 + 0.25 * float(threat)

static func threat_dmg(threat: int) -> float:
	return 1.0 + 0.12 * float(threat)

## Добыча после 30-го уровня растёт через угрозу: +2 к уровню предмета за ступень (до 50).
static func threat_ilvl(threat: int) -> int:
	return 2 * threat
