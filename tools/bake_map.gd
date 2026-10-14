extends SceneTree
## Генератор карты «Осада замка» -> scenes/map.tscn
## Запуск: godot --headless --script res://tools/bake_map.gd
## После генерации карту можно свободно править в редакторе Godot.
## ВНИМАНИЕ: повторный запуск перезапишет ручные правки map.tscn.

const S := 5.0          # масштаб построек гекс-пака KayKit под героев
const TREE_S := 7.0
const HALF := 35.0      # половина стороны городской стены
const MAP_HALF := 133.0 # граница карты

const TOWN := "res://assets/town/buildings/"
const NATURE := "res://assets/town/nature/"
const PROPS := "res://assets/town/props/"
const GRAVE := "res://assets/graveyard/"
const DUNGEON := "res://assets/dungeon/"

var mroot: Node3D
var colliders: Node3D
var rng := RandomNumberGenerator.new()
var lanes: Array[PackedVector2Array] = []
var multimesh_items: Dictionary = {}   # path -> Array[Transform3D]
var occupied: Array = []               # [Vector2, radius] — чтобы декорации не налезали

func _init() -> void:
	rng.seed = 20261013
	mroot = Node3D.new()
	mroot.name = "Map"
	colliders = _add(mroot, Node3D.new(), "Colliders")
	_environment()
	_ground()
	_build_lanes()
	_roads()
	_town()
	_graveyards()
	_nature()
	_flush_multimeshes()
	_bounds()
	var ps := PackedScene.new()
	var err := ps.pack(mroot)
	if err == OK:
		err = ResourceSaver.save(ps, "res://scenes/map.tscn")
	print("map bake: ", error_string(err))
	mroot.free()
	quit()

# ---------------------------------------------------------------- утилиты

func _add(parent: Node, n: Node, n_name: String = "") -> Node:
	if n_name != "":
		n.name = n_name
	parent.add_child(n, true)
	n.owner = mroot
	return n

func _place(path: String, pos: Vector3, rot_y: float = 0.0, scl: float = S, parent: Node = null) -> Node3D:
	var inst := (load(path) as PackedScene).instantiate() as Node3D
	inst.position = pos
	inst.rotation.y = rot_y
	inst.scale = Vector3.ONE * scl
	_add(parent if parent else mroot, inst)
	return inst

func _box(pos: Vector3, size: Vector3, rot_y: float = 0.0) -> void:
	var body := StaticBody3D.new()
	body.position = pos + Vector3(0, size.y * 0.5, 0)
	body.rotation.y = rot_y
	_add(colliders, body, "Box")
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	_add(body, cs)

func _cyl(pos: Vector3, radius: float, height: float) -> void:
	var body := StaticBody3D.new()
	body.position = pos + Vector3(0, height * 0.5, 0)
	_add(colliders, body, "Cyl")
	var cs := CollisionShape3D.new()
	var sh := CylinderShape3D.new()
	sh.radius = radius
	sh.height = height
	cs.shape = sh
	_add(body, cs)

var _fp_cache: Dictionary = {}

## Половина ширины модели по её габаритам (при масштабе 1) — для размера коллайдера.
func _footprint(path: String) -> float:
	if _fp_cache.has(path):
		return _fp_cache[path]
	var inst := (load(path) as PackedScene).instantiate() as Node3D
	var box := AABB()
	var first := true
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		var local := Transform3D.IDENTITY
		var n: Node = mi
		while n != inst:
			local = (n as Node3D).transform * local
			n = n.get_parent()
		var bb: AABB = local * (mi as MeshInstance3D).mesh.get_aabb()
		box = bb if first else box.merge(bb)
		first = false
	inst.free()
	var r := maxf(box.size.x, box.size.z) * 0.5
	_fp_cache[path] = r
	print("  габарит %s: %.2f" % [path.get_file(), r])
	return r

## Коллайдер-цилиндр под декорацию: доля frac от её половины ширины (ствол, а не крона).
## Случайные числа не трогаем — расстановка карты остаётся прежней.
func _prop_collider(path: String, p: Vector2, scl: float, frac: float, height: float = 6.0) -> void:
	var r := maxf(0.35, _footprint(path) * scl * frac)
	_cyl(Vector3(p.x, 0, p.y), r, height)

func _face_center(p: Vector2) -> float:
	return atan2(-p.x, -p.y)

func _rot90(p: Vector2, k: int) -> Vector2:
	for i in k:
		p = Vector2(-p.y, p.x)
	return p

