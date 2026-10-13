class_name Vfx
extends RefCounted
## Визуальные эффекты заклинаний. Только картинка — на игровую логику не влияют.
## Частицы считаются на видеокарте (GPUParticles3D), чтобы не нагружать процессор.

const RING_SHADER := preload("res://shaders/ring.gdshader")
const DOME_SHADER := preload("res://shaders/dome.gdshader")

const COL_FROST := Color(0.55, 0.85, 1.0)
const COL_FIRE := Color(1.0, 0.45, 0.1)
const COL_ARCANE := Color(0.8, 0.45, 1.0)
const COL_HOLY := Color(1.0, 0.85, 0.4)
const COL_HEAL := Color(0.75, 1.0, 0.55)
const COL_SHADOW := Color(0.55, 0.25, 0.85)

static var _dot_tex: Texture2D
static var _fade_ramp: GradientTexture1D
static var _draw_mats: Dictionary = {}
static var _ice_mat: StandardMaterial3D
static var zones: Dictionary = {}

# ---------------------------------------------------------------- материалы

static func ring_material(col: Color, fill: float = 0.15, runes: bool = false, energy: float = 1.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = RING_SHADER
	m.set_shader_parameter("color", col)
	m.set_shader_parameter("fill", fill)
	m.set_shader_parameter("runes", 1.0 if runes else 0.0)
	m.set_shader_parameter("energy", energy)
	return m

static func dome_material(col: Color, energy: float = 1.0, scroll: float = 0.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = DOME_SHADER
	m.set_shader_parameter("color", col)
	m.set_shader_parameter("energy", energy)
	m.set_shader_parameter("scroll", scroll)
	return m

static func preview_material(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(col.r, col.g, col.b, 0.35)
	m.no_depth_test = false
	return m

static func ice_material() -> StandardMaterial3D:
	if _ice_mat == null:
		_ice_mat = StandardMaterial3D.new()
		_ice_mat.albedo_color = Color(0.7, 0.9, 1.0, 0.82)
		_ice_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ice_mat.metallic = 0.2
		_ice_mat.roughness = 0.08
		_ice_mat.rim_enabled = true
		_ice_mat.rim = 0.8
		_ice_mat.emission_enabled = true
		_ice_mat.emission = Color(0.25, 0.55, 0.9)
		_ice_mat.emission_energy_multiplier = 0.6
	return _ice_mat

static func _dot() -> Texture2D:
	if _dot_tex == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		g.add_point(0.35, Color(1, 1, 1, 0.6))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = 64
		t.height = 64
		_dot_tex = t
	return _dot_tex

static func _ramp() -> GradientTexture1D:
	if _fade_ramp == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 0.0))
		g.set_color(1, Color(1, 1, 1, 0.0))
		g.add_point(0.15, Color(1, 1, 1, 1))
		g.add_point(0.6, Color(1, 1, 1, 0.8))
		_fade_ramp = GradientTexture1D.new()
		_fade_ramp.gradient = g
	return _fade_ramp

static func _draw_mat(additive: bool) -> StandardMaterial3D:
	if not _draw_mats.has(additive):
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		if additive:
			m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.vertex_color_use_as_albedo = true
		m.albedo_texture = _dot()
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		_draw_mats[additive] = m
	return _draw_mats[additive]

## Универсальный источник частиц.
static func particles(parent: Node3D, col: Color, amount: int, life: float, opts: Dictionary = {}) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	var pm := ParticleProcessMaterial.new()
	pm.color = col
	pm.color_ramp = _ramp()
	match opts.get("shape", "sphere"):
		"sphere":
			pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
			pm.emission_sphere_radius = opts.get("radius", 0.3)
		"box":
			pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
			pm.emission_box_extents = opts.get("extents", Vector3.ONE)
		"ring":
			pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
			pm.emission_ring_axis = Vector3.UP
			pm.emission_ring_radius = opts.get("radius", 3.0)
			pm.emission_ring_inner_radius = opts.get("inner", 0.0)
			pm.emission_ring_height = opts.get("height", 0.1)
	pm.direction = opts.get("dir", Vector3.UP)
	pm.spread = opts.get("spread", 30.0)
	pm.initial_velocity_min = opts.get("vmin", 1.0)
	pm.initial_velocity_max = opts.get("vmax", 2.0)
	pm.gravity = opts.get("gravity", Vector3.ZERO)
	pm.scale_min = opts.get("smin", 0.5)
	pm.scale_max = opts.get("smax", 1.0)
	pm.damping_min = opts.get("damping", 0.0)
	pm.damping_max = opts.get("damping", 0.0)
	p.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2.ONE * float(opts.get("size", 0.5))
	q.material = _draw_mat(opts.get("additive", true))
	p.draw_pass_1 = q
	p.amount = amount
	p.lifetime = life
	p.one_shot = opts.get("one_shot", false)
	p.explosiveness = opts.get("explosive", 0.0)
	p.local_coords = opts.get("local", false)
	var r := float(opts.get("aabb", 6.0))
	p.visibility_aabb = AABB(Vector3(-r, -2, -r), Vector3(r * 2, r + 8, r * 2))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if opts.has("pos"):
		p.position = opts["pos"]
	parent.add_child(p)
	p.emitting = true
	return p

static func school_color(school: String) -> Color:
	match school:
		"frost": return COL_FROST
		"fire": return COL_FIRE
		"arcane": return COL_ARCANE
		"holy": return COL_HOLY
		"shadow": return COL_SHADOW
	return Color(1, 1, 1)

static func unit_pos(world: Node3D, id: int, height: float = 1.2) -> Variant:
	var u: Unit = world.get_unit(id)
	if u == null:
		return null
	var base := u.pos
	if u.node and is_instance_valid(u.node):
		base = u.node.global_position
	return base + Vector3(0, height * (u.radius / 0.6 if u.kind == "mob" else 1.0), 0)

# ---------------------------------------------------------------- узлы-эффекты

## Эффект, который живёт заданное время и плавно исчезает.
class TimedFx extends Node3D:
	var life := 1.0
	var age := 0.0
	var fade_in := 0.15
	var fade_out := 0.4
	var mats: Array = []
	var follow_id := 0
	var follow_h := 0.0
	var world: Node3D
	var stop_particles_at := -1.0
	func _process(delta: float) -> void:
		age += delta
		if follow_id != 0 and world:
			var p = Vfx.unit_pos(world, follow_id, follow_h)
			if p != null:
				global_position = p
		var f := 1.0
		if age < fade_in:
			f = age / fade_in
		elif age > life - fade_out:
			f = maxf(0.0, (life - age) / fade_out)
		for m in mats:
			m.set_shader_parameter("fade", f)
		if stop_particles_at >= 0.0 and age >= stop_particles_at:
			stop_particles_at = -1.0
			for c in get_children():
				if c is GPUParticles3D:
					c.emitting = false
		if age >= life:
			queue_free()

class Projectile extends Node3D:
	var world: Node3D
	var to_id := 0
	var speed := 20.0
	var color := Color.WHITE
	var last_target := Vector3.ZERO
	var kind := ""
	func _process(delta: float) -> void:
		var p = Vfx.unit_pos(world, to_id, 1.1)
		if p != null:
			last_target = p
		var to := last_target - global_position
		var step := speed * delta
		if to.length() <= step:
			Vfx.burst(world, last_target, color, kind)
			match kind:
				"frost": Sfx.play_at("ice_shatter", last_target, -4.0)
				"fire": Sfx.play_at("fire_burn", last_target, -4.0)
				"physical": Sfx.play_at("hit_bone", last_target)
			queue_free()
			return
		global_position += to.normalized() * step
		look_at(last_target, Vector3.UP)

static func _timed(world: Node3D, pos: Vector3, life: float) -> TimedFx:
	var n := TimedFx.new()
	n.life = life
	n.world = world
	world.vfx_root.add_child(n)
	n.global_position = pos
	return n

static func _ring(parent: Node3D, radius: float, col: Color, fill: float, runes: bool, energy: float, holder: TimedFx) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(2, 2)
	mi.mesh = pm
	mi.scale = Vector3(radius, 1, radius)
	mi.position.y = 0.07
	var mat := ring_material(col, fill, runes, energy)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	if holder:
		holder.mats.append(mat)
	return mi

# ---------------------------------------------------------------- публичное API

static func projectile(world: Node3D, kind: String, from_id: int, to_id: int, speed: float) -> void:
	var start = unit_pos(world, from_id, 1.6)
	if start == null:
		return
	var school := kind.trim_prefix("bolt_")
	var col := school_color(school)
	var pr := Projectile.new()
	pr.world = world
	pr.to_id = to_id
	pr.speed = speed
	pr.color = col
	pr.kind = school
	world.vfx_root.add_child(pr)
	var fwd := Vector3.ZERO
	var fu: Unit = world.get_unit(from_id)
	if fu and fu.node:
		fwd = -fu.node.global_transform.basis.z * 0.6
	pr.global_position = start + fwd
	match school:
		"frost": Sfx.play_at("frost_bolt", pr.global_position)
		"fire": Sfx.play_at("fire", pr.global_position)
		"arcane": Sfx.play_at("arcane", pr.global_position, -3.0)
		"holy": Sfx.play_at("holy", pr.global_position, -6.0)
		"shadow": Sfx.play_at("arcane", pr.global_position, -10.0)
	var t = unit_pos(world, to_id, 1.1)
	pr.last_target = t if t != null else pr.global_position
	var core := MeshInstance3D.new()
	var sm := SphereMesh.new()
	var big := school == "fire"
	sm.radius = 0.32 if big else 0.22
	sm.height = sm.radius * 2.0
	sm.radial_segments = 10
	sm.rings = 6
	core.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col.lightened(0.5)
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 4.0
	core.material_override = mat
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pr.add_child(core)
	particles(pr, col, 24 if big else 16, 0.45, {"radius": 0.15, "vmin": 0.2, "vmax": 0.8, "spread": 180.0,
		"smin": 0.6, "smax": 1.2, "size": 0.55 if big else 0.4})

static func burst(world: Node3D, pos: Vector3, col: Color, kind: String = "") -> void:
	var n := _timed(world, pos, 1.0)
	var big := kind == "fire"
	particles(n, col, 30 if big else 18, 0.6, {"one_shot": true, "explosive": 0.95, "spread": 180.0,
		"vmin": 2.0, "vmax": 5.0 if big else 3.5, "damping": 4.0, "smin": 0.6, "smax": 1.3,
		"gravity": Vector3(0, -2 if kind != "frost" else -6, 0)})

static func level_up(world: Node3D, hero: Node3D) -> void:
	var n := _timed(world, hero.global_position, 2.2)
	n.follow_id = hero.unit.id
	n.follow_h = 0.0
	var col := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.0
	cm.bottom_radius = 1.2
	cm.height = 9.0
	cm.cap_top = false
	cm.cap_bottom = false
	col.mesh = cm
	col.position.y = 4.5
	var mat := dome_material(COL_HOLY, 2.5, 6.0)
	col.material_override = mat
	n.mats.append(mat)
	n.add_child(col)
	particles(n, COL_HOLY, 60, 1.4, {"shape": "ring", "radius": 1.4, "vmin": 3.0, "vmax": 6.0, "spread": 10.0, "smin": 0.5, "smax": 1.0})
	n.stop_particles_at = 1.0

const SPAWN_SOUNDS := {
	"hit_holy": "sword", "hit_fire": "fire", "beam_holy": "holy", "heal_burst": "heal", "heal_small": "heal",
	"shield": "shield", "bubble": "shield", "heal_circle": "heal", "nova_frost": "frost_big", "nova_holy": "holy",
	"rooted": "ice_shatter", "ice_block": "frost_big", "aura_arcane": "arcane", "aura_holy": "shield",
	"explosion_fire": "fire_big", "chain_arcane": "arcane", "chain_holy": "holy",
	"frozen": "ice_shatter", "nova_arcane": "arcane", "blink": "arcane",
}

static func spawn(world: Node3D, kind: String, pos: Vector3, from: Vector3, param: float, unit_id: int) -> void:
	if SPAWN_SOUNDS.has(kind):
		Sfx.play_at(SPAWN_SOUNDS[kind], pos + Vector3(0, 1, 0), -4.0 if kind == "heal_small" or kind.begins_with("chain") else 0.0)
	if kind == "hit_holy":
		Sfx.play_at("hit_bone", pos + Vector3(0, 1, 0))
	match kind:
		"hit_holy":
			burst(world, pos + Vector3(0, 1.2, 0), COL_HOLY)
		"hit_fire":
			burst(world, pos + Vector3(0, 1.2, 0), COL_FIRE, "fire")
		"frozen":
			burst(world, pos + Vector3(0, 1.2, 0), COL_FROST, "frost")
		"blink":
			var n := _timed(world, pos, 0.8)
			var ring := _ring(n, 0.4, COL_ARCANE, 0.3, false, 2.0, n)
			ring.create_tween().tween_property(ring, "scale", Vector3(2.5, 1, 2.5), 0.3).set_ease(Tween.EASE_OUT)
			particles(n, COL_ARCANE, 40, 0.6, {"radius": 0.6, "pos": Vector3(0, 1.2, 0), "vmin": 2.0, "vmax": 4.0,
				"spread": 180.0, "damping": 4.0, "one_shot": true, "explosive": 0.9, "smin": 0.6, "smax": 1.1})
		"aura_arcane", "aura_holy":
			# сияние вокруг героя на время усиления
			var c := COL_ARCANE if kind == "aura_arcane" else COL_HOLY
			var n := _timed(world, pos, maxf(param, 1.0))
			n.follow_id = unit_id
			n.follow_h = 0.0
			_ring(n, 1.4, c, 0.2, true, 1.6, n)
			particles(n, c, 24, 1.2, {"shape": "ring", "radius": 0.9, "vmin": 0.8, "vmax": 1.8, "spread": 10.0,
				"smin": 0.4, "smax": 0.8, "size": 0.4})
			burst(world, pos + Vector3(0, 1.2, 0), c)
		"ice_block":
			spawn(world, "rooted", pos, from, 4.0, unit_id)
			burst(world, pos + Vector3(0, 1.0, 0), COL_FROST, "frost")
		"bomb_mark":
			var n := _timed(world, pos, param)
			n.follow_id = unit_id
			n.follow_h = 1.4
			n.fade_out = 0.1
			particles(n, COL_FIRE, 14, 0.5, {"radius": 0.35, "vmin": 0.5, "vmax": 1.2, "smin": 0.6, "smax": 1.1, "size": 0.5})
		"explosion_fire":
			var n := _timed(world, pos, 1.2)
			var ring := _ring(n, 0.5, COL_FIRE, 0.4, false, 2.5, n)
			ring.create_tween().tween_property(ring, "scale", Vector3(param, 1, param), 0.25).set_ease(Tween.EASE_OUT)
			particles(n, Color(1.0, 0.55, 0.15), 80, 0.7, {"radius": 1.0, "vmin": param * 1.2, "vmax": param * 2.2,
				"spread": 180.0, "damping": param * 1.5, "one_shot": true, "explosive": 1.0, "smin": 1.2, "smax": 2.2,
				"size": 0.8, "aabb": param + 3.0})
		"beam_holy":
			var n := _timed(world, pos, 0.8)
			n.fade_in = 0.05
			n.fade_out = 0.6
			var col := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.8
			cm.bottom_radius = 0.6
			cm.height = 14.0
			cm.cap_top = false
			cm.cap_bottom = false
			col.mesh = cm
			col.position.y = 7.0
			var mat := dome_material(COL_HOLY, 3.0, 12.0)
			col.material_override = mat
			n.mats.append(mat)
			n.add_child(col)
			burst(world, pos + Vector3(0, 1.0, 0), COL_HOLY)
		"heal_burst", "heal_small":
			var big := kind == "heal_burst"
			var n := _timed(world, pos, 1.6)
			n.follow_id = unit_id
			_ring(n, 1.6 if big else 1.1, COL_HEAL, 0.25, false, 1.6, n)
			particles(n, COL_HEAL.lerp(COL_HOLY, 0.4), 40 if big else 20, 1.1, {"shape": "ring", "radius": 1.0, "inner": 0.3,
				"vmin": 1.5, "vmax": 3.0, "spread": 15.0, "smin": 0.4, "smax": 0.9, "size": 0.4})
			n.stop_particles_at = 0.4
		"shield":
			burst(world, pos + Vector3(0, 1.2, 0), COL_HOLY)
		"bubble":
			burst(world, pos + Vector3(0, 1.2, 0), COL_HOLY)
		"heal_circle":
			var n := _timed(world, pos, 1.2)
			var ring := _ring(n, 1.0, COL_HEAL, 0.05, false, 1.5, n)
			ring.create_tween().tween_property(ring, "scale", Vector3(param, 1, param), 0.5).set_ease(Tween.EASE_OUT)
		"nova_frost", "nova_holy", "nova_arcane":
			var c := COL_FROST if kind == "nova_frost" else (COL_ARCANE if kind == "nova_arcane" else COL_HOLY)
			var n := _timed(world, pos, 1.3)
			var ring := _ring(n, 0.5, c, 0.35, false, 2.0, n)
			ring.create_tween().tween_property(ring, "scale", Vector3(param, 1, param), 0.35).set_ease(Tween.EASE_OUT)
			particles(n, c, 70, 0.8, {"shape": "ring", "radius": 1.0, "vmin": param * 1.6, "vmax": param * 2.4,
				"dir": Vector3(1, 0, 0), "spread": 180.0, "damping": param, "one_shot": true, "explosive": 1.0,
				"smin": 0.6, "smax": 1.2, "aabb": param + 2.0})
		"rooted":
			var n := _timed(world, pos, param)
			n.follow_id = unit_id
			n.follow_h = 0.0
			n.fade_out = 0.3
			var ice := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.7
			cm.bottom_radius = 0.9
			cm.height = 0.9
			cm.radial_segments = 6
			ice.mesh = cm
			ice.position.y = 0.45
			ice.material_override = ice_material()
			n.add_child(ice)
		"stunned":
			var n := _timed(world, pos, param)
			n.follow_id = unit_id
			n.follow_h = 2.6
			n.fade_out = 0.2
			particles(n, COL_HOLY, 8, 0.6, {"shape": "ring", "radius": 0.5, "vmin": 0.1, "vmax": 0.3, "smin": 0.4, "smax": 0.6, "local": true})
		_:
			if kind.begins_with("chain_"):
				var c := school_color(kind.trim_prefix("chain_"))
				var a := from + Vector3(0, 1.2, 0)
				var b := pos + Vector3(0, 1.2, 0)
				var n := _timed(world, (a + b) * 0.5, 0.35)
				n.fade_in = 0.02
				n.fade_out = 0.3
				var beam := MeshInstance3D.new()
				var bm := BoxMesh.new()
				bm.size = Vector3(0.12, 0.12, maxf(0.1, a.distance_to(b)))
				beam.mesh = bm
				var mat := dome_material(c, 3.0)
				mat.set_shader_parameter("base_alpha", 0.8)
				beam.material_override = mat
				n.mats.append(mat)
				n.add_child(beam)
				if a.distance_to(b) > 0.2:
					n.look_at(b, Vector3.UP)
				burst(world, b, c)

## Долгие эффекты на земле: области, стены, купол.
static func zone(world: Node3D, id: int, kind: String, pos: Vector3, yaw: float, size: float, duration: float) -> void:
	var n := _timed(world, Vector3(pos.x, 0, pos.z), duration)
	n.fade_out = 0.6
	n.rotation.y = yaw
	zones[id] = n
	n.tree_exiting.connect(func(): zones.erase(id))
	var snd := {"zone_blizzard": "frost_big", "zone_flamestrike": "fire_big", "zone_consecration": "holy",
		"zone_barrier": "shield", "wall_ice": "frost_big", "wall_fire": "fire_burn"}
	if snd.has(kind):
		Sfx.play_at(snd[kind], n.global_position + Vector3(0, 1, 0))
	if kind == "wall_ice":
		Sfx.play_at("ice_shatter", n.global_position + Vector3(0, 1, 0))
	match kind:
		"zone_blizzard":
			_ring(n, size, COL_FROST, 0.18, false, 1.4, n)
			particles(n, Color(0.85, 0.95, 1.0), int(size * 22), 1.1, {"shape": "box", "extents": Vector3(size * 0.7, 0.5, size * 0.7),
				"pos": Vector3(0, 9, 0), "dir": Vector3(0.15, -1, 0.1), "spread": 6.0, "vmin": 10.0, "vmax": 14.0,
				"smin": 0.5, "smax": 1.0, "size": 0.35, "aabb": size + 2.0})
			particles(n, Color(0.7, 0.85, 1.0, 0.5), 30, 2.0, {"shape": "ring", "radius": size * 0.8, "vmin": 0.3, "vmax": 0.8,
				"smin": 3.0, "smax": 5.0, "size": 0.8, "additive": false, "aabb": size + 2.0})
			n.stop_particles_at = duration - 1.0
		"zone_flamestrike":
			_ring(n, size, COL_FIRE, 0.3, false, 1.8, n)
			# столб пламени в момент удара
			var pillar := _timed(world, n.global_position, 0.7)
			pillar.fade_in = 0.05
			pillar.fade_out = 0.5
			var col := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = size * 0.35
			cm.bottom_radius = size * 0.8
			cm.height = 12.0
			cm.cap_top = false
			cm.cap_bottom = false
			col.mesh = cm
			col.position.y = 6.0
			var pmat := dome_material(COL_FIRE, 3.0, 14.0)
			col.material_override = pmat
			pillar.mats.append(pmat)
			pillar.add_child(col)
			particles(pillar, Color(1.0, 0.6, 0.2), 90, 0.6, {"shape": "ring", "radius": size * 0.6, "vmin": 4.0, "vmax": 9.0,
				"spread": 10.0, "one_shot": true, "explosive": 0.9, "smin": 1.5, "smax": 2.5, "size": 1.0, "aabb": size + 4.0, "damping": 3.0})
			# горящая земля
			particles(n, Color(1.0, 0.45, 0.1), int(size * 18), 0.55, {"shape": "ring", "radius": size * 0.9, "vmin": 1.5, "vmax": 3.5,
				"spread": 8.0, "smin": 1.0, "smax": 1.8, "size": 0.8, "aabb": size + 2.0})
			n.stop_particles_at = duration - 0.8
		"zone_consecration":
			_ring(n, size, COL_HOLY, 0.28, true, 1.6, n)
			particles(n, COL_HOLY, int(size * 8), 1.4, {"shape": "ring", "radius": size * 0.9, "vmin": 0.6, "vmax": 1.4,
				"smin": 0.3, "smax": 0.6, "size": 0.35, "aabb": size + 1.0})
			n.stop_particles_at = duration - 1.0
		"zone_barrier":
			_ring(n, size, COL_HOLY, 0.12, true, 1.4, n)
			var dome := MeshInstance3D.new()
			var sm := SphereMesh.new()
			sm.radius = size
			sm.height = size
			sm.is_hemisphere = true
			dome.mesh = sm
			var mat := dome_material(Color(1.0, 0.9, 0.55), 1.3, 2.0)
			dome.material_override = mat
			n.mats.append(mat)
			n.add_child(dome)
			particles(n, COL_HOLY, 24, 2.5, {"shape": "ring", "radius": size * 0.95, "vmin": 0.8, "vmax": 1.6,
				"smin": 0.3, "smax": 0.6, "size": 0.35, "aabb": size + 1.0})
			n.stop_particles_at = duration - 1.0
		"wall_ice":
			_build_ice_wall(n, size)
		"wall_fire":
			var half := size * 0.5
			var strip := MeshInstance3D.new()
			var pm := PlaneMesh.new()
			pm.size = Vector2(size, 2.2)
			strip.mesh = pm
			strip.position.y = 0.06
			var smat := StandardMaterial3D.new()
			smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			smat.albedo_color = Color(1.0, 0.35, 0.05, 0.5)
			strip.material_override = smat
			strip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			n.add_child(strip)
			particles(n, Color(1.0, 0.4, 0.08), int(size * 20), 0.6, {"shape": "box", "extents": Vector3(half, 0.1, 0.45), "vmin": 3.0, "vmax": 6.0,
				"spread": 6.0, "smin": 1.4, "smax": 2.4, "size": 0.9, "aabb": half + 2.0})
			particles(n, Color(1.0, 0.85, 0.3), int(size * 6), 0.5, {"shape": "box", "extents": Vector3(half, 0.1, 0.3), "vmin": 1.5, "vmax": 3.0,
				"spread": 10.0, "smin": 0.6, "smax": 1.0, "size": 0.5, "aabb": half + 2.0})
			n.stop_particles_at = duration - 0.7

static func _build_ice_wall(n: TimedFx, length: float) -> void:
	n.fade_out = 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = int(n.global_position.x * 13.0 + n.global_position.z * 7.0)
	var count := int(length / 0.9)
	for i in count:
		var shard := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = rng.randf_range(0.05, 0.25)
		cm.bottom_radius = rng.randf_range(0.55, 0.85)
		var h := rng.randf_range(2.2, 3.6)
		cm.height = h
		cm.radial_segments = 5
		cm.rings = 1
		shard.mesh = cm
		shard.material_override = ice_material()
		var x := -length * 0.5 + (i + 0.5) * length / count
		shard.position = Vector3(x, h * 0.5 - 0.2, rng.randf_range(-0.35, 0.35))
		shard.rotation = Vector3(rng.randf_range(-0.2, 0.2), rng.randf_range(0, TAU), rng.randf_range(-0.2, 0.2))
		n.add_child(shard)
		shard.scale = Vector3(1, 0.05, 1)
		shard.create_tween().tween_property(shard, "scale", Vector3.ONE, 0.25 + rng.randf() * 0.15).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	particles(n, COL_FROST, 50, 0.8, {"shape": "box", "extents": Vector3(length * 0.5, 0.2, 0.6), "vmin": 2.0, "vmax": 4.0,
		"spread": 40.0, "one_shot": true, "explosive": 0.8, "gravity": Vector3(0, -6, 0), "aabb": length})

static func end_zone(world: Node3D, id: int) -> void:
	var n: TimedFx = zones.get(id, null)
	if n == null or not is_instance_valid(n):
		return
	zones.erase(id)
	Sfx.play_at("ice_shatter", n.global_position + Vector3(0, 1, 0), 4.0)
	# стена разрушена — разлёт осколков
	var shatter := _timed(world, n.global_position, 1.2)
	shatter.rotation = n.rotation
	particles(shatter, COL_FROST, 60, 0.9, {"shape": "box", "extents": Vector3(4, 1, 0.6), "pos": Vector3(0, 1.2, 0),
		"vmin": 3.0, "vmax": 6.0, "spread": 180.0, "one_shot": true, "explosive": 1.0, "gravity": Vector3(0, -12, 0), "aabb": 10.0})
	n.queue_free()
