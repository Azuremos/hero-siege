extends SceneTree
## Генератор карты режима «Война линий» -> scenes/map_lines.tscn
## Запуск: godot --path . --script res://tools/bake_map_lines.gd  (без --headless: в headless деревья и горы MultiMesh сохраняются пустыми)
## Осадную карту (bake_map.gd -> map.tscn) не трогает. Правьте генератор, а не сцену: повторный запуск перезапишет её.
##
## Устройство (вид сверху, север — минус Z):
##   две половины, разделённые горным хребтом по оси X = 0;
##   команда 0 («Юг»): база на юге (Z > 0) в западной половине, её линии идут с северо-запада («ворота» соперника) на юг;
##   команда 1 («Север»): то же, повёрнутое на 180° (база на севере, восточная половина).
##   У каждой команды до 3 параллельных коридоров, между ними — лесополосы с коллайдерами: чужие мобы ходят только по своей линии.
## Узлы для режима: Lanes/T<команда>L<линия>/P<i>, Bases/Base<команда> (meta radius), HeroSpawn<команда>,
## Shops/<Торговец>_<команда> (meta yaw — куда смотрит торговец).

const S := 5.0
const TREE_S := 5.5
const MAP_X := 88.0
const MAP_Z := 136.0
const LANE_X := [22.0, 46.0, 70.0]      # |x| линий 0, 1, 2
const SEP_X := [34.0, 58.0]            # лесополосы между линиями
const RIDGE := 10.0                    # полуширина центрального хребта
const SEP_Z0 := -100.0                 # лесополосы — от ворот…
const SEP_Z1 := 84.0                   # …до площади у базы
const BASE := Vector2(-46.0, 108.0)    # база команды 0 (у команды 1 — зеркально)
const GATE_Z := -116.0

const TOWN := "res://assets/town/buildings/"
const NATURE := "res://assets/town/nature/"
const PROPS := "res://assets/town/props/"
const GRAVE := "res://assets/graveyard/"
const DUNGEON := "res://assets/dungeon/"

var mroot: Node3D
var colliders: Node3D
var rng := RandomNumberGenerator.new()
var lanes: Array = []                  # [команда][линия] -> PackedVector2Array
var multimesh_items: Dictionary = {}
var _fp_cache: Dictionary = {}

func _init() -> void:
	rng.seed = 20261017
	mroot = Node3D.new()
	mroot.name = "Map"
	colliders = _add(mroot, Node3D.new(), "Colliders")
	_environment()
	_ground()
	_build_lanes()
	_roads()
	for team in 2:
		_base(team)
		_gates(team)
		_separators(team)
	_ridge_and_bounds()
	_scatter()
	_flush_multimeshes()
	var ps := PackedScene.new()
	var err := ps.pack(mroot)
	if err == OK:
		err = ResourceSaver.save(ps, "res://scenes/map_lines.tscn")
	print("map_lines bake: ", error_string(err))
	mroot.free()
	quit()

# ---------------------------------------------------------------- утилиты

## Зеркало для команды 1: поворот на 180° вокруг центра карты.
func _m(p: Vector2, team: int) -> Vector2:
	return p if team == 0 else -p

func _my(yaw: float, team: int) -> float:
	return yaw if team == 0 else yaw + PI

func _add(parent: Node, n: Node, n_name: String = "") -> Node:
	if n_name != "":
		n.name = n_name
	parent.add_child(n, true)
	n.owner = mroot
	return n

func _place(path: String, p: Vector2, rot_y: float = 0.0, scl: float = S, parent: Node = null) -> Node3D:
	var inst := (load(path) as PackedScene).instantiate() as Node3D
	inst.position = Vector3(p.x, 0, p.y)
	inst.rotation.y = rot_y
	inst.scale = Vector3.ONE * scl
	_add(parent if parent else mroot, inst)
	return inst

func _box(p: Vector2, size: Vector3, rot_y: float = 0.0) -> void:
	var body := StaticBody3D.new()
	body.position = Vector3(p.x, size.y * 0.5, p.y)
	body.rotation.y = rot_y
	_add(colliders, body, "Box")
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	_add(body, cs)

func _cyl(p: Vector2, radius: float, height: float, n_name: String = "Cyl") -> void:
	var body := StaticBody3D.new()
	body.position = Vector3(p.x, height * 0.5, p.y)
	_add(colliders, body, n_name)
	var cs := CollisionShape3D.new()
	var sh := CylinderShape3D.new()
	sh.radius = radius
	sh.height = height
	cs.shape = sh
	_add(body, cs)

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
	return r

func _mm(path: String, p: Vector2, yaw: float, scl: Vector3) -> void:
	if not multimesh_items.has(path):
		multimesh_items[path] = []
	multimesh_items[path].append(Transform3D(Basis(Vector3.UP, yaw).scaled(scl), Vector3(p.x, 0, p.y)))

