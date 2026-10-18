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
	if skel:
		# без шлема видна голова: головной убор показывает только надетая вещь
		for att in skel.get_children():
			if att is BoneAttachment3D and att.bone_name == "head":
				for m in att.get_children():
					(m as Node3D).visible = false
	holder.set_meta("class_id", class_id)
	holder.set_meta("race_id", race_id)
	_setup_anims(inst)
	if cls.has("default_weapon") or cls.has("default_offhand"):
		apply_outfit(holder, class_id, {})      # оружие и левая рука по умолчанию — модели вещей (молот шамана, том жреца)
	return holder

static func _prim(mesh: Mesh, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	return mi

static var _mesh_cache: Dictionary = {}

## Усечённый конус по оси Y (низ — r1, верх — r2), общий на все модели.
static func _cone(r1: float, r2: float, h: float, seg: int) -> Mesh:
	var key := "cone|%s|%s|%s|%d" % [r1, r2, h, seg]
	if not _mesh_cache.has(key):
		var m := CylinderMesh.new()
		m.bottom_radius = r1
		m.top_radius = r2
		m.height = h
		m.radial_segments = seg
		m.rings = 1
		_mesh_cache[key] = m
	return _mesh_cache[key]

static func _capsule(r: float, h: float) -> Mesh:
	var key := "caps|%s|%s" % [r, h]
	if not _mesh_cache.has(key):
		var m := CapsuleMesh.new()
		m.radius = r
		m.height = h
		m.radial_segments = 10
		m.rings = 3
		_mesh_cache[key] = m
	return _mesh_cache[key]

static func _dome(r: float) -> Mesh:
	var key := "dome|%s" % r
	if not _mesh_cache.has(key):
		var m := SphereMesh.new()
		m.radius = r
		m.height = r
		m.is_hemisphere = true
		m.radial_segments = 14
		m.rings = 5
		_mesh_cache[key] = m
	return _mesh_cache[key]

static func _flat_material(key: String, col: Color, rough: float) -> StandardMaterial3D:
	if not _material_cache.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.roughness = rough
		_material_cache[key] = m
	return _material_cache[key]

# ---------------------------------------------------------------- облик по снаряжению
## Части других моделей героев KayKit («Knight/Knight_Helmet»): на всех моделях одна схема костей,
## поэтому шлем рыцаря садится на голову мага так же, как на свою. Шаблон узла кешируется, на героя — копия.
static var _donors: Dictionary = {}

static func _donor(spec: String) -> Node3D:
	if not _donors.has(spec):
		# храним ресурсы (меш, скин, положение), а не узел: узлы вне дерева утекли бы при выходе
		var p := spec.split("/")
		var inst := _scene("res://assets/heroes/%s.glb" % p[0]).instantiate()
		var src := inst.find_child(p[1], true, false) as MeshInstance3D
		_donors[spec] = {} if src == null else {"mesh": src.mesh, "skin": src.skin, "xf": src.transform}
		inst.free()
	var d: Dictionary = _donors[spec]
	if d.is_empty():
		return null
	var mi := MeshInstance3D.new()
	mi.mesh = d["mesh"]
	mi.skin = d["skin"]
	mi.transform = d["xf"]
	return mi

## Облик героя по надетым вещам: looks — {ячейка: ItemData.look(id)}. Пересобирается только при смене
## снаряжения (economy.ev_appearance). Пустая ячейка: оружие и левая рука — по умолчанию класса, голова открыта,
## плащ — родной, туловище и ноги — родного цвета.
static func apply_outfit(model: Node3D, class_id: String, looks: Dictionary) -> bool:
	var skel := model.find_child("Skeleton3D", true, false) as Skeleton3D
	if skel == null:
		return false
	var cls: Dictionary = GameData.CLASSES[class_id]
	var defaults: Array = cls["show"]
	for n: Node in model.get_meta("outfit_nodes", []):
		if is_instance_valid(n):
			n.get_parent().remove_child(n)
			n.queue_free()
	var added: Array = []
	# --- руки
	var main: Dictionary = looks.get("weapon", {})
	if not main.has("model") and cls.has("default_weapon"):
		# пустая правая рука: оружие класса по умолчанию — белая вещь шаблона default_weapon
		main = GameData.ItemData.look(GameData.make_gear(str(cls["default_weapon"]), 1, 0, 0))
	var off: Dictionary = looks.get("offhand", {})
	if not off.has("model") and cls.has("default_offhand"):
		# пустая левая рука: вещь класса по умолчанию (том жреца лежит в кисти, как надетый том)
		off = GameData.ItemData.look(GameData.make_gear(str(cls["default_offhand"]), 1, 0, 0))
	var two := bool(main.get("two_hand", false))
	set_hand_item(model, "r", main if main.has("model") else {}, defaults)
	var left_def: Array = [] if two else defaults
	set_hand_item(model, "l", off if (off.has("model") and not two) else {}, left_def)
	# --- голова, плащ, наплечники
	var helm: Dictionary = looks.get("helm", {})
	var hw: Dictionary = helm.get("wear", {})
	var chest: Dictionary = looks.get("chest", {})
	var cw: Dictionary = chest.get("wear", {})
	var hooded := str(hw.get("head", "")) == "hooded"
	for att in skel.get_children():
		if not att is BoneAttachment3D:
			continue
		var bn: String = att.bone_name
		if bn == "head":
			# без шлема видна голова: родные головные уборы модели показывает только надетая вещь
			for m in att.get_children():
				(m as Node3D).visible = false
			if helm.has("wear") and not hooded:
				var h := _donor(str(hw["head"]))
				if h:
					h.name = "OutfitHelm"
					h.scale *= float(hw.get("head_scale", 1.0))      # шапка варвара сделана под лысую голову — чуть больше, чтобы прятала волосы
					att.add_child(h)
					_tint_node(h, str(hw["head"]), helm["cloth"] if helm["base"] == "hat" else helm["tint"], int(helm["q"]), 0.35)
					added.append(h)
		elif bn == "chest":
			for m in att.get_children():
				(m as Node3D).visible = not cw.has("cape")
			if cw.has("cape"):
				var cape := _donor(str(cw["cape"]))
				if cape:
					cape.name = "OutfitCape"
					att.add_child(cape)
					_tint_node(cape, str(cw["cape"]), chest["cloth"], int(chest["q"]), 0.25)
					added.append(cape)
	# капюшон: голова-капюшон разбойника вместо родной головы (свой меш со скином на той же схеме костей)
	var own_head: MeshInstance3D = null
	for c in skel.get_children():
		if c is MeshInstance3D and str(c.name).ends_with("_Head"):
			own_head = c
	if own_head:
		own_head.visible = not hooded
	if hooded:
		var hd := _donor("Rogue_Hooded/Rogue_Head_Hooded") as MeshInstance3D
		if hd:
			hd.name = "OutfitHood"
			skel.add_child(hd)
			hd.skeleton = NodePath("..")
			var race: Dictionary = GameData.RACES[model.get_meta("race_id", "human")]
			if race.get("skin", "") != "":
				_apply_recolor(hd, "Rogue_Hooded|hood|" + str(race["skin"]), "", race["skin"])
			_tint_node(hd, "hood|" + str(race.get("skin", "")), Color.WHITE, int(helm["q"]), 0.2)   # лицо не красим — только свечение по качеству
			added.append(hd)
	var pads: Dictionary = looks.get("shoulders", {})
	if pads.has("wear"):
		# на кости груди, а не плеча: рука в анимациях вращается, а наплечник должен лежать на плече
		var att := BoneAttachment3D.new()
		att.name = "OutfitPads"
		att.bone_name = "chest"
		skel.add_child(att)
		for side in ["l", "r"]:
			_build_pad(skel, att, str(pads["wear"]["pads"]), pads, side)
		added.append(att)
	# --- туловище (доспех) и ноги (сапоги): цвет ткани или металла, свечение по качеству
	for c in skel.get_children():
		if not c is MeshInstance3D:
			continue
		var cn := str(c.name)
		if cn.ends_with("_Body"):
			_tint_body(c, chest, str(cw.get("body", "")))
		elif cn.ends_with("_LegLeft") or cn.ends_with("_LegRight"):
			var boots: Dictionary = looks.get("boots", {})
			_tint_body(c, boots, "boots" if boots.has("wear") else "")
	model.set_meta("outfit_nodes", added)
	return true

## Перекраска части тела: исходные материалы запоминаются при первом вызове, пустой kind — вернуть родные.
static func _tint_body(mi: MeshInstance3D, lk: Dictionary, kind: String) -> void:
	if not mi.has_meta("base_mats"):
		var base: Array = []
		for s in mi.mesh.get_surface_count():
			base.append(mi.get_surface_override_material(s))
		mi.set_meta("base_mats", base)
	var mats: Array = mi.get_meta("base_mats")
	for s in mi.mesh.get_surface_count():
		var src: Material = mats[s] if mats[s] != null else mi.mesh.surface_get_material(s)
		if kind == "":
			mi.set_surface_override_material(s, mats[s])
			continue
		var tint: Color = lk["tint"]
		match kind:
			"cloth": tint = lk["cloth"]
			"mail": tint = (lk["tint"] as Color) * 0.82
			"boots": tint = (lk["tint"] as Color).lerp(Color(0.75, 0.6, 0.45), 0.35)
		var key := "body|%d|%s|%s|%d" % [src.get_instance_id() if src else 0, kind, tint.to_html(), int(lk["q"])]
		mi.set_surface_override_material(s, _item_material(key, src, tint, int(lk["q"]), 0.15, false))

## Перекраска готовой части (шлем, плащ): все поверхности всех мешей узла.
static func _tint_node(n: Node, key: String, tint: Color, q: int, glow: float) -> void:
	var list: Array = n.find_children("*", "MeshInstance3D", true, false)
	if n is MeshInstance3D:
		list.append(n)
	for mi in list:
		var m := mi as MeshInstance3D
		for s in m.mesh.get_surface_count():
			var src: Material = m.get_surface_override_material(s) if m.get_surface_override_material(s) else m.mesh.surface_get_material(s)
			m.set_surface_override_material(s, _item_material("wear|%s|%s|%d|%d|%d" % [key, tint.to_html(), q, s, src.get_instance_id() if src else 0], src, tint, q, glow, false))

## Наплечники из примитивов на кости плеча: ткань — мягкий валик, кольчуга — двойная чешуя,
## латы — крупный купол с ободом, с синего — шип. Металл по ступени, ткань по качеству, свечение по качеству.
static func _build_pad(skel: Skeleton3D, att: Node3D, kind: String, lk: Dictionary, side: String) -> void:
	var q: int = lk["q"]
	var metal := _item_material("pad|metal|%s|%d" % [(lk["tint"] as Color).to_html(), q], null,
		Color(0.62, 0.64, 0.68) * (lk["tint"] as Color), q, 0.35, false) as StandardMaterial3D
	metal.metallic = 0.7
	metal.roughness = 0.35
	# место и наклон — из позы покоя скелета: над суставом плеча, купол вверх и чуть наружу
	var chest_rest := skel.get_bone_global_rest(skel.find_bone("chest"))
	var arm_rest := skel.get_bone_global_rest(skel.find_bone("upperarm." + side))
	var inv := chest_rest.basis.inverse()
	var up := (inv * Vector3.UP).normalized()
	var outward := (inv * Vector3(signf(arm_rest.origin.x), 0, 0)).normalized()
	var fwd := (inv * Vector3.BACK).normalized()
	var y := (up + outward * 0.5).normalized()
	var x := y.cross(fwd).normalized()
	var root := Node3D.new()
	root.transform = Transform3D(Basis(x, y, x.cross(y)), chest_rest.affine_inverse() * arm_rest.origin + up * 0.06 + outward * 0.1)
	root.scale = Vector3.ONE * 1.3
	att.add_child(root)
	match kind:
		"cloth":
			var cm := _item_material("pad|cloth|%s|%d" % [(lk["cloth"] as Color).to_html(), q], null, Color(0.55, 0.45, 0.7) * (lk["cloth"] as Color), q, 0.3, false)
			var d := _prim(_dome(0.24), cm)
			d.scale = Vector3(1.0, 0.75, 1.1)
			root.add_child(d)
			var rim := _prim(_capsule(0.06, 0.5), cm)
			rim.rotation_degrees = Vector3(0, 90, 90)
			rim.position = Vector3(0, -0.03, -0.14)
			root.add_child(rim)
		"mail":
			var d1 := _prim(_dome(0.25), metal)
			d1.scale = Vector3(1.0, 0.7, 1.1)
			root.add_child(d1)
			var d2 := _prim(_dome(0.22), metal)
			d2.scale = Vector3(1.05, 0.6, 1.1)
			d2.position = Vector3(0, -0.05, -0.1)
			root.add_child(d2)
		_:
			var d := _prim(_dome(0.3), metal)
			d.scale = Vector3(1.0, 0.8, 1.15)
			root.add_child(d)
			var rim := _prim(_cone(0.31, 0.31, 0.05, 14), metal)
			rim.scale = Vector3(1.0, 1.0, 1.15)
			root.add_child(rim)
			if q >= 2:
				var sp := _prim(_cone(0.07, 0.0, 0.3, 6), metal)
				sp.position = Vector3(0, 0.33, 0)
				root.add_child(sp)
	if q >= 4:
		root.add_child(_legend_sparks())

## Враг: модель скелета с оружием в руках или (src «hero») модель героя KayKit на той же схеме костей —
## с перекраской под фракцию, своим оружием в руках и масштабом.
static func build_mob(mob_id: String) -> Node3D:
	var def: Dictionary = GameData.MOBS[mob_id]
	var holder := Node3D.new()
	if def.get("src", "enemy") == "object":
		_build_object(def, holder)
		return holder
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
		var mdl: String = look["model"]
		var w: Node3D
		if mdl == "orb":
			w = _orb(look)
		elif mdl.contains("/"):
			w = _donor(mdl)          # щит рыцаря — уже на своём месте в руке
			if w and mdl.begins_with("Mage/Spellbook"):
				# книга мага KayKit по задумке парит у бедра — кладём том в кисть
				w.transform = Transform3D(Basis.from_euler(Vector3(0, PI * 0.5, 0)).scaled(Vector3.ONE * 0.85), Vector3(0, 0, 0))   # обложкой наружу
		else:
			w = weapon_scene(mdl).instantiate() as Node3D
			w.scale = Vector3.ONE * 0.8      # оружие Fantasy Weapons Bits крупнее родного оружия героев KayKit
		if w == null:
			return
		w.name = "ItemWeapon"
		att.add_child(w)
		var q: int = look["q"]
		var key := "item|%s|%s|%d" % [mdl, str(look["tint"]), q]
		var list: Array = w.find_children("*", "MeshInstance3D", true, false)
		if w is MeshInstance3D:
			list.append(w)
		if mdl != "orb":
			for mi in list:
				var m := mi as MeshInstance3D
				for s in m.mesh.get_surface_count():
					m.set_surface_override_material(s, _item_material(key + "|" + str(s), m.mesh.surface_get_material(s), look["tint"], q))
		if q >= 4:
			w.add_child(_legend_sparks())
		return

## Сфера в левой руке заклинателя: светящийся шар над ладонью, цвет — по качеству.
static func _orb(look: Dictionary) -> Node3D:
	var q: int = look["q"]
	var col: Color = GameData.ItemData.QUALITY[q].lerp(Color(0.5, 0.7, 1.0), 0.5)
	var key := "orb|%d" % q
	if not _material_cache.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(col.r, col.g, col.b, 0.8)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = 0.8 + 0.4 * q
		m.roughness = 0.1
		_material_cache[key] = m
		if q == 3:
			_pulse_mats.append(m)
			m.set_meta("pulse_base", m.emission_energy_multiplier)
	var root := Node3D.new()
	var ball := _prim(_ball(0.16), _material_cache[key])
	ball.position = Vector3(0, 0.1, 0.0)   # в ладони, а не в стороне от руки
	root.add_child(ball)
	return root

static func _ball(r: float) -> Mesh:
	var key := "ball|%s" % r
	if not _mesh_cache.has(key):
		var m := SphereMesh.new()
		m.radius = r
		m.height = r * 2.0
		m.radial_segments = 16
		m.rings = 8
		_mesh_cache[key] = m
	return _mesh_cache[key]

## Материалы эпических вещей мерцают: их немного (кеш по вещи), яркость меняет world._process раз в кадр.
static var _pulse_mats: Array = []

static func pulse(t: float) -> void:
	var k := 0.55 + 0.45 * sin(t * 3.2)
	for m: StandardMaterial3D in _pulse_mats:
		m.emission_energy_multiplier = float(m.get_meta("pulse_base")) * k

## Материал вещи: оттенок металла/ткани, свечение по качеству (glow — сила свечения: оружие ярче брони),
## purple — эпическое оружие ещё и окрашивается в фиолетовый.
static func _item_material(key: String, src: Material, tint: Color, q: int, glow_k: float = 1.0, purple: bool = true) -> Material:
	if _material_cache.has(key):
		return _material_cache[key]
	var mat := (src.duplicate() if src is StandardMaterial3D else StandardMaterial3D.new()) as StandardMaterial3D
	mat.albedo_color = mat.albedo_color * tint
	var glow: Color = GameData.ItemData.QUALITY_GLOW.get(q, Color.BLACK)
	if q == 3 and purple:
		mat.albedo_color = mat.albedo_color.lerp(Color(0.45, 0.25, 0.95), 0.45)   # эпическое — фиолетовое, не розовое
	if q >= 3:
		mat.emission_enabled = true
		mat.emission = glow
		mat.emission_energy_multiplier = (0.45 if q == 3 else 0.8) * glow_k
		if q == 3:
			mat.set_meta("pulse_base", mat.emission_energy_multiplier)
			_pulse_mats.append(mat)
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
	# родное оружие модели (шипастая дубинка орка) — снять со скина и закрепить на кисти жёстко, как в позе покоя:
	# при склейке частей оно съезжало с руки
	var rigid: Dictionary = mdl.get("rigid", {})
	for part: String in rigid:
		var src := skel.find_child(part, true, false) as MeshInstance3D
		if src == null:
			continue
		var bone: String = rigid[part]
		var ratt := BoneAttachment3D.new()
		ratt.bone_name = bone
		skel.add_child(ratt)
		var rm := MeshInstance3D.new()
		rm.mesh = src.mesh
		# рукоять — верхний конец меша (головка с шипами внизу): кладём её в кулак тем же хватом, что и наше оружие,
		# головкой — со стороны большого пальца
		var ab := src.mesh.get_aabb()
		var grip_pt := Vector3(ab.get_center().x, ab.end.y - ab.size.y * 0.15, ab.get_center().z)
		rm.transform = _fist_grip(skel, bone, bone.get_slice(".", 1)) * Transform3D(Basis(Vector3.BACK, PI), Vector3.ZERO) * Transform3D(Basis(), -grip_pt)
		for s in src.mesh.get_surface_count():
			rm.set_surface_override_material(s, _monster_material(mob_id + "|rigid|" + str(s), def, src.mesh.surface_get_material(s), true))
		ratt.add_child(rm)
		skel.remove_child(src)
		src.free()
		var rfist := FistModifier.new()
		rfist.setup(skel, bone.get_slice(".", 1))
		skel.add_child(rfist)
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
		var sc := float(grip["scale"]) * float(def.get("weapon_scale", 1.0)) / (arm * float(mdl["fit"]))
		var fist_xf := _fist_grip(skel, grip["bone"], side.to_upper())
		if fist_xf != Transform3D.IDENTITY:
			# как у героев KayKit: рукоять поперёк кулака (от мизинца к большому пальцу), клинок — со стороны
			# большого пальца; крепление к кисти (предплечью), поэтому оружие идёт за ударом в любой анимации
			w.transform = fist_xf * Transform3D(Basis.from_euler(def.get("grip_rot", grip["rot"]) * PI / 180.0).scaled(Vector3.ONE * sc), Vector3.ZERO)
		else:
			w.position = grip["pos"] / (arm * float(mdl["fit"]))
			w.rotation_degrees = def.get("grip_rot", grip["rot"])
			w.scale = Vector3.ONE * sc
		att.add_child(w)
		# пальцы этой руки — в кулак вокруг рукояти
		var fist := FistModifier.new()
		fist.setup(skel, side.to_upper())
		skel.add_child(fist)
	_setup_monster_anims(inst, mdl)

## Хват в кулаке (модели Quaternius): в пространстве кости-кисти bone (LowerArm — у этих моделей пальцы растут
## прямо из неё). Центр — середина первых фаланг пальцев, ось Y — от мизинца к указательному (рукоять поперёк
## ладони, клинок со стороны большого пальца), ось X — вдоль пальцев. IDENTITY — у модели нет таких костей.
static func _fist_grip(skel: Skeleton3D, bone: String, side: String) -> Transform3D:
	var bi := skel.find_bone(bone)
	var ii := skel.find_bone("Index2." + side)       # первые фаланги растут из одной точки — берём вторые
	var pk := skel.find_bone("Pinky2." + side)
	var mi := skel.find_bone("Middle1." + side)
	var m2 := skel.find_bone("Middle2." + side)
	if bi < 0 or ii < 0 or pk < 0 or mi < 0 or m2 < 0:
		return Transform3D.IDENTITY
	var inv := skel.get_bone_global_rest(bi).affine_inverse()
	var p_index := inv * skel.get_bone_global_rest(ii).origin
	var p_pinky := inv * skel.get_bone_global_rest(pk).origin
	var p_mid := inv * skel.get_bone_global_rest(mi).origin
	var p_mid2 := inv * skel.get_bone_global_rest(m2).origin
	var y := (p_index - p_pinky).normalized()
	var fingers := (p_mid2 - p_mid).normalized()
	var x := (fingers - y * fingers.dot(y)).normalized()
	var z := x.cross(y).normalized()
	# центр кулака: у основания пальцев, чуть внутрь ладони
	var center := (p_mid + p_mid2) * 0.5
	return Transform3D(Basis(x, y, z), center)

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
	"hunter": {"blue": [0.27, 0.5, 0.5], "purple": [0.08, 0.55, 0.45], "red": [0.07, 0.6, 0.55]},     # охотник: лесной зелёный и кожа
	"rogue": {"blue": [0.75, 0.25, 0.32], "purple": [0.76, 0.35, 0.3], "red": [0.0, 0.55, 0.4]},     # разбойник: тёмный фиолетово-серый и бордо
	"shaman": {"blue": [0.5, 0.75, 0.62], "purple": [0.07, 0.55, 0.5], "red": [0.08, 0.7, 0.7], "metal": [0.09, 0.4, 0.9]},    # шаман: бирюза, кожа и бронза
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

## Объекты боссов (филактерия, портал, ледяная гробница) — простые светящиеся фигуры без анимаций.
## Временная замена: нужен ассет.
static func _build_object(def: Dictionary, holder: Node3D) -> void:
	var col: Color = def.get("color", Color(0.5, 1.0, 0.6))
	var mi := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 1.6
	match def.get("shape", "crystal"):
		"crystal":
			var pm := PrismMesh.new()
			pm.size = Vector3(0.9, 2.2, 0.9)
			mi.mesh = pm
			mi.position.y = 1.4
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color.a = 0.85
			var base := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.5
			cm.bottom_radius = 0.7
			cm.height = 0.4
			base.mesh = cm
			base.position.y = 0.2
			var bm := StandardMaterial3D.new()
			bm.albedo_color = Color(0.3, 0.3, 0.32)
			base.material_override = bm
			holder.add_child(base)
		"portal":
			var tm := TorusMesh.new()
			tm.inner_radius = 1.1
			tm.outer_radius = 1.4
			mi.mesh = tm
			mi.rotation.x = PI * 0.5
			mi.position.y = 1.5
			mat.emission_energy_multiplier = 3.0
			var disc := MeshInstance3D.new()
			var dm := CylinderMesh.new()
			dm.top_radius = 1.1
			dm.bottom_radius = 1.1
			dm.height = 0.05
			disc.mesh = dm
			disc.rotation.x = PI * 0.5
			disc.position.y = 1.5
			var dmat := StandardMaterial3D.new()
			dmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			dmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			dmat.albedo_color = Color(col.r * 0.4, col.g * 0.6, col.b * 0.3, 0.7)
			disc.material_override = dmat
			holder.add_child(disc)
		"ice":
			var cy := CylinderMesh.new()
			cy.top_radius = 0.8
			cy.bottom_radius = 1.0
			cy.height = 2.6
			cy.radial_segments = 6
			mi.mesh = cy
			mi.position.y = 1.3
			mi.material_override = Vfx.ice_material()
			holder.add_child(mi)
			return
	mi.material_override = mat
	holder.add_child(mi)
