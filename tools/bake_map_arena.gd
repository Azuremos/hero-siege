extends SceneTree
## Генератор карты режима «Арена» -> scenes/map_arena.tscn
## Запуск: godot --path . --script res://tools/bake_map_arena.gd  (без --headless: в headless MultiMesh сохраняются пустыми)
## Осадную карту и карту «Линий» не трогает. Правьте генератор, а не сцену: повторный запуск перезапишет её.
##
## Раскладка — scripts/data/arena_data.gd (её же читает режим): база команды 0 на юге (Z > 0), команды 1 — на севере
## (поворот на 180°), в центре — закрытая арена дуэлей со зрительскими местами, лагеря монстров по кольцам.
## Узлы для режима: Bases/Base<команда> (meta radius), HeroSpawn<команда> (meta yaw), Fountain<команда>,
## Shops/<Торговец>_<команда> (meta yaw), Camps/<id> (meta tier), DuelArena (meta radius), Colliders.

const A := preload("res://scripts/data/arena_data.gd")
const S := 5.0
const TREE_S := 5.5
const H := A.MAP_HALF

const TOWN := "res://assets/town/buildings/"
const NATURE := "res://assets/town/nature/"
const PROPS := "res://assets/town/props/"
const GRAVE := "res://assets/graveyard/"
const DUNGEON := "res://assets/dungeon/"

var mroot: Node3D
var colliders: Node3D
var rng := RandomNumberGenerator.new()
var multimesh_items: Dictionary = {}
var _fp_cache: Dictionary = {}
var _roads: Array = []                 # PackedVector2Array — для рассыпанных деревьев (не на дорогах)
var _keep_out: Array = []              # [центр, радиус] — площади баз, лагеря, арена

func _init() -> void:
	rng.seed = 20261018
	mroot = Node3D.new()
	mroot.name = "Map"
	colliders = _add(mroot, Node3D.new(), "Colliders")
	_environment()
	_ground()
	_plan_roads()
	_roads_mesh()
	for team in 2:
		_base(team)
	_duel_arena()
	_camps()
	_bounds()
	_scatter()
	_flush_multimeshes()
	var ps := PackedScene.new()
	var err := ps.pack(mroot)
	if err == OK:
		err = ResourceSaver.save(ps, "res://scenes/map_arena.tscn")
	print("map_arena bake: ", error_string(err))
	mroot.free()
	quit()

# ---------------------------------------------------------------- утилиты (как в bake_map_lines.gd)

func _m(p: Vector2, team: int) -> Vector2:
	return A.mirror(p, team)

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

func _dist_to_roads(p: Vector2) -> float:
	var best := 1e9
	for road: PackedVector2Array in _roads:
		for i in road.size() - 1:
			best = minf(best, Geometry2D.get_closest_point_to_segment(p, road[i], road[i + 1]).distance_to(p))
	return best

func _in_keep_out(p: Vector2, margin: float) -> bool:
	for k in _keep_out:
		if p.distance_to(k[0]) < float(k[1]) + margin:
			return true
	return false

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

# ---------------------------------------------------------------- дороги

## Дороги: от каждой базы к арене, кольцо вокруг арены, ответвления к лагерям.
func _plan_roads() -> void:
	for team in 2:
		var b: Vector2 = A.BASE
		_roads.append(_mirror_line([b + Vector2(0, -6), Vector2(0, 60), Vector2(0, 28)], team))
		for c in A.CAMPS:
			var cp: Vector2 = c["pos"]
			var from := Vector2(0, clampf(cp.y, 28.0, 80.0)) if absf(cp.x) > 20.0 else b
			_roads.append(_mirror_line([from, from.lerp(cp, 0.5) + Vector2(0, 4), cp], team))
	var ring := PackedVector2Array()
	for i in 33:
		var a := TAU * i / 32.0
		ring.append(Vector2(cos(a), sin(a)) * 28.0)
	_roads.append(ring)
	# дорога от центра к арене дуэлей на краю
	_roads.append(PackedVector2Array([Vector2(28, 0), Vector2(55, -2), A.DUEL_CENTER - Vector2(A.DUEL_RADIUS + 1.0, 0)]))

