extends SceneTree
## Симуляция экономики «Войны линий»: доход, золото за убийства, опыт и уровень героя по минутам.
## godot --headless --path . --script res://tools/lines_sim.gd [-- --share=0.5 --minutes=40]
## Модель: герой убивает всё на своей линии (общие волны + отправки соперника); каждые 45 сек. идёт к Вербовщику
## и тратит долю share золота на отправки (лучшие доступные), остальное — на вещи (не моделируются, только трата).
## Два игрока: «A» со стратегией share, «B» — со своей (--share_b), чтобы видеть, кто кого обгоняет по доходу.

const L := preload("res://scripts/data/lines_data.gd")
const SD := preload("res://scripts/data/sends.gd")
const Formulas := preload("res://scripts/data/formulas.gd")
const Mobs := preload("res://scripts/data/mob_data.gd")

class P:
	var name := ""
	var share := 0.5
	var gold := 0.0
	var income := 0
	var level := 1
	var xp := 0.0
	var earned_kills := 0.0
	var earned_income := 0.0
	var spent_sends := 0.0
	var spent_items := 0.0
	var cds := {}
	var sent_value := 0.0       # цена отправленного сопернику (для его награды)
	var sends_n := 0

func _init() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var minutes := int(args.get("minutes", 40))
	var a := P.new()
	a.name = "A"
	a.share = float(args.get("share", 0.5))
	var b := P.new()
	b.name = "B"
	b.share = float(args.get("share_b", 0.5))
	var players := [a, b]
	for p: P in players:
		p.gold = L.START_GOLD
	var dt := 1.0
	var next_wave := L.FIRST_WAVE_DELAY
	var next_income := L.INCOME_EVERY
	var next_shop := 25.0
	var wave := 0
	var rows: Array = []
	var minute_acc := {}
	var t := 0.0
	while t < minutes * 60.0:
		t += dt
		var mins := t / 60.0
		if t >= next_wave:
			next_wave += L.WAVE_EVERY
			wave += 1
			var w := maxi(1, int(round(L.wave_strength(mins))))
			var faction: String = ["undead", "orcs", "demons", "goblins"][((wave - 1) / 2) % 4]
			var plan: Dictionary = Formulas.wave_plan(w, [faction], 1)
			var budget := Formulas.wave_budget(w, 1) * L.WAVE_BUDGET_K
			var spent := 0.0
			var gold := 0.0
			var xp := 0.0
			for e in plan["list"]:
				var md: Dictionary = Mobs.MOBS[e[0]]
				if md.get("boss", false) or e[2] == "champion" or spent >= budget:
					continue
				spent += float(md["cost"])
				gold += float(md["gold"]) * L.KILL_GOLD_K
				xp += float(md["xp"]) * (1.0 + 0.1 * float(w - 1)) * L.XP_K
			for p: P in players:
				p.gold += gold
				p.earned_kills += gold
				_give_xp(p, xp)
		if t >= next_income:
			next_income += L.INCOME_EVERY
			for p: P in players:
				var inc := float(L.base_income(mins) + p.income)
				p.gold += inc
				p.earned_income += inc
		if t >= next_shop:
			next_shop += float(L.BOT_SHOP_EVERY)
			for p: P in players:
				var other: P = b if p == a else a
				var budget := p.gold * p.share
				for k in 4:
					var best := ""
					for sid in SD.SENDS:
						var s: Dictionary = SD.SENDS[sid]
						if mins < float(s["minute"]) or float(p.cds.get(sid, 0.0)) > t or float(s["price"]) > budget:
							continue
						if best == "" or [int(s["tier"]), int(s["price"])] > [int(SD.SENDS[best]["tier"]), int(SD.SENDS[best]["price"])]:
							best = sid
					if best == "":
						break
					var s: Dictionary = SD.SENDS[best]
					budget -= float(s["price"])
					p.gold -= float(s["price"])
					p.spent_sends += float(s["price"])
					p.income += int(s["income"])
					p.cds[best] = t + float(s["cd"])
					p.sends_n += 1
					# соперник убивает отправку и получает долю цены и опыт
					other.gold += float(s["price"]) * L.SEND_BOUNTY
					other.earned_kills += float(s["price"]) * L.SEND_BOUNTY
					var md: Dictionary = Mobs.MOBS[s["mob"]]
					_give_xp(other, float(md["xp"]) * float(s["count"]) * (1.0 + 0.1 * (L.wave_strength(mins) - 1.0)) * L.XP_K)
				# остальное — на вещи
				p.spent_items += p.gold
				p.gold = 0.0
		var m := int(t / 60.0)
		if t / 60.0 - float(m) < dt / 60.0 * 0.5 and not minute_acc.has(m) and m > 0:
			minute_acc[m] = true
			rows.append([m, a.level, int(L.base_income(mins) + a.income), int(a.earned_kills), int(a.earned_income), int(a.spent_sends), int(a.spent_items), a.sends_n,
				b.level, int(L.base_income(mins) + b.income), int(L.wave_strength(mins))])
	print("Доход за тик (15 сек.) и золото по минутам. A: доля на отправки %.0f%%, B: %.0f%%" % [a.share * 100.0, b.share * 100.0])
	print("| мин | сила волны | ур. A | доход A | убийства A (всего) | доход A (всего) | на отправки A | на вещи A | отправок A | ур. B | доход B |")
	print("|---|---|---|---|---|---|---|---|---|---|---|")
	for r in rows:
		if int(r[0]) % 5 == 0 or int(r[0]) <= 3:
			print("| %d | %d | %d | %d | %d | %d | %d | %d | %d | %d | %d |" % [r[0], r[10], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9]])
	quit()

func _give_xp(p: P, amount: float) -> void:
	p.xp += amount
	while p.level < 30 and p.xp >= float(Formulas.xp_to_next(p.level)):
		p.xp -= float(Formulas.xp_to_next(p.level))
		p.level += 1
