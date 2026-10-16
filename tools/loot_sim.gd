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
	_slots()
	_sets("одиночка", 1)
	_sets("группа из 3", 3)
	quit()

## 3) Какие вещи падают: доля ячеек (как economy._random_gear: аксессуар с шансом 20%, иначе любой шаблон поровну)
##    и сколько вещей своего класса по ячейкам на 100 выпавших.
func _slots() -> void:
	var by_slot := {}
	var for_class := {}
	var keys: Array = ItemData.TEMPLATES.keys()
	for i in N:
		var slot := "trinket"
		var base := ""
		if randf() >= 0.2:
			base = keys[randi() % keys.size()]
			slot = ItemData.TEMPLATES[base]["slot"]
		by_slot[slot] = int(by_slot.get(slot, 0)) + 1
		for cid in ["mage", "priest", "paladin", "warrior"]:
			var cls: Array = ItemData.TEMPLATES[base].get("classes", []) if base != "" else []
			if cls.is_empty() or cls.has(cid):
				var k: String = cid + "|" + slot
				for_class[k] = int(for_class.get(k, 0)) + 1
	print("\n== Ячейки выпавших вещей (%d бросков)" % N)
	print("| Ячейка | Доля | Маг | Жрец | Паладин | Воин |")
	print("|---|---|---|---|---|---|")
	for slot in ["weapon", "offhand", "helm", "shoulders", "chest", "boots", "ring", "amulet", "trinket"]:
		var s := "| %s | %.1f%% |" % [ItemData.SLOTS[slot], 100.0 * int(by_slot.get(slot, 0)) / N]
		for cid in ["mage", "priest", "paladin", "warrior"]:
			s += " %.1f |" % (100.0 * int(for_class.get(cid + "|" + slot, 0)) / N)
		print(s)

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

## 4) Сеты и легендарки (сессия 07б): правила economy._roll_special. 300 партий по 40 волн:
##    волна первой части сета своего класса, первой части сета своей ветки, полного сета своей ветки (6 разных частей)
##    и первой легендарки своего класса. Медиана и доля партий, где это случилось.
const Econ := preload("res://scripts/world/economy.gd")

func _sets(title: String, players: int) -> void:
	var runs := 300
	var first_any: Array = []
	var first_own: Array = []
	var full_own: Array = []
	var first_leg: Array = []
	var share := (1.0 + 0.5 * float(players - 1)) / float(players)
	for r in runs:
		var lvl := 1
		var xp := 0.0
		var pity := 0.0
		var lpity := 0.0
		var got: Dictionary = {}
		var fa := -1
		var fo := -1
		var fu := -1
		var fl := -1
		for wave in range(1, 41):
			var comp: Array = Formulas.wave_plan(wave, ["undead", "orcs", "demons", "goblins"], players)["list"]
			for e in comp:
				var def: Dictionary = MobData.MOBS[e[0]]
				xp += float(def["xp"]) * (1.0 + 0.1 * float(wave - 1)) * share * 0.8 * 1.1
				var src := "boss" if def.get("boss", false) else ("champion" if e[2] == "champion" else ("elite" if wave >= 4 and randf() < 0.06 else "mob"))
				if src == "mob":
					continue
				if lvl >= Econ.SET_MIN_LEVEL:
					if randf() < float(Econ.SET_CHANCE[src]) + pity:
						pity = 0.0
						# 70% — класс из отряда (наш — 1 из players), 30% — любой из 5
						var mine := randf() < Econ.PARTY_SHARE / float(players) + (1.0 - Econ.PARTY_SHARE) / 5.0
						var for_me := randf() < Econ.PARTY_SHARE / (Econ.PARTY_SHARE / float(players) + (1.0 - Econ.PARTY_SHARE) / 5.0) / float(players)
						if mine:
							if fa < 0:
								fa = wave
							if randf() < ((Econ.MAIN_TREE_SHARE + (1.0 - Econ.MAIN_TREE_SHARE) / 3.0) if for_me else 1.0 / 3.0):      # сет своей ветки
								if fo < 0:
									fo = wave
								var miss: Array = range(6).filter(func(s): return not got.has(s))
								got[miss[randi() % miss.size()] if for_me and not miss.is_empty() and randf() < Econ.MISSING_SHARE else randi() % 6] = true
								if got.size() == 6 and fu < 0:
									fu = wave
					else:
						pity += Econ.SET_PITY
				if lvl >= Econ.LEG_MIN_LEVEL:
					if randf() < float(Econ.LEG_CHANCE[src]) + lpity:
						lpity = 0.0
						# легендарки своего класса: 2 из (2 своих + 2 общих) при выпадении для нашего класса
						if randf() < (Econ.PARTY_SHARE / float(players) + (1.0 - Econ.PARTY_SHARE) / 5.0) and randf() < 0.5 and fl < 0:
							fl = wave
					else:
						lpity += Econ.LEG_PITY
			while xp >= Formulas.xp_to_next(lvl) and lvl < 30:
				xp -= Formulas.xp_to_next(lvl)
				lvl += 1
		first_any.append(fa)
		first_own.append(fo)
		full_own.append(fu)
		first_leg.append(fl)
	print("\n== Сеты и легендарки: %s, %d партий по 40 волн (медиана волны; в скобках — доля партий, где случилось)" % [title, runs])
	print("| Событие | Медиана волны | Партий |")
	print("|---|---|---|")
	for row in [["первая часть сета своего класса", first_any], ["первая часть сета своей ветки", first_own],
			["полный сет своей ветки (6 частей)", full_own], ["первая легендарка своего класса", first_leg]]:
		var ok: Array = row[1].filter(func(x): return x > 0)
		ok.sort()
		var med: String = str(ok[ok.size() / 2]) if not ok.is_empty() else "—"
		print("| %s | %s | %d%% |" % [row[0], med, int(100.0 * ok.size() / runs)])