func _dist_to_lanes(p: Vector2) -> float:
	var best := 1e9
	for lane in lanes:
		for i in lane.size() - 1:
			var c := Geometry2D.get_closest_point_to_segment(p, lane[i], lane[i + 1])
			best = minf(best, c.distance_to(p))
	return best

func _is_free(p: Vector2, r: float) -> bool:
	for o in occupied:
		if p.distance_to(o[0]) < r + float(o[1]):
			return false
	return true

func _mm(path: String, xf: Transform3D) -> void:
	if not multimesh_items.has(path):
		multimesh_items[path] = []
	multimesh_items[path].append(xf)

# ---------------------------------------------------------------- окружение

func _environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -38, 0)
	sun.light_energy = 1.15
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 60.0
	_add(mroot, sun, "Sun")

	var env := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.32, 0.52, 0.82)
	sky_mat.sky_horizon_color = Color(0.72, 0.8, 0.9)
	sky_mat.ground_horizon_color = Color(0.72, 0.8, 0.9)
	sky_mat.ground_bottom_color = Color(0.3, 0.35, 0.3)
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.75
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.05
	env.fog_enabled = true
	env.fog_light_color = Color(0.7, 0.78, 0.88)
	env.fog_density = 0.0018
	env.fog_sky_affect = 0.3
	var we := WorldEnvironment.new()
	we.environment = env
	_add(mroot, we, "WorldEnvironment")

func _ground() -> void:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(380, 380)
	mi.mesh = pm
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/ground.gdshader")
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add(mroot, mi, "Ground")
	var body := StaticBody3D.new()
	_add(mroot, body, "GroundBody")
	var cs := CollisionShape3D.new()
	cs.shape = WorldBoundaryShape3D.new()
	_add(body, cs)

# ---------------------------------------------------------------- полосы врагов

func _build_lanes() -> void:
	# Северная полоса: от кладбища к воротам и к замку. Остальные — поворот на 90°.
	var base := [Vector2(0, -118), Vector2(8, -102), Vector2(-9, -86), Vector2(-11, -68),
		Vector2(0, -52), Vector2(0, -35), Vector2(0, -20), Vector2(0, -9.5)]
	var names := ["North", "East", "South", "West"]
	var lanes_node := _add(mroot, Node3D.new(), "Lanes")
	for k in 4:
		var pts := PackedVector2Array()
		for p: Vector2 in base:
			var q := p
			if k % 2 == 1:
				q.x = -q.x
			pts.append(_rot90(q, k))
		lanes.append(pts)
		var lane_node := _add(lanes_node, Node3D.new(), names[k])
		for i in pts.size():
			var m := Marker3D.new()
			m.position = Vector3(pts[i].x, 0, pts[i].y)
			_add(lane_node, m, "P%d" % i)
		occupied.append([pts[0], 16.0])

	var hs := Marker3D.new()
	hs.position = Vector3(0, 0, 14)
	_add(mroot, hs, "HeroSpawn")
	var core := Marker3D.new()
	core.position = Vector3.ZERO
	core.set_meta("radius", 6.5)
	_add(mroot, core, "CastleCore")

func _roads() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for lane in lanes:
		_ribbon(st, lane, 7.0, 2.5)
	# площадь вокруг замка
	var seg := 40
	for i in seg:
		var a0 := TAU * i / seg
		var a1 := TAU * (i + 1) / seg
		for ring in [[0.0, 15.0, 1.0, 1.0], [15.0, 18.5, 1.0, 0.0]]:
			var r0: float = ring[0]
			var r1: float = ring[1]
			var al0: float = ring[2]
			var al1: float = ring[3]
			var v := [Vector3(cos(a0) * r0, 0.025, sin(a0) * r0), Vector3(cos(a1) * r0, 0.025, sin(a1) * r0),
				Vector3(cos(a1) * r1, 0.025, sin(a1) * r1), Vector3(cos(a0) * r1, 0.025, sin(a0) * r1)]
			var al := [al0, al0, al1, al1]
			for idx in [0, 2, 1, 0, 3, 2]:
				st.set_color(Color(1, 1, 1, al[idx]))
				st.set_normal(Vector3.UP)
				st.add_vertex(v[idx])
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.80, 0.64, 0.45)
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 1.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add(mroot, mi, "Roads")

