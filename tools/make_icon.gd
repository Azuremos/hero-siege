extends Node3D
## Иконка игры: снимок замка KayKit (CC0) на прозрачном фоне -> assets/icon/icon.png и icon.ico (16–256 пикселей).
## Запуск: Godot --path . -- --makeicon   (из главного меню вместо него; нужен рендер — без --headless)
## ICO собирается вручную: в каждом размере лежит PNG (так умеют Windows Vista и новее).

const SIZES := [16, 24, 32, 48, 64, 128, 256]

func _ready() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(512, 512)
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_CLEAR_COLOR
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.78, 0.85)
	e.ambient_light_energy = 0.8
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, -35, 0)
	sun.light_energy = 1.3
	vp.add_child(sun)
	var castle := (load("res://assets/town/buildings/building_castle_blue.gltf") as PackedScene).instantiate() as Node3D
	vp.add_child(castle)
	castle.rotation_degrees.y = 30.0
	var cam := Camera3D.new()
	cam.fov = 30.0
	vp.add_child(cam)
	cam.current = true
	cam.look_at_from_position(Vector3(6.8, 4.4, 6.8), Vector3(0.35, 1.65, 0.35))
	for i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	var dir := "res://assets/icon"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var big := img.duplicate() as Image
	big.resize(256, 256, Image.INTERPOLATE_LANCZOS)
	big.save_png(dir + "/icon.png")
	var pngs: Array = []
	for s: int in SIZES:
		var im := img.duplicate() as Image
		im.resize(s, s, Image.INTERPOLATE_LANCZOS)
		pngs.append(im.save_png_to_buffer())
	var ico := PackedByteArray()
	ico.resize(6 + 16 * SIZES.size())
	ico.encode_u16(0, 0)
	ico.encode_u16(2, 1)
	ico.encode_u16(4, SIZES.size())
	var offset := ico.size()
	for i in SIZES.size():
		var o := 6 + 16 * i
		var s: int = SIZES[i]
		ico.encode_u8(o, 0 if s >= 256 else s)
		ico.encode_u8(o + 1, 0 if s >= 256 else s)
		ico.encode_u8(o + 2, 0)
		ico.encode_u8(o + 3, 0)
		ico.encode_u16(o + 4, 1)
		ico.encode_u16(o + 6, 32)
		ico.encode_u32(o + 8, (pngs[i] as PackedByteArray).size())
		ico.encode_u32(o + 12, offset)
		offset += (pngs[i] as PackedByteArray).size()
	for p: PackedByteArray in pngs:
		ico.append_array(p)
	var f := FileAccess.open(dir + "/icon.ico", FileAccess.WRITE)
	f.store_buffer(ico)
	f.close()
	print("icon saved: %s/icon.png, icon.ico (%d байт)" % [dir, ico.size()])
	Sfx.quit_game()
