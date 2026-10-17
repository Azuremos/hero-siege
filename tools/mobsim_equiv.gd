extends Node
## Тест эквивалентности путей симуляции мобов: GDScript и C++ (MobSimNative).
## Запуск: Godot --path . -- --mobsimtest   (из главного меню вместо него; ответ — в консоль, затем выход)
## Берётся настоящий mob_manager.gd (без сцены): 500 мобов в толпе на площадке 120×120 м, 60 препятствий,
## 2 ледяные стены, цели и скорости — от одного зерна. Один и тот же код (_rebuild_grid, _queue_move, _apply_moves)
## выполняется на обоих путях. Проверки:
##   1) один шаг из одинакового состояния — позиции, yaw, упоры в стены (допуск 1e-4 м);
##   2) 200 шагов подряд — расхождение в толпе (накапливается из-за float; допуск 0,05 м);
##   3) query_radius — одни и те же мобы в том же порядке; 4) снимок для клиентов — побайтно.

const MobManagerScript := preload("res://scripts/world/mob_manager.gd")
const N := 500
const STEPS := 200
const DT := 0.05

func _ready() -> void:
	if not ClassDB.class_exists("MobSimNative"):
		print("MOBSIM EQUIV: MobSimNative не загружен — проверять нечего (FAIL)")
		Sfx.quit_game()
		return
	var ok := true
	var a := _make(false)
	var b := _make(true)
	# 1) один шаг из одинакового состояния
	var one := _step_diff(a, b)
	print("MOBSIM EQUIV шаг 1: макс. расхождение позиции %.6f м, yaw %.6f, стены совпали: %s" % [one[0], one[1], one[2]])
	ok = ok and one[0] < 1e-4 and one[1] < 1e-3 and one[2]
	# 2) 200 шагов: перед каждым шагом путь C++ получает состояние пути GDScript — каждый шаг из одинакового
	#    состояния, но конфигурации толпы, стен и препятствий меняются от шага к шагу
	var worst := 0.0
	var walls_ok := true
	for s in STEPS:
		_sync(a, b)
		var d := _step_diff(a, b)
		worst = maxf(worst, d[0])
		walls_ok = walls_ok and d[2]
	print("MOBSIM EQUIV %d шагов (каждый из одинакового состояния): макс. расхождение %.6f м, стены совпали: %s" % [STEPS, worst, walls_ok])
	ok = ok and worst < 1e-4 and walls_ok
	# справочно: свободный ход 200 шагов без синхронизации — в толпе расхождения float растут (хаос)
	var fa := _make(false)
	var fb := _make(true)
	for s in STEPS:
		_step_diff(fa, fb)
	var drifts: Array = []
	for i in N:
		drifts.append(fa.mobs[1000 + i].pos2.distance_to(fb.mobs[1000 + i].pos2))
	drifts.sort()
	print("MOBSIM EQUIV свободный ход %d шагов (справочно): медиана %.4f м, 95%% мобов — до %.3f м, максимум %.2f м" % [STEPS, drifts[N / 2], drifts[int(N * 0.95)], drifts[N - 1]])
	fa.free()
	fb.free()
	_sync(a, b)
	# 3) запросы по радиусу
	a._rebuild_grid()
	b._rebuild_grid()
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var q_ok := true
	for k in 200:
		var p := Vector2(rng.randf_range(-60, 60), rng.randf_range(-60, 60))
		var r := rng.randf_range(2.0, 15.0)
		var qa: Array = a.query_radius(p, r).map(func(u): return u.id)
		var qb: Array = b.query_radius(p, r).map(func(u): return u.id)
		if qa != qb:
			q_ok = false
	print("MOBSIM EQUIV query_radius (200 запросов): %s" % ("совпадают" if q_ok else "РАЗНЫЕ"))
	ok = ok and q_ok
	# 4) снимок: один и тот же набор мобов — побайтно
	for i in N:
		b.mobs[a.mobs.keys()[i]].pos2 = a.mobs[a.mobs.keys()[i]].pos2
		b.mobs[a.mobs.keys()[i]].yaw = a.mobs[a.mobs.keys()[i]].yaw
	var sa: PackedByteArray = a._encode_snapshot()
	var sb: PackedByteArray = b._encode_snapshot()
	print("MOBSIM EQUIV снимок: %d байт, %s" % [sa.size(), "совпадает побайтно" if sa == sb else "РАЗНЫЙ"])
	ok = ok and sa == sb
	print("MOBSIM EQUIV: %s" % ("OK" if ok else "FAIL"))
	a.free()
	b.free()
	Sfx.quit_game()