func _ribbon(st: SurfaceTool, pts: PackedVector2Array, width: float, fade: float) -> void:
	var offs := [-width * 0.5 - fade, -width * 0.5, width * 0.5, width * 0.5 + fade]
	var alphas := [0.0, 1.0, 1.0, 0.0]
	# Сглаживаем полилинию, чтобы дорога шла плавной дугой.
	var curve := Curve2D.new()
	for i in pts.size():
		var tin := Vector2.ZERO
		var tout := Vector2.ZERO
		if i > 0 and i < pts.size() - 1:
			var t := (pts[i + 1] - pts[i - 1]) * 0.25
			tin = -t
			tout = t
		curve.add_point(pts[i], tin, tout)
	curve.bake_interval = 2.0
	var path := curve.get_baked_points()
	# Нормаль в каждой точке — среднее соседних сегментов, чтобы края на изгибах не рвались.
	var normals := PackedVector2Array()
	for i in path.size():
		var d0 := (path[i] - path[maxi(i - 1, 0)]).normalized()
		var d1 := (path[mini(i + 1, path.size() - 1)] - path[i]).normalized()
		var d := (d0 + d1).normalized()
		if d == Vector2.ZERO:
			d = d1 if d1 != Vector2.ZERO else d0
		normals.append(Vector2(-d.y, d.x))
	for i in path.size() - 1:
		var a := path[i]
		var b := path[i + 1]
		var na := normals[i]
		var nb := normals[i + 1]
		for c in 3:
			var p0a: Vector2 = a + na * offs[c]
			var p1a: Vector2 = a + na * offs[c + 1]
			var p0b: Vector2 = b + nb * offs[c]
			var p1b: Vector2 = b + nb * offs[c + 1]
			var quad := [[p0a, alphas[c]], [p0b, alphas[c]], [p1b, alphas[c + 1]], [p0a, alphas[c]], [p1b, alphas[c + 1]], [p1a, alphas[c + 1]]]
			for q in quad:
				st.set_color(Color(1, 1, 1, q[1]))
				st.set_normal(Vector3.UP)
				st.add_vertex(Vector3(q[0].x, 0.02, q[0].y))

# ---------------------------------------------------------------- город

func _town() -> void:
	var town := _add(mroot, Node3D.new(), "Town")
	# Стены: по 6 секций на сторону, в центре — проход между двумя башнями.
	for side in 4:
		for o in [-32.0, -22.0, -12.0, 12.0, 22.0, 32.0]:
			var p := _rot90(Vector2(o, -HALF), side)
			var rot := -PI * 0.5 * side
			_place(TOWN + "wall_straight.gltf", Vector3(p.x, 0, p.y), rot, S, town)
			_box(Vector3(p.x, 0, p.y), Vector3(10.2, 6.0, 4.0), rot)
		for o in [-7.0, 7.0]:
			var p := _rot90(Vector2(o, -HALF), side)
			_place(TOWN + "building_tower_B_blue.gltf", Vector3(p.x, 0, p.y), -PI * 0.5 * side, S, town)
			_cyl(Vector3(p.x, 0, p.y), 2.6, 12.0)
		var c := _rot90(Vector2(HALF, -HALF), side)
		_place(TOWN + "building_tower_A_blue.gltf", Vector3(c.x, 0, c.y), 0.0, S, town)
		_cyl(Vector3(c.x, 0, c.y), 2.7, 12.0)

	# Замок
	_place(TOWN + "building_castle_blue.gltf", Vector3.ZERO, 0.0, S, town)
	_box(Vector3.ZERO, Vector3(9.0, 20.0, 10.0))
	occupied.append([Vector2.ZERO, 12.0])

	# Мастерские и магазины (в будущем — кузница, чары, алхимия, торговцы)
	var shops := _add(mroot, Node3D.new(), "Shops")
	var buildings := [
		["building_blacksmith_blue.gltf", Vector2(19, -19), Vector3(6.4, 5, 6.2), "Blacksmith"],
		["building_market_blue.gltf", Vector2(-19, -19), Vector3(8.6, 5, 6.4), "Market"],
		["building_church_blue.gltf", Vector2(-19, 19), Vector3(5.2, 8, 5.6), "Enchanting"],
		["building_tavern_blue.gltf", Vector2(19, 19), Vector3(5.8, 7, 6.6), "Alchemy"],
	]
	for b in buildings:
		var p: Vector2 = b[1]
		var rot := _face_center(p)
		_place(TOWN + b[0], Vector3(p.x, 0, p.y), rot, S, town)
		_box(Vector3(p.x, 0, p.y), b[2], rot)
		var front := p + (Vector2.ZERO - p).normalized() * 6.5
		var mk := Marker3D.new()
		mk.position = Vector3(front.x, 0, front.y)
		_add(shops, mk, b[3])
	# Жилые дома и колодец
	for h in [["building_home_A_blue.gltf", Vector2(27, -11)], ["building_home_B_blue.gltf", Vector2(-27, 11)],
			["building_home_A_blue.gltf", Vector2(11, 27)], ["building_home_B_blue.gltf", Vector2(-11, -27)],
			["building_home_B_blue.gltf", Vector2(27, 11)], ["building_home_A_blue.gltf", Vector2(-27, -11)]]:
		var p: Vector2 = h[1]
		var rot := _face_center(p)
		_place(TOWN + h[0], Vector3(p.x, 0, p.y), rot, S, town)
		_box(Vector3(p.x, 0, p.y), Vector3(4.6, 5, 4.6), rot)
	_place(TOWN + "building_well_blue.gltf", Vector3(-12, 0, 12), 0.4, S, town)
	_cyl(Vector3(-12, 0, 12), 1.8, 3.0)
	# Мелочи у кузницы и рынка
	for pr in [["barrel.gltf", Vector2(14, -24)], ["crate_A_big.gltf", Vector2(24, -14)], ["weaponrack.gltf", Vector2(15, -14.5)],
			["crate_B_small.gltf", Vector2(-14, -24)], ["sack.gltf", Vector2(-24, -14)], ["wheelbarrow.gltf", Vector2(-15, -14.5)],
			["bucket_water.gltf", Vector2(-10, 14)], ["crate_long_A.gltf", Vector2(14, 24)], ["barrel.gltf", Vector2(24, 15)]]:
		var p: Vector2 = pr[1]
		_place(PROPS + pr[0], Vector3(p.x, 0, p.y), rng.randf() * TAU, S, town)
		_prop_collider(PROPS + pr[0], p, S, 0.5, 2.0)
	# Деревья внутри стен
	for tp in [Vector2(-28, -24), Vector2(28, 24), Vector2(24, -28), Vector2(-24, 28)]:
		_mm(NATURE + "tree_single_A.gltf", Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * TREE_S), Vector3(tp.x, 0, tp.y)))
		_prop_collider(NATURE + "tree_single_A.gltf", tp, TREE_S, 0.16, 8.0)
	occupied.append([Vector2.ZERO, 50.0])

