class_name ModelFactory
extends RefCounted
## Сборка 3D-моделей героев и врагов из пакетов KayKit:
## видимость оружия, перекраска (жрец, расы), зацикливание анимаций.

const LOOPING := ["Idle", "Idle_B", "Idle_Combat", "Running_A", "Running_B", "Running_C",
	"Walking_A", "Walking_B", "Walking_C", "Walking_Backwards", "Walking_D_Skeletons",
	"Running_Strafe_Left", "Running_Strafe_Right", "Spellcasting", "Unarmed_Idle",
	"2H_Melee_Idle", "Blocking", "Jump_Idle", "Lie_Idle", "1H_Ranged_Aiming", "2H_Ranged_Aiming"]

static var _scene_cache: Dictionary = {}
static var _material_cache: Dictionary = {}
static var _looped: Dictionary = {}

static func _scene(path: String) -> PackedScene:
	if not _scene_cache.has(path):
		_scene_cache[path] = load(path)
	return _scene_cache[path]

## Герой: возвращает Node3D, смотрящий вдоль -Z; AnimationPlayer доступен через find_anim().
static func build_hero(class_id: String, race_id: String) -> Node3D:
	var cls: Dictionary = GameData.CLASSES[class_id]
	var race: Dictionary = GameData.RACES[race_id]
	var holder := Node3D.new()
	holder.name = "Model"
	var inst := _scene("res://assets/heroes/%s.glb" % cls["model"]).instantiate() as Node3D
	inst.rotation.y = PI
	holder.add_child(inst)
	holder.scale = race.get("scale", Vector3.ONE)

	var skel := inst.find_child("Skeleton3D", true, false) as Skeleton3D
	if skel:
		for att in skel.get_children():
			if att is BoneAttachment3D and att.bone_name.begins_with("handslot"):
				for m in att.get_children():
					(m as Node3D).visible = cls["show"].has(m.name)
	for hide_name in cls["hide"]:
		var n := inst.find_child(hide_name, true, false)
		if n:
			(n as Node3D).visible = false

	var recolor_key := "%s|%s|%s" % [cls["model"], cls["recolor"], race.get("skin", "")]
	if cls["recolor"] != "" or race.get("skin", "") != "":
		_apply_recolor(inst, recolor_key, cls["recolor"], race.get("skin", ""))
	_setup_anims(inst)
	return holder

## Враг: модель скелета с оружием в руках.
static func build_mob(mob_id: String) -> Node3D:
	var def: Dictionary = GameData.MOBS[mob_id]
	var holder := Node3D.new()
	var inst := _scene("res://assets/enemies/%s.glb" % def["model"]).instantiate() as Node3D
	inst.rotation.y = PI
	holder.add_child(inst)
	holder.scale = Vector3.ONE * float(def.get("scale", 1.0))
	var skel := inst.find_child("Skeleton3D", true, false) as Skeleton3D
	if skel:
		if not Net.cli.has("nomerge"):
			_merge_skinned_parts(skel, def["model"])
		var weapons: Dictionary = def.get("weapons", {})
		for side in weapons:
			var att := BoneAttachment3D.new()
			att.bone_name = "handslot.%s" % side
			skel.add_child(att)
			att.add_child(_scene("res://assets/enemies/weapons/%s.gltf" % weapons[side]).instantiate())
	_setup_anims(inst)
	return holder

## Части тела KayKit (руки, ноги, голова…) — отдельные меши на одном скелете.
## Склеиваем их в один меш: ~10 вызовов отрисовки на моба превращаются в 1.
static var _merged: Dictionary = {}

