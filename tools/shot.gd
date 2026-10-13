extends SceneTree
## Снимок сцены в PNG для быстрой визуальной проверки.
## godot --script res://tools/shot.gd -- <scene> <out.png> <cam x,y,z> <look x,y,z> [fov]

func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var scene := (load(a[0]) as PackedScene).instantiate()
	root.add_child(scene)
	var cam := Camera3D.new()
	root.add_child(cam)
	var cp := a[2].split_floats(",")
	var lp := a[3].split_floats(",")
	var from := Vector3(cp[0], cp[1], cp[2])
	cam.look_at_from_position(from, Vector3(lp[0], lp[1], lp[2]))
	cam.fov = float(a[4]) if a.size() > 4 else 60.0
	cam.far = 600.0
	cam.make_current()
	for i in 12:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(a[1])
	print("saved ", a[1])
	quit()