func _dist_to_lanes(p: Vector2) -> float:
	var best := 1e9
	for team_lanes in lanes:
		for lane: PackedVector2Array in team_lanes:
			for i in lane.size() - 1:
				best = minf(best, Geometry2D.get_closest_point_to_segment(p, lane[i], lane[i + 1]).distance_to(p))
	return best

# ---------------------------------------------------------------- окружение (как у осадной карты)

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
	pm.size = Vector2(420, 420)
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

# ---------------------------------------------------------------- линии

func _build_lanes() -> void:
	var lanes_node := _add(mroot, Node3D.new(), "Lanes")
	for team in 2:
		var team_lanes: Array = []
		for li in LANE_X.size():
			var x0: float = -LANE_X[li]
			var raw := [Vector2(x0, GATE_Z), Vector2(x0 + 3, -96), Vector2(x0 - 3, -72), Vector2(x0 + 3, -48), Vector2(x0 - 3, -24),
				Vector2(x0 + 3, 0), Vector2(x0 - 3, 24), Vector2(x0 + 3, 48), Vector2(x0 - 2, 70), Vector2(x0, 86),
				Vector2(lerpf(x0, BASE.x, 0.5), 95), Vector2(lerpf(x0, BASE.x, 0.85), BASE.y - 7.5)]
			var pts := PackedVector2Array()
			for p: Vector2 in raw:
				pts.append(_m(p, team))
			team_lanes.append(pts)
			var ln := _add(lanes_node, Node3D.new(), "T%dL%d" % [team, li])
			for i in pts.size():
				var mk := Marker3D.new()
				mk.position = Vector3(pts[i].x, 0, pts[i].y)
				_add(ln, mk, "P%d" % i)
		lanes.append(team_lanes)
	var bases := _add(mroot, Node3D.new(), "Bases")
	for team in 2:
		var b := Marker3D.new()
		var bp := _m(BASE, team)
		b.position = Vector3(bp.x, 0, bp.y)
		b.set_meta("radius", 6.5)
		_add(bases, b, "Base%d" % team)
		var hs := Marker3D.new()
		var sp := _m(BASE + Vector2(0, 9.5), team)
		hs.position = Vector3(sp.x, 0, sp.y)
		hs.set_meta("yaw", _my(0.0, team))       # лицом к своим линиям (на север у команды 0)
		_add(mroot, hs, "HeroSpawn%d" % team)

func _roads() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for team_lanes in lanes:
		for lane: PackedVector2Array in team_lanes:
			_ribbon(st, lane, 7.0, 2.5)
	for team in 2:
		var c := _m(BASE, team)
		var seg := 40
		for i in seg:
			var a0 := TAU * i / seg
			var a1 := TAU * (i + 1) / seg
			for ring in [[0.0, 16.0, 1.0, 1.0], [16.0, 20.0, 1.0, 0.0]]:
				var v := [Vector3(c.x + cos(a0) * ring[0], 0.025, c.y + sin(a0) * ring[0]), Vector3(c.x + cos(a1) * ring[0], 0.025, c.y + sin(a1) * ring[0]),
					Vector3(c.x + cos(a1) * ring[1], 0.025, c.y + sin(a1) * ring[1]), Vector3(c.x + cos(a0) * ring[1], 0.025, c.y + sin(a0) * ring[1])]
				var al := [ring[2], ring[2], ring[3], ring[3]]
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

# ---------------------------------------------------------------- база и площадь с лавками

