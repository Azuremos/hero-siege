extends SceneTree
# Печатает габариты (AABB) моделей — для подбора масштабов карты.

func _aabb(n: Node, xf: Transform3D, acc: Array) -> void:
	var t := xf
	if n is Node3D:
		t = xf * (n as Node3D).transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh:
		var a: AABB = t * (n as MeshInstance3D).get_aabb()
		if acc[0] == null:
			acc[0] = a
		else:
			acc[0] = (acc[0] as AABB).merge(a)
	for c in n.get_children():
		_aabb(c, t, acc)

func _init() -> void:
	var files := OS.get_cmdline_user_args()
	for f in files:
		var ps := load(f) as PackedScene
		if ps == null:
			print(f, " -> FAILED")
			continue
		var inst := ps.instantiate()
		var acc := [null]
		_aabb(inst, Transform3D.IDENTITY, acc)
		var a: AABB = acc[0]
		print(f.get_file(), "  size=", a.size, "  pos=", a.position)
		inst.free()
	quit()