func _mirror_line(pts: Array, team: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p: Vector2 in pts:
		out.append(_m(p, team))
	return out

func _roads_mesh() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for road: PackedVector2Array in _roads:
		_ribbon(st, road, 6.0, 2.5)
	for team in 2:
		_disc(st, _m(A.BASE, team), 24.0, 4.0)
	_disc(st, A.DUEL_CENTER, A.DUEL_RADIUS + 1.0, 2.0)
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

func _disc(st: SurfaceTool, c: Vector2, r: float, fade: float) -> void:
	var seg := 40
	for i in seg:
		var a0 := TAU * i / seg
		var a1 := TAU * (i + 1) / seg
		for ring in [[0.0, r, 1.0, 1.0], [r, r + fade, 1.0, 0.0]]:
			var v := [Vector3(c.x + cos(a0) * ring[0], 0.025, c.y + sin(a0) * ring[0]), Vector3(c.x + cos(a1) * ring[0], 0.025, c.y + sin(a1) * ring[0]),
				Vector3(c.x + cos(a1) * ring[1], 0.025, c.y + sin(a1) * ring[1]), Vector3(c.x + cos(a0) * ring[1], 0.025, c.y + sin(a0) * ring[1])]
			var al := [ring[2], ring[2], ring[3], ring[3]]
			for idx in [0, 2, 1, 0, 3, 2]:
				st.set_color(Color(1, 1, 1, al[idx]))
				st.set_normal(Vector3.UP)
				st.add_vertex(v[idx])

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

# ---------------------------------------------------------------- база

func _base(team: int) -> void:
	var town := _add(mroot, Node3D.new(), "Base%d" % team)
	var flag: String = PROPS + ("flag_blue.gltf" if team == 0 else "flag_red.gltf")
	var banner: String = DUNGEON + ("banner_triple_blue.gltf.glb" if team == 0 else "banner_triple_red.gltf.glb")
	var b: Vector2 = A.BASE
	_keep_out.append([_m(b + Vector2(0, 6), team), 34.0])
	# замок (цель «разрушить базу») — за площадью
	var cp := _m(b + A.CASTLE_OFF, team)
	_place(TOWN + "building_castle_blue.gltf", cp, _my(PI, team), S, town)
	_box(cp, Vector3(9.0, 20.0, 10.0))
	var bases: Node = mroot.get_node_or_null("Bases")
	if bases == null:
		bases = _add(mroot, Node3D.new(), "Bases")
	var bm := Marker3D.new()
	bm.position = Vector3(cp.x, 0, cp.y)
	bm.set_meta("radius", A.BASE_RADIUS)
	_add(bases, bm, "Base%d" % team)
	# воскрешение и фонтан (колодец)
	var hs := Marker3D.new()
	var sp := _m(b + A.SPAWN_OFF, team)
	hs.position = Vector3(sp.x, 0, sp.y)
	hs.set_meta("yaw", _my(0.0, team))
	_add(mroot, hs, "HeroSpawn%d" % team)
	var fp := _m(b + A.FOUNTAIN_OFF, team)
	_place(TOWN + "building_well_blue.gltf", fp, _my(0.0, team), S * 0.9, town)
	_cyl(fp, 2.0, 4.0)
	var fm := Marker3D.new()
	fm.position = Vector3(fp.x, 0, fp.y)
	_add(mroot, fm, "Fountain%d" % team)
	# лавки: здание за торговцем (дальше от центра карты), торговец — лицом к центру
	var shops: Node = mroot.get_node_or_null("Shops")
	if shops == null:
		shops = _add(mroot, Node3D.new(), "Shops")
	var look := {"smith": ["building_blacksmith_blue.gltf", "Blacksmith", Vector3(6.4, 5, 6.2)],
		"alchemist": ["building_tavern_blue.gltf", "Alchemy", Vector3(5.8, 7, 6.6)],
		"crafter": ["building_market_blue.gltf", "Crafter", Vector3(6.0, 5, 6.0)],
		"bookseller": ["building_church_blue.gltf", "Bookseller", Vector3(6.0, 8, 7.0)]}
	for shop in A.SHOPS:
		var kind: String = shop[0]
		var off: Vector2 = shop[1]
		var mp := _m(b + off, team)
		var bp := _m(b + off + Vector2(0, 7.5), team)
		var rot := _my(PI, team)
		_place(TOWN + look[kind][0], bp, rot, S * 0.85, town)
		_box(bp, look[kind][2] * 0.85, rot)
		var mk := Marker3D.new()
		mk.position = Vector3(mp.x, 0, mp.y)
		mk.set_meta("yaw", _my(0.0, team))
		_add(shops, mk, "%s_%d" % [look[kind][1], team])
	# башни базы (из них стреляет база), флаги, знамёна
	for o in [Vector2(-20, -18), Vector2(20, -18)]:
		var p := _m(b + o, team)
		_place(TOWN + "building_tower_A_blue.gltf", p, 0.0, S * 0.8, town)
		_cyl(p, 2.2, 12.0)
	for o in [Vector2(-8, -8), Vector2(8, -8), Vector2(-30, 6), Vector2(30, 6)]:
		_place(flag, _m(b + o, team), _my(0.0, team), S, town)
	for o in [Vector2(-5, 6), Vector2(5, 6)]:
		_place(banner, _m(b + o, team), _my(0.0, team), 1.5, town)
	for pr in [["barrel.gltf", Vector2(-28, -4)], ["crate_A_big.gltf", Vector2(28, -4)], ["weaponrack.gltf", Vector2(-17, -5)], ["sack.gltf", Vector2(17, -5)]]:
		var p: Vector2 = _m(b + pr[1], team)
		_place(PROPS + pr[0], p, rng.randf() * TAU, S, town)
		_cyl(p, maxf(0.35, _footprint(PROPS + pr[0]) * S * 0.5), 2.0)
	# стена за базой и по бокам (база открыта к центру карты)
	for ox in range(-40, 41, 10):
		var p := _m(b + Vector2(ox, 22), team)
		_place(TOWN + "wall_straight.gltf", p, _my(0.0, team), S, town)
		_box(p, Vector3(10.2, 6.0, 4.0))
	for side in [-1.0, 1.0]:
		for oz in [-2.0, 8.0, 18.0]:
			var p := _m(b + Vector2(side * 42.0, oz), team)
			_place(TOWN + "wall_straight.gltf", p, _my(PI * 0.5, team), S, town)
			_box(p, Vector3(4.0, 6.0, 10.2))

# ---------------------------------------------------------------- арена дуэлей

## Закрытый круг: каменная ограда с коллайдером (пройти нельзя — дуэлянтов переносит режим), снаружи — скамьи
## и знамёна для зрителей. Ограда низкая — зрителям видно бой.
func _duel_arena() -> void:
	var g := _add(mroot, Node3D.new(), "DuelArenaProps")
	var c: Vector2 = A.DUEL_CENTER
	var r: float = A.DUEL_RADIUS
	_keep_out.append([c, r + 10.0])
	var mk := Marker3D.new()
	mk.position = Vector3(c.x, 0, c.y)
	mk.set_meta("radius", r)
	_add(mroot, mk, "DuelArena")
	var n := 20
	for i in n:
		var a := TAU * (float(i) + 0.5) / float(n)
		var p := c + Vector2(cos(a), sin(a)) * (r + 0.6)
		var seg_len := TAU * (r + 0.6) / float(n)
		var rot := -a + PI * 0.5
		# у модели ограды длинная сторона — по оси Z: поворот на четверть круга, растяжка по Z
		var f := _place(TOWN + "fence_stone_straight.gltf", p, rot + PI * 0.5, S * 0.9, g)
		f.scale.z = seg_len / maxf(0.05, _fence_len())
		_box(p, Vector3(seg_len + 0.4, 6.0, 1.2), rot)
	for i in 12:
		var a := TAU * float(i) / 12.0
		var p := c + Vector2(cos(a), sin(a)) * (r + 4.5)
		_place(GRAVE + "bench.gltf", p, -a + PI * 0.5, 1.8, g)
	for i in 4:
		var a := TAU * float(i) / 4.0 + PI * 0.25
		var p := c + Vector2(cos(a), sin(a)) * (r + 2.4)
		_place(GRAVE + "pillar.gltf", p, 0.0, 1.6, g)
		_cyl(p, 0.7, 6.0)
		_place(DUNGEON + ("banner_patternA_blue.gltf.glb" if i % 2 == 0 else "banner_patternA_red.gltf.glb"), p + Vector2(cos(a), sin(a)) * 1.4, -a + PI * 0.5, 1.5, g)

## Длина модели ограды по Z (в её масштабе 1).
func _fence_len() -> float:
	var inst := (load(TOWN + "fence_stone_straight.gltf") as PackedScene).instantiate() as Node3D
	var box := AABB()
	var first := true
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		var bb: AABB = (mi as MeshInstance3D).mesh.get_aabb()
		box = bb if first else box.merge(bb)
		first = false
	inst.free()
	return box.size.z

# ---------------------------------------------------------------- лагеря

## Лагерь — точка + убранство по фракции (палатки орков, могилы нежити, обломки демонов, ящики гоблинов);
## у логова босса — арка и фонари. Монстров ставит режим (данные — arena_data.CAMPS).
func _camps() -> void:
	var holder := _add(mroot, Node3D.new(), "Camps")
	for c in A.all_camps():
		var p: Vector2 = c["pos"]
		_keep_out.append([p, 11.0])
		var mk := Marker3D.new()
		mk.position = Vector3(p.x, 0, p.y)
		mk.set_meta("tier", int(c["tier"]))
		_add(holder, mk, str(c["id"]))
		var deco: Array = []
		match str(c.get("faction", "")):
			"undead":
				deco = [[GRAVE + "grave_A.gltf", 1.6], [GRAVE + "gravestone.gltf", 1.6], [GRAVE + "tree_dead_medium.gltf", 1.6], [GRAVE + "post_skull.gltf", 1.6]]
			"orcs":
				deco = [[PROPS + "tent.gltf", S], [PROPS + "weaponrack.gltf", S], [PROPS + "barrel.gltf", S], [PROPS + "resource_lumber.gltf", S]]
			"demons":
				deco = [[TOWN + "building_destroyed.gltf", S * 0.7], [GRAVE + "skull_candle.gltf", 1.8], [GRAVE + "ribcage.gltf", 1.6], [GRAVE + "candle_triple.gltf", 1.6]]
			_:
				deco = [[PROPS + "crate_A_big.gltf", S], [PROPS + "crate_long_A.gltf", S], [PROPS + "wheelbarrow.gltf", S], [PROPS + "barrel.gltf", S]]
		var k := 5 if int(c["tier"]) >= 3 else 4
		for i in k:
			var a := TAU * float(i) / float(k) + rng.randf() * 0.5
			var dp := p + Vector2(cos(a), sin(a)) * rng.randf_range(7.5, 9.5)
			var d: Array = deco[i % deco.size()]
			_place(d[0], dp, rng.randf() * TAU, d[1], holder)
			_cyl(dp, maxf(0.4, _footprint(d[0]) * float(d[1]) * 0.45), 2.5)
		if int(c["tier"]) == 4:
			var to := (Vector2.ZERO - p).normalized()
			var ap := p + to * 9.0
			_place(GRAVE + "arch_gate.gltf", ap, atan2(to.x, to.y), 2.2, holder)
			for s in [-1.0, 1.0]:
				var side: Vector2 = Vector2(-to.y, to.x) * s * 4.4
				_cyl(ap + side, 0.6, 6.0)
				_place(GRAVE + "post_lantern.gltf", ap + side * 1.5 + to * 1.5, 0.0, 1.8, holder)

# ---------------------------------------------------------------- края карты

func _bounds() -> void:
	var mountains := ["mountain_A_grass_trees.gltf", "mountain_B_grass_trees.gltf", "mountain_C_grass_trees.gltf", "mountain_A_grass.gltf", "mountain_B.gltf"]
	for side in [-1.0, 1.0]:
		var z := -H
		while z < H - 1.0:
			var len := minf(40.0, H - z)
			_box(Vector2(side * (H + 2.0), z + len * 0.5), Vector3(4.0, 20.0, len))
			_box(Vector2(z + len * 0.5, side * (H + 2.0)), Vector3(len, 20.0, 4.0))
			z += len
		var t := -H - 12.0
		while t <= H + 12.0:
			for axis in 2:
				var item: String = mountains[rng.randi() % mountains.size()]
				var s := rng.randf_range(7.0, 10.0)
				var off: float = side * (H + rng.randf_range(8, 16))
				var p := Vector2(off, t) if axis == 0 else Vector2(t, off)
				_mm(NATURE + item, p, rng.randf() * TAU, Vector3(s, s * rng.randf_range(0.8, 1.3), s))
			t += 11.0

## Рощи, камни и одиночные деревья — не на дорогах, не у баз, лагерей и арены.
func _scatter() -> void:
	for i in 520:
		var p := Vector2(rng.randf_range(-H + 4, H - 4), rng.randf_range(-H + 4, H - 4))
		if _in_keep_out(p, 3.0):
			continue
		var dr := _dist_to_roads(p)
		if dr < 6.0:
			continue
		if rng.randf() < 0.35:
			var item := "rock_single_%s.gltf" % ["A", "B", "C", "D", "E"][rng.randi() % 5]
			var s := rng.randf_range(2.5, 4.5)
			_mm(NATURE + item, p, rng.randf() * TAU, Vector3.ONE * s)
			var r := _footprint(NATURE + item) * s * 0.7
			if dr > r + 3.0:
				_cyl(p, maxf(0.35, r), 3.0)
		else:
			var item: String = ["tree_single_A.gltf", "tree_single_B.gltf", "trees_A_small.gltf", "trees_B_small.gltf", "trees_A_medium.gltf"][rng.randi() % 5]
			var s := TREE_S * rng.randf_range(0.8, 1.15)
			_mm(NATURE + item, p, rng.randf() * TAU, Vector3.ONE * s)
			if dr > 6.5:
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