# ---------------------------------------------------------------- кладбища (точки появления)

func _graveyards() -> void:
	var gy := _add(mroot, Node3D.new(), "Graveyards")
	for k in lanes.size():
		var spawn: Vector2 = lanes[k][0]
		var out_dir := spawn.normalized()
		var rot := _face_center(spawn)
		var crypt_p := spawn + out_dir * 12.0
		_place(GRAVE + "crypt.gltf", Vector3(crypt_p.x, 0, crypt_p.y), rot, 1.3, gy)
		_box(Vector3(crypt_p.x, 0, crypt_p.y), Vector3(7.8, 9, 10.4), rot)
		var arch_p := spawn - out_dir * 6.0
		_place(GRAVE + "arch_gate.gltf", Vector3(arch_p.x, 0, arch_p.y), rot, 1.6, gy)
		var side := Vector2(-out_dir.y, out_dir.x)
		for s in [-1.0, 1.0]:
			var pillar: Vector2 = arch_p + side * s * 3.6
			_cyl(Vector3(pillar.x, 0, pillar.y), 0.6, 6.0)
			for f in 3:
				var fp: Vector2 = arch_p + side * s * (6.0 + f * 3.6)
				_place(GRAVE + ("fence.gltf" if f != 1 else "fence_broken.gltf"), Vector3(fp.x, 0, fp.y), rot, 1.6, gy)
		var placed := 0
		var tries := 0
		while placed < 16 and tries < 200:
			tries += 1
			var p := spawn + Vector2(rng.randf_range(-20, 20), rng.randf_range(-20, 20))
			if _dist_to_lanes(p) < 6.0 or p.distance_to(crypt_p) < 8.0 or p.distance_to(arch_p) < 7.0:
				continue
			var pick := ["grave_A.gltf", "grave_B.gltf", "gravestone.gltf", "gravemarker_A.gltf", "gravemarker_B.gltf",
				"grave_A_destroyed.gltf", "tree_dead_large.gltf", "tree_dead_medium.gltf", "post_lantern.gltf", "skull.gltf", "bone_A.gltf"]
			var item: String = pick[rng.randi() % pick.size()]
			var scl := 1.6 if item.begins_with("tree") else 1.3
			_place(GRAVE + item, Vector3(p.x, 0, p.y), rot + rng.randf_range(-0.3, 0.3), scl, gy)
			if item.begins_with("tree"):
				_prop_collider(GRAVE + item, p, scl, 0.18, 6.0)
			elif item.begins_with("grave"):
				_prop_collider(GRAVE + item, p, scl, 0.4, 2.0)
			placed += 1
		occupied.append([spawn, 24.0])