static func _merge_skinned_parts(skel: Skeleton3D, key: String) -> void:
	var parts: Array = []
	for c in skel.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).skin != null:
			parts.append(c)
	if parts.size() < 2:
		return
	if not _merged.has(key):
		# Склеиваем массивы вручную: важно сохранить кости и веса (иначе модель застынет в T-позе).
		var verts := PackedVector3Array()
		var normals := PackedVector3Array()
		var tangents := PackedFloat32Array()
		var uvs := PackedVector2Array()
		var bones := PackedInt32Array()
		var weights := PackedFloat32Array()
		var indices := PackedInt32Array()
		var has_tangents := true
		var mat: Material = null
		for p: MeshInstance3D in parts:
			for s in p.mesh.get_surface_count():
				var a := p.mesh.surface_get_arrays(s)
				var base := verts.size()
				verts.append_array(a[Mesh.ARRAY_VERTEX])
				normals.append_array(a[Mesh.ARRAY_NORMAL])
				if a[Mesh.ARRAY_TANGENT] != null:
					tangents.append_array(a[Mesh.ARRAY_TANGENT])
				else:
					has_tangents = false
				uvs.append_array(a[Mesh.ARRAY_TEX_UV])
				bones.append_array(a[Mesh.ARRAY_BONES])
				weights.append_array(a[Mesh.ARRAY_WEIGHTS])
				for i: int in a[Mesh.ARRAY_INDEX]:
					indices.append(i + base)
				if mat == null:
					mat = p.mesh.surface_get_material(s)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		if has_tangents:
			arrays[Mesh.ARRAY_TANGENT] = tangents
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_BONES] = bones
		arrays[Mesh.ARRAY_WEIGHTS] = weights
		arrays[Mesh.ARRAY_INDEX] = indices
		var merged := ArrayMesh.new()
		merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		merged.surface_set_material(0, mat)
		_merged[key] = merged
	var first: MeshInstance3D = parts[0]
	var mi := MeshInstance3D.new()
	mi.name = "MergedBody"
	mi.mesh = _merged[key]
	mi.skin = first.skin
	mi.skeleton = NodePath("..")   # без этого модель не привязана к костям и стоит в T-позе
	skel.add_child(mi)
	for p in parts:
		skel.remove_child(p)
		p.free()

static func find_anim(model: Node) -> AnimationPlayer:
	return model.find_child("AnimationPlayer", true, false) as AnimationPlayer

static func _setup_anims(inst: Node) -> void:
	var ap := find_anim(inst)
	if ap == null:
		return
	var lib := ap.get_animation_library("")
	if lib == null or _looped.has(lib.get_instance_id()):
		return
	_looped[lib.get_instance_id()] = true
	for n in LOOPING:
		if lib.has_animation(n):
			lib.get_animation(n).loop_mode = Animation.LOOP_LINEAR

# ---------------------------------------------------------------- перекраска

static func _apply_recolor(inst: Node, key: String, scheme: String, skin: String) -> void:
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		for s in m.mesh.get_surface_count():
			var src := m.mesh.surface_get_material(s) as StandardMaterial3D
			if src == null or src.albedo_texture == null:
				continue
			var mkey := key + "|" + str(src.get_instance_id())
			if not _material_cache.has(mkey):
				var mat := src.duplicate() as StandardMaterial3D
				mat.albedo_texture = _recolor_texture(src.albedo_texture, scheme, skin)
				_material_cache[mkey] = mat
			m.set_surface_override_material(s, _material_cache[mkey])

static func _recolor_texture(tex: Texture2D, scheme: String, skin: String) -> Texture2D:
	var img := tex.get_image()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	# Атлас KayKit — крупные градиентные плашки, 256px достаточно и в 16 раз быстрее.
	img.resize(256, 256, Image.INTERPOLATE_BILINEAR)
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var h := c.h
			var s := c.s
			var v := c.v
			var out := c
			var is_skin := h > 0.03 and h < 0.11 and s > 0.18 and s < 0.55 and v > 0.75
			if scheme == "priest" and not is_skin:
				if s > 0.2 and h > 0.6 and h < 0.8:
					# фиолетовая мантия -> белоснежная с тёплым оттенком
					out = Color.from_hsv(0.11, 0.06 + s * 0.12, clampf(v * 0.6 + 0.5, 0.0, 1.0))
				elif s > 0.45 and (h > 0.85 or h < 0.02):
					# малиновые вставки -> золото
					out = Color.from_hsv(0.12, 0.7, clampf(v * 0.9 + 0.25, 0.0, 1.0))
			if is_skin:
				if skin == "pale":
					out = Color.from_hsv(0.08, s * 0.55, clampf(v * 1.05, 0.0, 1.0))
				elif skin == "blue":
					out = Color.from_hsv(0.66, s * 0.9, v * 0.92)
			img.set_pixel(x, y, out)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
