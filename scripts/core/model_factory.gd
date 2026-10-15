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
	if def.get("src", "enemy") == "monster":
		_build_monster(def, mob_id, holder)
		holder.scale = Vector3.ONE * float(def.get("scale", 1.0))
		return holder
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

# ---------------------------------------------------------------- оружие героя по надетой вещи
## Рука героя KayKit (handslot.r / handslot.l): если look не пуст — родные предметы модели в этой руке прячутся
## и в руку ставится модель вещи (оттенок металла по ступени, свечение по качеству). Пустой look — облик класса
## по умолчанию: видны предметы из defaults (show класса).
static func set_hand_item(model: Node3D, side: String, look: Dictionary, defaults: Array) -> void:
	var skel := model.find_child("Skeleton3D", true, false) as Skeleton3D
	if skel == null:
		return
	for att in skel.get_children():
		if not (att is BoneAttachment3D and att.bone_name == "handslot." + side):
			continue
		var old := att.get_node_or_null("ItemWeapon")
		if old:
			att.remove_child(old)
			old.queue_free()
		for m in att.get_children():
			(m as Node3D).visible = look.is_empty() and defaults.has(m.name)
		if look.is_empty():
			return
		var w := weapon_scene(look["model"]).instantiate() as Node3D
		w.name = "ItemWeapon"
		w.scale = Vector3.ONE * 0.8      # оружие Fantasy Weapons Bits крупнее родного оружия героев KayKit
		att.add_child(w)
		var q: int = look["q"]
		var key := "item|%s|%s|%d" % [look["model"], str(look["tint"]), q]
		for mi in w.find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			for s in m.mesh.get_surface_count():
				m.set_surface_override_material(s, _item_material(key + "|" + str(s), m.mesh.surface_get_material(s), look["tint"], q))
		if q >= 4:
			w.add_child(_legend_sparks())
		return

static func _item_material(key: String, src: Material, tint: Color, q: int) -> Material:
	if _material_cache.has(key):
		return _material_cache[key]
	var mat := (src.duplicate() if src is StandardMaterial3D else StandardMaterial3D.new()) as StandardMaterial3D
	mat.albedo_color = mat.albedo_color * tint
	var glow: Color = GameData.ItemData.QUALITY_GLOW.get(q, Color.BLACK)
	if q == 3:
		mat.albedo_color = mat.albedo_color.lerp(Color(0.45, 0.25, 0.95), 0.45)   # эпическое — фиолетовое, не розовое
	if q >= 3:
		mat.emission_enabled = true
		mat.emission = glow
		mat.emission_energy_multiplier = 0.45 if q == 3 else 0.8
	_material_cache[key] = mat
	return mat

## Искры легендарного оружия: немного частиц на GPU.
static func _legend_sparks() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "LegendSparks"
	p.amount = 12
	p.lifetime = 0.9
	p.local_coords = false
	p.position.y = 0.5
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(0.08, 0.4, 0.08)
	pm.gravity = Vector3(0, 0.6, 0)
	pm.initial_velocity_min = 0.05
	pm.initial_velocity_max = 0.25
	pm.color = Color(1.0, 0.7, 0.25)
	p.process_material = pm
	var qm := QuadMesh.new()
	qm.size = Vector2(0.06, 0.06)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	sm.vertex_color_use_as_albedo = true
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	qm.material = sm
	p.draw_pass_1 = qm
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p