func _base(team: int) -> void:
	var town := _add(mroot, Node3D.new(), "Base%d" % team)
	var flag: String = PROPS + ("flag_blue.gltf" if team == 0 else "flag_red.gltf")
	var banner: String = DUNGEON + ("banner_triple_blue.gltf.glb" if team == 0 else "banner_triple_red.gltf.glb")
	var c := _m(BASE, team)
	_place(TOWN + "building_castle_blue.gltf", c, _my(PI, team), S, town)
	_box(c, Vector3(9.0, 20.0, 10.0))
	# лавки — за замком, лицом к нему (кузнец, вербовщик, алхимик)
	var shops: Node = mroot.get_node_or_null("Shops")
	if shops == null:
		shops = _add(mroot, Node3D.new(), "Shops")
	var list := [["building_blacksmith_blue.gltf", Vector2(18, 21), Vector3(6.4, 5, 6.2), "Blacksmith"],
		["building_barracks_blue.gltf", Vector2(0, 23), Vector3(7.0, 6, 6.0), "Recruiter"],
		["building_tavern_blue.gltf", Vector2(-18, 21), Vector3(5.8, 7, 6.6), "Alchemy"]]
	for b in list:
		var p: Vector2 = _m(BASE + b[1], team)
		var face := _m(BASE + Vector2(b[1].x * 0.5, 12.0), team)
		var rot := atan2(face.x - p.x, face.y - p.y)
		_place(TOWN + b[0], p, rot, S, town)
		_box(p, b[2], rot)
		var front := p + (face - p).normalized() * 6.5
		var mk := Marker3D.new()
		mk.position = Vector3(front.x, 0, front.y)
		mk.set_meta("yaw", atan2(face.x - front.x, face.y - front.y) + PI)
		_add(shops, mk, "%s_%d" % [b[3], team])
	# башни и флаги по углам площади
	for o in [Vector2(-34, -18), Vector2(32, -18), Vector2(-34, 24), Vector2(32, 24)]:
		var p := _m(BASE + o, team)
		_place(TOWN + "building_tower_A_blue.gltf", p, 0.0, S * 0.8, town)
		_cyl(p, 2.2, 12.0)
	for o in [Vector2(-10, -9), Vector2(10, -9), Vector2(-26, 8), Vector2(26, 8)]:
		_place(flag, _m(BASE + o, team), _my(0.0, team), S, town)
	for o in [Vector2(-7, 7), Vector2(7, 7)]:
		_place(banner, _m(BASE + o, team), _my(0.0, team), 1.5, town)
	# мелочи у лавок
	for pr in [["barrel.gltf", Vector2(24, 15)], ["crate_A_big.gltf", Vector2(12, 26)], ["weaponrack.gltf", Vector2(6, 17)],
			["sack.gltf", Vector2(-24, 15)], ["crate_B_small.gltf", Vector2(-12, 26)], ["bucket_water.gltf", Vector2(-6, 17)]]:
		var p: Vector2 = _m(BASE + pr[1], team)
		_place(PROPS + pr[0], p, rng.randf() * TAU, S, town)
		_cyl(p, maxf(0.35, _footprint(PROPS + pr[0]) * S * 0.5), 2.0)
	# южная (у команды 1 — северная) стена за лавками
	var back_z := 30.0
	for ox in range(-36, 37, 10):
		var p := _m(BASE + Vector2(ox, back_z), team)
		_place(TOWN + "wall_straight.gltf", p, _my(0.0, team), S, town)
		_box(p, Vector3(10.2, 6.0, 4.0))

## «Ворота» соперника: откуда выходят враги этой команды (арки, фонари, знамёна соперника), стена за ними.
func _gates(team: int) -> void:
	var g := _add(mroot, Node3D.new(), "Gates%d" % team)
	var enemy_banner: String = DUNGEON + ("banner_thin_red.gltf.glb" if team == 0 else "banner_thin_blue.gltf.glb")
	for li in LANE_X.size():
		var x0: float = -LANE_X[li]
		var arch := _m(Vector2(x0, GATE_Z + 4.0), team)
		var rot := _my(0.0, team)
		_place(GRAVE + "arch_gate.gltf", arch, rot, 1.8, g)
		for s in [-1.0, 1.0]:
			var pillar := _m(Vector2(x0 + s * 4.0, GATE_Z + 4.0), team)
			_cyl(pillar, 0.6, 6.0)
			_place(enemy_banner, _m(Vector2(x0 + s * 5.5, GATE_Z + 2.0), team), rot, 1.4, g)
			_place(GRAVE + "post_lantern.gltf", _m(Vector2(x0 + s * 6.5, GATE_Z + 8.0), team), rot, 1.6, g)
	for ox in range(-80, -9, 10):
		var p := _m(Vector2(ox + 5, -MAP_Z + 8.0), team)
		_place(TOWN + "wall_straight.gltf", p, _my(0.0, team), S, g)
		_box(p, Vector3(10.2, 6.0, 4.0))
	# камни и мёртвые деревья у ворот
	for i in 14:
		var p := _m(Vector2(rng.randf_range(-80, -14), rng.randf_range(-126, -104)), team)
		if _dist_to_lanes(p) < 6.0:
			continue
		var item: String = ["tree_dead_large.gltf", "tree_dead_medium.gltf", "skull.gltf", "bone_A.gltf", "gravestone.gltf"][rng.randi() % 5]
		_place(GRAVE + item, p, rng.randf() * TAU, 1.6, g)

