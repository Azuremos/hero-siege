extends SceneTree
## Симуляция уровня выпадающих вещей: какую долю вещей герой может надеть сразу или через 1–2 уровня.
## Запуск: godot --headless --path . -s res://tools/loot_sim.gd
## Модель: опыт за состав каждой волны (formulas.gd) по правилам дележа опыта из world.gd;
## одиночка убивает 70% врагов волны (отстающий — 40%), группа из трёх — 90%, а один из троих отстаёт на 2 уровня
## (умирал, отходил к лавке). Сравниваются прежняя ступень (только по волне) и новая (по уровню героев).

const Formulas := preload("res://scripts/data/formulas.gd")
const MobData := preload("res://scripts/data/mob_data.gd")
const ItemData := preload("res://scripts/data/item_data.gd")


func _init() -> void:
	for scenario in [["одиночка", 1, 0.7], ["одиночка, отстаёт по опыту", 1, 0.4], ["группа из 3", 3, 0.9]]:
		_run(scenario[0], scenario[1], scenario[2])
	quit()

func _run(title: String, players: int, kill_frac: float) -> void:
	var lvl := 1
	var xp := 0.0
	var share := (1.0 + 0.5 * float(players - 1)) / float(players)
	var stats := {"n": 0, "old_now": 0, "old_soon": 0, "new_now": 0, "new_soon": 0}
	var rows: Array = []
	for wave in range(1, 31):
		var levels: Array = [lvl] if players == 1 else [lvl, lvl, maxi(1, lvl - 2)]
		var comp: Array = Formulas.wave_plan(wave, ["undead", "orcs", "demons", "goblins"], players)["list"]
		var gear_drops := 0.0
		for e in comp:
			var def: Dictionary = MobData.MOBS[e[0]]
			xp += float(def["xp"]) * (1.0 + 0.1 * float(wave - 1)) * share * kill_frac * 1.1   # 1.1 — человек
			gear_drops += 2.0 if def.get("boss", false) else 0.06 * 0.5
		# по 200 бросков на волну, взвешенных числом вещей
		var n := int(ceil(gear_drops * 200.0))
		for i in n:
			var bonus := 0
			var t_new := Formulas.gear_tier(wave + bonus, levels)
			if randf() < 0.25:
				t_new = maxi(1, t_new - 1)
			var t_old := Formulas.old_gear_tier(wave)
			for l in levels:
				stats["n"] += 1
				var need_new := int(ItemData.TIERS[t_new - 1]["level"])
				var need_old := int(ItemData.TIERS[t_old - 1]["level"])
				stats["new_now"] += 1 if l >= need_new else 0
				stats["new_soon"] += 1 if l + 2 >= need_new else 0
				stats["old_now"] += 1 if l >= need_old else 0
				stats["old_soon"] += 1 if l + 2 >= need_old else 0
		rows.append("волна %2d: уровни %s, ступень было ~%d стало %d" % [wave, str(levels), Formulas.old_gear_tier(wave), Formulas.gear_tier(wave, levels)])
		while xp >= Formulas.xp_to_next(lvl) and lvl < 30:
			xp -= Formulas.xp_to_next(lvl)
			lvl += 1
	var n := float(stats["n"])
	print("== %s: было — сразу %d%%, через ≤2 ур. %d%%;  стало — сразу %d%%, через ≤2 ур. %d%%" % [title,
		int(stats["old_now"] / n * 100), int(stats["old_soon"] / n * 100), int(stats["new_now"] / n * 100), int(stats["new_soon"] / n * 100)])
	for r in rows.slice(0, 30, 3):
		print("   ", r)