# ---------------------------------------------------------------- монстры (src «monster»)
## Модели Quaternius: своя схема костей и свои анимации (MobData.MODELS, ANIM_SETS).
## Части тела с разными материалами склеиваются в один меш, цвет материала — в вершинах:
## один вызов отрисовки на моба, перекраска фракции — заменой цвета материала (mats в данных моба).
static func _build_monster(def: Dictionary, mob_id: String, holder: Node3D) -> void:
	var mdl: Dictionary = GameData.MONSTER_MODELS[def["model"]]
	var inst := _scene("res://assets/monsters/%s.glb" % def["model"]).instantiate() as Node3D
	inst.scale = Vector3.ONE * float(mdl["fit"])
	inst.position.y = float(mdl.get("lift", 0.0))
	inst.rotation_degrees.y = 180.0 + float(mdl.get("yaw", 0.0))   # как у KayKit: модель смотрит вдоль +Z
	holder.add_child(inst)
	var skel := inst.find_child("Skeleton3D", true, false) as Skeleton3D
	for hide_name: String in def.get("hide", []):
		var h := skel.find_child(hide_name, true, false)
		if h:
			skel.remove_child(h)
			h.free()
	if Net.cli.has("nomerge") or not _merge_monster(skel, mob_id, def):
		for mi in skel.find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			for s in m.mesh.get_surface_count():
				m.set_surface_override_material(s, _monster_material(mob_id + "|" + str(s) + m.name, def, m.mesh.surface_get_material(s), true))
	# у моделей Quaternius у арматуры масштаб 100 — оружие задаём в единицах героя
	var arm := 1.0
	var pn: Node = skel
	while pn != inst:
		if pn is Node3D:
			arm *= (pn as Node3D).scale.x
		pn = pn.get_parent()
	var weapons: Dictionary = def.get("weapons", {})
	for side: String in weapons:
		var grip: Dictionary = mdl["grip_" + side]
		var att := BoneAttachment3D.new()
		att.bone_name = grip["bone"]
		skel.add_child(att)
		var w := weapon_scene(weapons[side]).instantiate() as Node3D
		w.position = grip["pos"] / (arm * float(mdl["fit"]))
		w.rotation_degrees = def.get("grip_rot", grip["rot"])
		w.scale = Vector3.ONE * float(grip["scale"]) * float(def.get("weapon_scale", 1.0)) / (arm * float(mdl["fit"]))
		att.add_child(w)
	_setup_monster_anims(inst, mdl)

## Оружие KayKit: Fantasy Weapons Bits (assets/weapons) или оружие скелетов (assets/enemies/weapons).
static func weapon_scene(wname: String) -> PackedScene:
	var p := "res://assets/weapons/%s.gltf" % wname
	return _scene(p if ResourceLoader.exists(p) else "res://assets/enemies/weapons/%s.gltf" % wname)

## Цвет части (альфа — сила свечения из glow: {материал: 0…1}).
static func _monster_color(def: Dictionary, src: Material) -> Color:
	var mname := src.resource_name if src else ""
	var mats: Dictionary = def.get("mats", {})
	var c: Color
	if mats.has(mname):
		c = mats[mname]
	else:
		var base := (src as StandardMaterial3D).albedo_color if src is StandardMaterial3D else Color.WHITE
		c = base * def.get("tint", Color.WHITE)
	c.a = float(def.get("glow", {}).get(mname, 0.0))
	return c

static var _monster_shader: Shader = null

## Материал склеенного меша — общий шейдер монстров (shaders/monster.gdshader): цвет и свечение из вершин,
## текстура атласа, если была. Без склейки (--nomerge) — обычный матовый материал на каждую часть.
static func _monster_material(key: String, def: Dictionary, src: Material, flat: bool) -> Material:
	if _material_cache.has(key):
		return _material_cache[key]
	var tex: Texture2D = (src as StandardMaterial3D).albedo_texture if src is StandardMaterial3D else null
	var out: Material
	if flat:
		var mat := StandardMaterial3D.new()
		mat.roughness = 1.0
		mat.albedo_texture = tex
		var c := _monster_color(def, src)
		mat.albedo_color = Color(c.r, c.g, c.b)
		if c.a > 0.0:
			mat.emission_enabled = true
			mat.emission = Color(c.r, c.g, c.b)
			mat.emission_energy_multiplier = c.a * 1.5
		out = mat
	else:
		if _monster_shader == null:
			_monster_shader = load("res://shaders/monster.gdshader")
		var sm := ShaderMaterial.new()
		sm.shader = _monster_shader
		sm.set_shader_parameter("use_tex", tex != null)
		sm.set_shader_parameter("tex", tex)
		out = sm
	_material_cache[key] = out
	return out