## Лесополосы между линиями одной команды: стена-коллайдер (отрезки до 46 м — мобы читают их как препятствия)
## и два ряда елей поверх (MultiMesh). Внешний край половины — горы.
func _separators(team: int) -> void:
	for sx: float in SEP_X:
		var z := SEP_Z0
		while z < SEP_Z1 - 1.0:
			var len := minf(46.0, SEP_Z1 - z)
			_box(_m(Vector2(-sx, z + len * 0.5), team), Vector3(5.0, 8.0, len))
			z += len
		var tz := SEP_Z0 + 2.0
		while tz < SEP_Z1:
			for row in [-1.6, 1.6]:
				var p := _m(Vector2(-sx + row + rng.randf_range(-0.6, 0.6), tz + rng.randf_range(-1.2, 1.2)), team)
				var item: String = ["tree_single_A.gltf", "tree_single_B.gltf"][rng.randi() % 2]
				var s := TREE_S * rng.randf_range(0.85, 1.15)
				_mm(NATURE + item, p, rng.randf() * TAU, Vector3.ONE * s)
			tz += 3.4

func _ridge_and_bounds() -> void:
	# центральный хребет: горы и коллайдер по всей длине карты
	var z := -MAP_Z
	while z < MAP_Z - 1.0:
		var len := minf(40.0, MAP_Z - z)
		_box(Vector2(0, z + len * 0.5), Vector3(RIDGE * 2.0 - 2.0, 20.0, len))
		z += len
	var mountains := ["mountain_A_grass_trees.gltf", "mountain_B_grass_trees.gltf", "mountain_C_grass_trees.gltf", "mountain_A_grass.gltf", "mountain_B.gltf"]
	var t := -MAP_Z
	while t <= MAP_Z:
		var item: String = mountains[rng.randi() % mountains.size()]
		var s := rng.randf_range(5.6, 6.6)
		_mm(NATURE + item, Vector2(rng.randf_range(-1.0, 1.0), t), rng.randf() * TAU, Vector3(s, s * rng.randf_range(0.9, 1.4), s))
		t += 8.0
	# края карты: горы и стены-коллайдеры
	for side in [-1.0, 1.0]:
		var bz := -MAP_Z
		while bz < MAP_Z - 1.0:
			var len := minf(40.0, MAP_Z - bz)
			_box(Vector2(side * (MAP_X + 2.0), bz + len * 0.5), Vector3(4.0, 20.0, len))
			bz += len
		var mt := -MAP_Z - 10.0
		while mt <= MAP_Z + 10.0:
			var item: String = mountains[rng.randi() % mountains.size()]
			var s := rng.randf_range(7.0, 10.0)
			_mm(NATURE + item, Vector2(side * (MAP_X + rng.randf_range(8, 16)), mt), rng.randf() * TAU, Vector3(s, s * rng.randf_range(0.8, 1.3), s))
			mt += 11.0
	for side in [-1.0, 1.0]:
		for x in [-44.0, 0.0, 44.0]:
			_box(Vector2(x, side * (MAP_Z + 2.0)), Vector3(44.0, 20.0, 4.0))
		var mx := -MAP_X - 20.0
		while mx <= MAP_X + 20.0:
			var item: String = mountains[rng.randi() % mountains.size()]
			var s := rng.randf_range(7.0, 10.0)
			_mm(NATURE + item, Vector2(mx, side * (MAP_Z + rng.randf_range(8, 16))), rng.randf() * TAU, Vector3(s, s * rng.randf_range(0.8, 1.3), s))
			mx += 11.0

## Камни, кусты и одиночные деревья по краям коридоров (без коллайдеров на дороге).
func _scatter() -> void:
	for i in 220:
		var p := Vector2(rng.randf_range(-MAP_X + 3, MAP_X - 3), rng.randf_range(SEP_Z0, SEP_Z1))
		if absf(p.x) < RIDGE + 2.0:
			continue
		var dl := _dist_to_lanes(p)
		if dl < 5.5:
			continue
		var near_sep := false
		for sx: float in SEP_X:
			if absf(absf(p.x) - sx) < 4.0:
				near_sep = true
		if near_sep:
			continue
		if rng.randf() < 0.55:
			var item := "rock_single_%s.gltf" % ["A", "B", "C", "D", "E"][rng.randi() % 5]
			var s := rng.randf_range(2.5, 4.5)
			_mm(NATURE + item, p, rng.randf() * TAU, Vector3.ONE * s)
			var r := _footprint(NATURE + item) * s * 0.7
			if dl > r + 3.0:
				_cyl(p, maxf(0.35, r), 3.0)
		else:
			var item: String = ["tree_single_A.gltf", "tree_single_B.gltf", "trees_A_small.gltf", "trees_B_small.gltf"][rng.randi() % 4]
			var s := TREE_S * rng.randf_range(0.8, 1.1)
			_mm(NATURE + item, p, rng.randf() * TAU, Vector3.ONE * s)
			if dl > 6.5:
				_cyl(p, 0.9, 6.0, "Tree")

func _flush_multimeshes() -> void:
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