# ---------------------------------------------------------------- природа

func _nature() -> void:
	var clumps := ["trees_A_large.gltf", "trees_B_large.gltf", "trees_A_medium.gltf", "trees_B_medium.gltf", "hills_A_trees.gltf"]
	var tries := 0
	var placed := 0
	while placed < 150 and tries < 4000:
		tries += 1
		var p := Vector2(rng.randf_range(-MAP_HALF + 4, MAP_HALF - 4), rng.randf_range(-MAP_HALF + 4, MAP_HALF - 4))
		if absf(p.x) < 46 and absf(p.y) < 46:
			continue
		if _dist_to_lanes(p) < 13.0 or not _is_free(p, 5.0):
			continue
		var item: String = clumps[rng.randi() % clumps.size()]
		var s := TREE_S * rng.randf_range(0.85, 1.2)
		_mm(NATURE + item, Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s), Vector3(p.x, 0, p.y)))
		occupied.append([p, 5.5])
		_prop_collider(NATURE + item, p, s, 0.6 if item.begins_with("hills") else 0.45, 10.0)
		placed += 1
	# Камни
	for i in 120:
		var p := Vector2(rng.randf_range(-MAP_HALF, MAP_HALF), rng.randf_range(-MAP_HALF, MAP_HALF))
		if absf(p.x) < 40 and absf(p.y) < 40:
			continue
		var item := "rock_single_%s.gltf" % ["A", "B", "C", "D", "E"][rng.randi() % 5]
		var rock_s := rng.randf_range(5.0, 9.0)    # порядок как в прежней формуле: сначала масштаб, потом поворот
		var rock_rot := rng.randf() * TAU
		_mm(NATURE + item, Transform3D(Basis(Vector3.UP, rock_rot).scaled(Vector3.ONE * rock_s), Vector3(p.x, 0, p.y)))
		# на дорогах камень остаётся без коллайдера, чтобы не перегородить путь
		var rock_r := _footprint(NATURE + item) * rock_s * 0.75
		if _dist_to_lanes(p) > rock_r + 3.0:
			_cyl(Vector3(p.x, 0, p.y), maxf(0.35, rock_r), 3.0)
	# Горы по краю карты
	var mountains := ["mountain_A_grass_trees.gltf", "mountain_B_grass_trees.gltf", "mountain_C_grass_trees.gltf", "mountain_A_grass.gltf", "mountain_B.gltf"]
	var t := -152.0
	while t < 152.0:
		for side in 4:
			var p := _rot90(Vector2(t + rng.randf_range(-3, 3), -MAP_HALF - rng.randf_range(4, 16)), side)
			var item: String = mountains[rng.randi() % mountains.size()]
			var s := rng.randf_range(8.0, 12.0)
			_mm(NATURE + item, Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.8, 1.3), s)), Vector3(p.x, 0, p.y)))
		t += 11.0

func _flush_multimeshes() -> void:
	# Одинаковые модели рисуются одним вызовом (MultiMesh) — экономит процессор.
	var nature := _add(mroot, Node3D.new(), "Nature")
	for path in multimesh_items:
		var inst := (load(path) as PackedScene).instantiate() as Node3D
		for mi in inst.find_children("*", "MeshInstance3D", true, false):
			var local := Transform3D.IDENTITY
			var n: Node = mi
			while n != inst:
				local = (n as Node3D).transform * local
				n = n.get_parent()
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = (mi as MeshInstance3D).mesh
			var xfs: Array = multimesh_items[path]
			mm.instance_count = xfs.size()
			for i in xfs.size():
				mm.set_instance_transform(i, (xfs[i] as Transform3D) * local)
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			if path.contains("rock_"):
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_add(nature, mmi, path.get_file().get_basename())
		inst.free()

func _bounds() -> void:
	for side in 4:
		var p := _rot90(Vector2(0, -MAP_HALF - 2), side)
		_box(Vector3(p.x, 0, p.y), Vector3(300, 20, 4), -PI * 0.5 * side)