static func _merge_monster(skel: Skeleton3D, key: String, def: Dictionary) -> bool:
	var parts: Array = []
	for c in skel.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).skin != null:
			parts.append(c)
	if parts.is_empty():
		return false
	var first: MeshInstance3D = parts[0]
	if not _merged.has(key):
		# у частей могут быть разные Skin (тело и оружие) — переводим индексы костей в Skin первой части
		var skin0: Skin = first.skin
		var bind_of := {}
		for i in skin0.get_bind_count():
			bind_of[skin0.get_bind_name(i) if skin0.get_bind_name(i) != &"" else str(skin0.get_bind_bone(i))] = i
		var verts := PackedVector3Array()
		var normals := PackedVector3Array()
		var uvs := PackedVector2Array()
		var colors := PackedColorArray()
		var bones := PackedInt32Array()
		var weights := PackedFloat32Array()
		var indices := PackedInt32Array()
		var tex_mat: Material = null
		for p: MeshInstance3D in parts:
			var remap := PackedInt32Array()
			for i in p.skin.get_bind_count():
				var bn: String = p.skin.get_bind_name(i) if p.skin.get_bind_name(i) != &"" else str(p.skin.get_bind_bone(i))
				remap.append(int(bind_of.get(bn, 0)))
			for s in p.mesh.get_surface_count():
				var a := p.mesh.surface_get_arrays(s)
				var src_mat := p.mesh.surface_get_material(s)
				if p.get_surface_override_material(s):
					src_mat = p.get_surface_override_material(s)
				if src_mat is StandardMaterial3D and (src_mat as StandardMaterial3D).albedo_texture:
					tex_mat = src_mat
				var n: int = (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
				var b: PackedInt32Array = a[Mesh.ARRAY_BONES]
				if b.size() != n * 4:
					return false      # 8 весов на вершину — не склеиваем
				var base := verts.size()
				verts.append_array(a[Mesh.ARRAY_VERTEX])
				normals.append_array(a[Mesh.ARRAY_NORMAL])
				if a[Mesh.ARRAY_TEX_UV] != null:
					uvs.append_array(a[Mesh.ARRAY_TEX_UV])
				else:
					var z := PackedVector2Array()
					z.resize(n)
					uvs.append_array(z)
				var col := _monster_color(def, src_mat)
				for i in n:
					colors.append(col)
				for i in b.size():
					bones.append(remap[b[i]] if b[i] < remap.size() else 0)
				weights.append_array(a[Mesh.ARRAY_WEIGHTS])
				for i: int in a[Mesh.ARRAY_INDEX]:
					indices.append(i + base)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_BONES] = bones
		arrays[Mesh.ARRAY_WEIGHTS] = weights
		arrays[Mesh.ARRAY_INDEX] = indices
		var merged := ArrayMesh.new()
		merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		merged.surface_set_material(0, _monster_material(key + "|merged", def, tex_mat, false))
		_merged[key] = merged
	var mi := MeshInstance3D.new()
	mi.name = "MergedBody"
	mi.mesh = _merged[key]
	mi.skin = first.skin
	mi.skeleton = NodePath("..")
	skel.add_child(mi)
	for p in parts:
		skel.remove_child(p)
		p.free()
	return true

## Короткие имена анимаций («CharacterArmature|Run» → «Run») и зацикливание — один раз на библиотеку.
static func _setup_monster_anims(inst: Node, mdl: Dictionary) -> void:
	var ap := find_anim(inst)
	if ap == null:
		return
	var lib := ap.get_animation_library("")
	if lib == null or _looped.has(lib.get_instance_id()):
		return
	_looped[lib.get_instance_id()] = true
	for n: StringName in lib.get_animation_list():
		var short := String(n).get_slice("|", String(n).get_slice_count("|") - 1)
		if not lib.has_animation(short):
			lib.add_animation(short, lib.get_animation(n))
	var aset: Dictionary = GameData.ANIM_SETS[mdl["set"]]
	for k in ["idle", "run"]:
		if lib.has_animation(aset[k]):
			lib.get_animation(aset[k]).loop_mode = Animation.LOOP_LINEAR

## Анимация KayKit, которую просит логика мобов («Running_A», «2H_Melee_Attack_Chop»…) → анимация монстра.
## Сначала по действию (бег, удар, каст…), затем замены из данных моба (anims).
static var _anim_alias: Dictionary = {}

static func monster_anim(mob_id: String, kaykit_name: String) -> String:
	var key := mob_id + "|" + kaykit_name
	if _anim_alias.has(key):
		return _anim_alias[key]
	var def: Dictionary = GameData.MOBS[mob_id]
	var aset: Dictionary = GameData.ANIM_SETS[GameData.MONSTER_MODELS[def["model"]]["set"]]
	var act := "idle"
	var n := kaykit_name
	if n.begins_with("Death"):
		act = "death"
	elif n.begins_with("Hit"):
		act = "hit"
	elif n.begins_with("Running") or n.begins_with("Walking"):
		act = "run"
	elif "Attack" in n or "Shoot" in n or n == "Throw":
		act = "attack"
	elif n.begins_with("Spellcast") or n == "Interact":
		act = "cast"
	elif n == "Cheer" or n.begins_with("Spawn"):
		act = "spawn"
	var over: Dictionary = def.get("anims", {})
	var out: String = over.get(act, aset.get(act, aset["idle"]))
	_anim_alias[key] = out
	return out

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