## mob_manager без сцены: мобы, препятствия и стены — от одного зерна (одинаковые для обоих путей).
func _make(native: bool) -> Node:
	var mm: Node = MobManagerScript.new()
	if native:
		mm._native = ClassDB.instantiate("MobSimNative")
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261017
	for i in 60:
		var c := Vector2(rng.randf_range(-55, 55), rng.randf_range(-55, 55))
		if rng.randf() < 0.5:
			mm._add_static(c, c, rng.randf_range(0.5, 2.0))
		else:
			mm._add_static(c, c + Vector2(rng.randf_range(-6, 6), rng.randf_range(-6, 6)), rng.randf_range(0.5, 1.5))
	if native:
		var oa := PackedVector2Array()
		var ob := PackedVector2Array()
		var orr := PackedFloat32Array()
		for s: Array in mm._static_obs:
			oa.append(s[0])
			ob.append(s[1])
			orr.append(s[2])
		mm._native.set_obstacles(oa, ob, orr)
	mm.walls[1] = {"a": Vector2(-10, 5), "b": Vector2(10, 5), "hp": 100.0, "max": 100.0, "stage": 0, "until": 1e9}
	mm.walls[2] = {"a": Vector2(20, -30), "b": Vector2(20, -10), "hp": 100.0, "max": 100.0, "stage": 0, "until": 1e9}
	for i in N:
		var m = MobManagerScript.Mob.new()
		var u := Unit.new()
		u.id = 1000 + i
		u.radius = rng.randf_range(0.5, 1.2)
		u.hp = rng.randf_range(10, 100)
		u.max_hp = 100.0
		m.unit = u
		m.def = {"speed": rng.randf_range(3.0, 6.0), "ranged": rng.randf() < 0.3}
		m.state = MobManagerScript.S.MOVE if rng.randf() < 0.7 else MobManagerScript.S.CHASE
		# толпа: половина — у центра, остальные — по площадке; цели — на другой стороне
		var spread := 12.0 if i % 2 == 0 else 55.0
		m.pos2 = Vector2(rng.randf_range(-spread, spread), rng.randf_range(-spread, spread))
		m.yaw = rng.randf_range(-PI, PI)
		m.set_meta("goal", Vector2(rng.randf_range(-60, 60), rng.randf_range(-60, 60)))
		mm.mobs[u.id] = m
	return mm

## Шаг обоих путей из их текущих состояний; если состояния совпадают — это проверка одного шага.
## Возвращает [макс. расхождение позиции после шага, макс. расхождение yaw, совпали ли упоры в стены].
func _step_diff(a: Node, b: Node) -> Array:
	var before_same := true
	for mm in [a, b]:
		mm._rebuild_grid()
		for m in mm.mobs.values():
			if m.state != MobManagerScript.S.WALL:
				mm._queue_move(m, m.get_meta("goal"), float(m.def["speed"]))
		mm._apply_moves(DT, 0.0)
	var dp := 0.0
	var dy := 0.0
	var walls_same := true
	var ka: Array = a.mobs.keys()
	for id in ka:
		var ma = a.mobs[id]
		var mb = b.mobs[id]
		dp = maxf(dp, ma.pos2.distance_to(mb.pos2))
		dy = maxf(dy, absf(angle_difference(ma.yaw, mb.yaw)))
		if ma.state != mb.state or ma.wall != mb.wall:
			walls_same = false
	return [dp, dy, walls_same and before_same]

## Состояние пути GDScript — пути C++ (позиции, yaw, состояние и стена).
func _sync(a: Node, b: Node) -> void:
	for id in a.mobs:
		var ma = a.mobs[id]
		var mb = b.mobs[id]
		mb.pos2 = ma.pos2
		mb.yaw = ma.yaw
		mb.state = ma.state
		mb.wall = ma.wall
