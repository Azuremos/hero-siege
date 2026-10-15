extends SceneTree
## Симуляция добычи: уровень и качество выпадающих вещей.
## Запуск: godot --headless --path . -s res://tools/loot_sim.gd
## 1) Качество по уровню героев и источнику (ItemData.QUALITY_CHANCE, SOURCE_BONUS): доли и «сколько врагов
##    на одну синюю/фиолетовую/легендарную» при шансе вещи 6% × 40% с обычного врага.
## 2) Партия: опыт за состав каждой волны (formulas.gd) по правилам дележа опыта из world.gd — какой уровень
##    у героя на какой волне, сколько вещей какого качества он увидит за осаду и сколько можно надеть сразу.

const Formulas := preload("res://scripts/data/formulas.gd")
const MobData := preload("res://scripts/data/mob_data.gd")
const ItemData := preload("res://scripts/data/item_data.gd")
const N := 200000
const GEAR_PER_MOB := 0.06 * 0.4

func _init() -> void:
	seed(12345)
	print("== Качество по уровню героев (обычный враг), %d бросков на строку" % N)
	print("| Уровень | Белое | Зелёное | Синее | Фиолет. | Легенд. | Врагов на синюю | на фиолет. | на легенд. |")
	print("|---|---|---|---|---|---|---|---|---|")
	for lvl in [1, 3, 5, 8, 10, 12, 15, 20, 25, 30]:
		_row(str(lvl), lvl, "mob")
	print("\n== Источник на 15-м уровне")
	print("| Источник | Белое | Зелёное | Синее | Фиолет. | Легенд. |")
	print("|---|---|---|---|---|---|")
	for src in ["mob", "elite", "champion", "boss"]:
		_row(src, 15, src, false)
	for scenario in [["одиночка", 1, 0.7], ["группа из 3", 3, 0.9]]:
		_run(scenario[0], scenario[1], scenario[2])
	quit()

func _row(title: String, lvl: int, src: String, per_mob: bool = true) -> void:
	var c := [0, 0, 0, 0, 0]
	for i in N:
		c[ItemData.roll_quality(lvl, src, randf())] += 1
	var s := "| %s |" % title
	for q in 5:
		s += " %.1f%% |" % (100.0 * c[q] / N)
	if per_mob:
		for q in [2, 3, 4]:
			var p := float(c[q]) / N * GEAR_PER_MOB
			s += (" %d |" % int(1.0 / p)) if p > 0.0 else " — |"
	print(s)

## Партия на 30 волн: уровни по опыту и сколько вещей какого качества выпало (обычные враги + элитные + боссы).
func _run(title: String, players: int, kill_frac: float) -> void:
	var lvl := 1
	var xp := 0.0
	var share := (1.0 + 0.5 * float(players - 1)) / float(players)
	var q_at := {}       # первая волна, на которой выпало качество q
	var counts := [0, 0, 0, 0, 0]
	var wear := [0, 0]
	print("\n== %s: волна → уровень героя, вещи за волну по качеству" % title)
	for wave in range(1, 31):
		var levels: Array = [lvl] if players == 1 else [lvl, lvl, maxi(1, lvl - 2)]
		var comp: Array = Formulas.wave_plan(wave, ["undead", "orcs", "demons", "goblins"], players)["list"]
		var wc := [0, 0, 0, 0, 0]
		for e in comp:
			var def: Dictionary = MobData.MOBS[e[0]]
			xp += float(def["xp"]) * (1.0 + 0.1 * float(wave - 1)) * share * kill_frac * 1.1   # 1.1 — человек
			var src := "boss" if def.get("boss", false) else ("elite" if wave >= 4 and randf() < 0.06 else "mob")
			var n := 2 if src == "boss" else (1 if src == "elite" else (1 if randf() < GEAR_PER_MOB else 0))
			for i in n:
				var q := ItemData.roll_quality(Formulas.typical_level(levels), src, randf())
				var ilvl := Formulas.gear_ilvl(wave, levels, src)
				wc[q] += 1
				counts[q] += 1
				if not q_at.has(q):
					q_at[q] = wave
				wear[0] += 1
				wear[1] += 1 if levels[0] >= ilvl else 0
		if wave % 3 == 0 or wave <= 2:
			print("   волна %2d: уровень %2d, вещи %s" % [wave, lvl, str(wc)])
		while xp >= Formulas.xp_to_next(lvl) and lvl < 30:
			xp -= Formulas.xp_to_next(lvl)
			lvl += 1
	print("   всего по качеству %s; первая синяя — волна %s, фиолетовая — %s, легендарная — %s; надеть сразу %d%%" % [str(counts),
		str(q_at.get(2, "—")), str(q_at.get(3, "—")), str(q_at.get(4, "—")), int(100.0 * wear[1] / maxf(1.0, wear[0]))])
