extends Node3D
## Иконки врагов для окна Вербовщика («Война линий»): снимок модели каждого врага из sends.gd — портрет 96×96.
## Запуск: Godot --path . -- --mobicons=res://assets/icons/mobs   (из главного меню вместо него, нужен рендер — без --headless)
## Модели — те же, что в игре (KayKit, Quaternius), поэтому иконки под той же лицензией, что и модели.

const SIZE := 96

func _ready() -> void:
	var out_dir: String = str(Net.cli["mobicons"])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var ids: Array = []
	for sid in GameData.SendData.SENDS:
		var mob: String = GameData.SendData.SENDS[sid]["mob"]
		if not ids.has(mob):
			ids.append(mob)
	var vp := SubViewport.new()
	vp.size = Vector2i(SIZE * 2, SIZE * 2)
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_CLEAR_COLOR
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.7, 0.7, 0.75)
	e.ambient_light_energy = 0.7
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, 160, 0)
	sun.light_energy = 1.4
	vp.add_child(sun)
	var cam := Camera3D.new()
	cam.fov = 30.0
	vp.add_child(cam)
	cam.current = true
	for mid: String in ids:
		var m := ModelFactory.build_mob(mid)
		vp.add_child(m)
		m.rotation_degrees.y = 0.0
		var ap := ModelFactory.find_anim(m)
		if ap:
			var md: Dictionary = GameData.MOBS[mid]
			ap.play(ModelFactory.monster_anim(mid, "Idle") if md.get("src", "enemy") == "monster" else "Idle")
		# кадр по габаритам модели: голова и плечи крупно
		var box := _bounds(m)
		var h := maxf(box.size.y, 0.5)
		var top := box.position.y + h
		var focus := Vector3(box.get_center().x, top - h * 0.36, box.get_center().z)
		var dist := h * 0.42 / tan(deg_to_rad(cam.fov * 0.5)) + maxf(box.size.x, box.size.z) * 0.3
		# модели смотрят в сторону −Z: камера спереди
		cam.look_at_from_position(focus + Vector3(dist * 0.35, h * 0.1, -dist), focus)
		for i in 6:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		img.resize(SIZE, SIZE, Image.INTERPOLATE_LANCZOS)
		var path := "%s/%s.png" % [out_dir, mid]
		img.save_png(path)
		print("icon ", path)
		m.queue_free()
		await get_tree().process_frame
	Sfx.quit_game()

func _bounds(root: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var gi := mi as MeshInstance3D
		if gi.mesh == null or not gi.is_visible_in_tree():
			continue
		var bb: AABB = gi.global_transform * gi.mesh.get_aabb()
		box = bb if first else box.merge(bb)
		first = false
	return box
