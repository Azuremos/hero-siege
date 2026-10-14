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

## Враг: модель скелета с оружием в руках или (src «hero») модель героя KayKit на той же схеме костей —
## с перекраской под фракцию, своим оружием в руках и масштабом.
static func build_mob(mob_id: String) -> Node3D:
	var def: Dictionary = GameData.MOBS[mob_id]
	var holder := Node3D.new()
	var from_hero: bool = def.get("src", "enemy") == "hero"
	var path := ("res://assets/heroes/%s.glb" if from_hero else "res://assets/enemies/%s.glb") % def["model"]
	var inst := _scene(path).instantiate() as Node3D
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
		for att in skel.get_children():
			if att is BoneAttachment3D and from_hero:
				for item in att.get_children():
					var hand: bool = att.bone_name.begins_with("handslot")
					(item as Node3D).visible = def.get("show", []).has(item.name) if hand else not def.get("hide", []).has(item.name)
		if def.get("recolor", "") != "":
			_apply_recolor(inst, "%s|%s|" % [def["model"], def["recolor"]], def["recolor"], "")
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
				if FACTION_SCHEMES.has(scheme) and FACTION_SCHEMES[scheme].has("glow"):
					# тлеющее свечение (инфернал, бесы): своя подсветка, без источников света
					mat.emission_enabled = true
					mat.emission = FACTION_SCHEMES[scheme]["glow"]
					mat.emission_energy_multiplier = 0.12
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
			if scheme == "smith" and not is_skin and s > 0.18 and h > 0.42 and h < 0.75:
				# синяя одежда варвара -> закопчённая кожа фартука
				out = Color.from_hsv(0.075, clampf(s * 0.75, 0.3, 0.65), v * 0.6)
			if scheme == "priest" and not is_skin:
				if s > 0.2 and h > 0.6 and h < 0.8:
					# фиолетовая мантия -> белоснежная с тёплым оттенком
					out = Color.from_hsv(0.11, 0.06 + s * 0.12, clampf(v * 0.6 + 0.5, 0.0, 1.0))
				elif s > 0.45 and (h > 0.85 or h < 0.02):
					# малиновые вставки -> золото
					out = Color.from_hsv(0.12, 0.7, clampf(v * 0.9 + 0.25, 0.0, 1.0))
			if FACTION_SCHEMES.has(scheme):
				out = _faction_pixel(FACTION_SCHEMES[scheme], c, h, s, v, is_skin)
			if is_skin:
				if skin == "pale":
					out = Color.from_hsv(0.08, s * 0.55, clampf(v * 1.05, 0.0, 1.0))
				elif skin == "blue":
					out = Color.from_hsv(0.66, s * 0.9, v * 0.92)
			img.set_pixel(x, y, out)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

## Перекрасить готовую модель по схеме (например, «smith» — кузнец в кожаном фартуке).
static func recolor_model(inst: Node, model_name: String, scheme: String) -> void:
	_apply_recolor(inst, "%s|%s|" % [model_name, scheme], scheme, "")

# ---------------------------------------------------------------- облики фракций
## Временные облики орков, демонов, гоблинов и огров — перекраска моделей KayKit.
## Группы пикселей атласа: skin — кожа, blue / purple / red — ткань этих оттенков, bone — светлые
## ненасыщенные (кости скелетов, белая ткань), metal — серые средней яркости.
## Правило: [оттенок, насыщенность, множитель яркости]; glow — свечение материала.
const FACTION_SCHEMES := {
	"orc": {"skin": [0.27, 0.5, 0.8], "blue": [0.01, 0.6, 0.55]},
	"orc_chief": {"skin": [0.27, 0.5, 0.78], "blue": [0.0, 0.75, 0.6], "metal": [0.08, 0.35, 0.8]},
	"orc_shaman": {"skin": [0.27, 0.5, 0.8], "purple": [0.08, 0.55, 0.55], "red": [0.33, 0.6, 0.6]},
	"imp": {"skin": [0.02, 0.8, 0.9], "blue": [0.0, 0.6, 0.3], "bone": [0.05, 0.5, 0.5], "glow": Color(1.0, 0.3, 0.05)},
	"demon": {"skin": [0.0, 0.75, 0.7], "metal": [0.98, 0.45, 0.45], "blue": [0.0, 0.8, 0.35], "bone": [0.02, 0.4, 0.45], "red": [0.06, 0.9, 0.9]},
	"succubus": {"skin": [0.9, 0.35, 0.95], "blue": [0.82, 0.6, 0.35], "purple": [0.82, 0.6, 0.4], "red": [0.85, 0.7, 0.7]},
	"goblin": {"skin": [0.2, 0.6, 0.9], "blue": [0.08, 0.5, 0.5], "purple": [0.08, 0.5, 0.5]},
	"goblin_tinker": {"skin": [0.2, 0.6, 0.9], "blue": [0.07, 0.8, 0.8], "purple": [0.07, 0.8, 0.8]},
	"ogre": {"skin": [0.55, 0.2, 0.75], "blue": [0.07, 0.45, 0.45], "purple": [0.07, 0.45, 0.45], "red": [0.07, 0.5, 0.5]},
	"necro": {"purple": [0.36, 0.65, 0.45], "blue": [0.36, 0.65, 0.45], "red": [0.36, 0.7, 0.6]},
	"ghoul": {"bone": [0.22, 0.32, 0.72], "metal": [0.22, 0.3, 0.6]},
	"banshee": {"bone": [0.52, 0.3, 1.05], "purple": [0.55, 0.4, 0.9], "blue": [0.55, 0.4, 0.9], "metal": [0.55, 0.3, 0.9]},
	"felhound": {"bone": [0.0, 0.75, 0.55], "metal": [0.98, 0.6, 0.4]},
	"infernal": {"bone": [0.04, 0.35, 0.32], "metal": [0.05, 0.5, 0.4], "glow": Color(1.0, 0.35, 0.05)},
}

static func _faction_pixel(rules: Dictionary, c: Color, h: float, s: float, v: float, is_skin: bool) -> Color:
	var key := ""
	# у скелетов кожи нет: тёплые светлые пиксели — это кости
	if is_skin and rules.has("skin"):
		key = "skin"
	elif s < (0.3 if not rules.has("skin") else 0.16) and v > 0.55:
		key = "bone"
	elif s < 0.16 and v > 0.22:
		key = "metal"
	elif s > 0.2 and h > 0.42 and h < 0.72:
		key = "blue"
	elif s > 0.2 and h >= 0.72 and h < 0.92:
		key = "purple"
	elif s > 0.35 and (h >= 0.92 or h < 0.03):
		key = "red"
	if key == "" or not rules.has(key):
		return c
	var r: Array = rules[key]
	return Color.from_hsv(float(r[0]), float(r[1]), clampf(v * float(r[2]), 0.0, 1.0), c.a)
