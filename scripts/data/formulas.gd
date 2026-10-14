extends RefCounted
## Формулы баланса: опыт, рост силы героя, состав волн, сила врагов.
## Вызываются через GameData.* (GameData.xp_to_next и т.п.).

static func xp_to_next(level: int) -> int:
	return int(50.0 * pow(float(level), 1.45))

## Множитель силы эффектов (урон/лечение) героя от уровня. Вместе с атрибутами урон растёт заметно.
static func level_power(level: int) -> float:
	return 1.0 + 0.05 * float(level - 1)

## Состав волны: список [тип_моба, полоса].
static func wave_composition(wave: int, lanes: int, final_boss: bool = false) -> Array:
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

static func mob_hp_mult(wave: int, players: int) -> float:
	return (1.0 + 0.17 * float(wave - 1)) * (1.0 + 0.4 * float(max(players, 1) - 1))

static func mob_dmg_mult(wave: int) -> float:
	return 1.0 + 0.09 * float(wave - 1)


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

## Ступень выпавшей вещи (1..6) для героев с уровнями levels на волне wave:
## самая высокая, которую «типичный» герой рядом наденет сейчас или через 1–2 уровня.
## Типичный — медиана, но не выше самого младшего + 3, чтобы в группе вещь не ждала его долго.
## Волна ограничивает сверху, как раньше: на первых волнах не падают драконьи вещи.
static func gear_tier(wave: int, levels: Array) -> int:
	var tiers: Array = ItemData.TIERS
	var sorted := levels.duplicate()
	sorted.sort()
	var lvl: int = 1
	if not sorted.is_empty():
		lvl = mini(int(sorted[sorted.size() / 2]), int(sorted[0]) + 3)
	var by_level := 1
	for i in tiers.size():
		if int(tiers[i]["level"]) <= lvl + 2:
			by_level = i + 1
	var by_wave := clampi(1 + int((wave - 1) / 4), 1, tiers.size())
	return mini(by_level, by_wave)

## Прежняя ступень — только по волне (для сравнения в --lootsim и tools/loot_sim.gd).
static func old_gear_tier(wave: int) -> int:
	return clampi(1 + int((wave - 1) / 4) - randi() % 2, 1, ItemData.TIERS.size())
