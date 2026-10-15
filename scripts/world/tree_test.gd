extends Node
## --treetest: зонд с капсулой героя (та же форма и скорость) идёт в каждую рощу, одиночное и сухое дерево
## с шести сторон прямо в центр. Если он прошёл центр насквозь — коллайдер с дырой, тест провален.
## Ускорено: 32 шага зонда на кадр с прежним шагом времени (без проскакивания).

const DIRS := 6
const STEPS := 150          # 2,5 сек. ходьбы при 60 шагах в секунду
const RUN_SPEED := 7.5

var _targets: Array = []    # [имя, центр Vector3, радиус охвата]
var _probe: CharacterBody3D
var _i := 0
var _dir := 0
var _step := 0
var _fails: Array = []
var _start := Vector3.ZERO
var _done := false

func setup(colliders: Node) -> void:
	for body in colliders.get_children():
		var n := String(body.name)
		if not (n.begins_with("Grove") or n.begins_with("DeadTree")):
			continue
		var c := (body as Node3D).global_position
		var r := 0.0
		for cs in body.get_children():
			var sh := (cs as CollisionShape3D).shape as CylinderShape3D
			r = maxf(r, Vector2((cs as Node3D).position.x, (cs as Node3D).position.z).length() + sh.radius)
		_targets.append([n, Vector3(c.x, 0, c.z), r])
	_probe = CharacterBody3D.new()
	_probe.collision_layer = 2
	_probe.collision_mask = 1
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.5
	cap.height = 2.2
	cs.shape = cap
	cs.position.y = 1.1
	_probe.add_child(cs)
	add_child(_probe)
	print("TREETEST: целей ", _targets.size())
	_begin()

func _begin() -> void:
	var t: Array = _targets[_i]
	var a := TAU * float(_dir) / float(DIRS) + 0.3
	var d := Vector3(sin(a), 0, cos(a))
	_start = t[1] + d * (float(t[2]) + 1.5)
	_probe.global_position = _start + Vector3(0, 0.05, 0)
	_probe.velocity = Vector3.ZERO
	_step = 0

func _physics_process(_delta: float) -> void:
	if _done or _targets.is_empty():
		return
	for k in 32:
		_tick()
		if _done:
			return

func _tick() -> void:
	var t: Array = _targets[_i]
	var center: Vector3 = t[1]
	var to := center - _probe.global_position
	to.y = 0.0
	var dt := 1.0 / 60.0
	_probe.velocity = to.normalized() * RUN_SPEED if to.length() > 0.05 else Vector3.ZERO
	_probe.velocity.y = -2.0
	# move_and_collide с ручным скольжением, как move_and_slide, но с фиксированным шагом
	var motion := _probe.velocity * dt
	for s in 4:
		var col := _probe.move_and_collide(motion)
		if col == null:
			break
		motion = col.get_remainder().slide(col.get_normal())
	_step += 1
	if _step < STEPS:
		return
	var from := _start - center
	from.y = 0.0
	var pos := _probe.global_position - center
	pos.y = 0.0
	# прошёл насквозь — оказался по другую сторону центра или у самого центра
	if pos.dot(from.normalized()) < 0.3:
		_fails.append("%s угол %d: дошёл до %.1f м от центра" % [t[0], _dir, pos.length()])
	_dir += 1
	if _dir >= DIRS:
		_dir = 0
		_i += 1
	if _i >= _targets.size():
		_done = true
		print("TREETEST: проверено %d деревьев/рощ × %d сторон, сквозь прошёл %d раз" % [_targets.size(), DIRS, _fails.size()])
		for f in _fails:
			print("TREETEST FAIL ", f)
		print("TREETEST: ", "OK" if _fails.is_empty() else "ПРОВАЛ")
		get_tree().quit()
		return
	_begin()
