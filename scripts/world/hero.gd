extends CharacterBody3D
## Герой игрока. Своим героем управляет сам игрок (позиция отправляется остальным),
## бой и характеристики считает хост.

const PlayerControllerScript := preload("res://scripts/world/player_controller.gd")

const RUN_SPEED := 7.5
const BACK_SPEED := 4.5
const TURN_SPEED := 3.2
const GRAVITY := 24.0
const JUMP_VELOCITY := 8.5

enum A { IDLE, RUN, BACK, STRAFE_L, STRAFE_R, JUMP }

const ACTION_ANIMS := {
	"cast": "Spellcast_Shoot", "shoot": "Spellcast_Shoot", "raise": "Spellcast_Raise",
	"melee": "1H_Melee_Attack_Slice_Diagonal", "melee2": "1H_Melee_Attack_Chop",
	"wand": "Spellcast_Shoot", "hit": "Hit_A", "spin": "2H_Melee_Attack_Spinning",
}

var world: Node3D
var hero_id := 0
var peer_id := 0
var class_id := "mage"
var race_id := "human"
var player_name := "Герой"
var unit: Unit
var is_local := false

# прогресс (сервер — истина, клиенты — из снимков)
var xp := 0
var xp_next := 60
var gold := 0
var respawn_at := 0.0

# данные из снимков для интерфейса и визуала
var net_absorb := 0.0
var net_stun_left := 0.0
var net_speed := 1.0               # множитель скорости бега (замедления, баффы скорости)
var net_buffs: Array = []
var net_respawn_left := 0.0

var model: Node3D
var anim: AnimationPlayer
var controller: Node = null
var anim_state: int = A.IDLE
var casting := false
var alive_visual := true
var _action_left := 0.0
var _cur_anim := ""
var _net_pos := Vector3.ZERO
var _net_yaw := 0.0
var _net_initialized := false
var _send_accum := 0.0
var _shield: MeshInstance3D
var _nameplate: Label3D

func setup(w: Node3D, hid: int, pid: int, info: Dictionary) -> void:
	world = w
	hero_id = hid
	peer_id = pid
	class_id = info.get("class", "mage")
	race_id = info.get("race", "human")
	player_name = info.get("name", "Герой")
	is_local = pid == Net.my_id()
	unit = Unit.new()
	unit.id = hid
	unit.kind = "hero"
	unit.team = Unit.Team.PLAYERS
	unit.type_id = class_id
	unit.display_name = player_name
	unit.radius = 0.7
	unit.node = self
	bag.resize(BAG_SIZE)
	bag.fill(null)
	apply_level_stats(true)
	xp_next = GameData.xp_to_next(1)

## Атрибуты (итог: класс + рост за уровни + снаряжение) и производные характеристики.
var attrs: Dictionary = {}
var spell_power := 0.0
var attack_power := 0.0

## Снаряжение: ячейка -> id предмета. Сумка: 20 ячеек {id, n} или null.
var equip: Dictionary = {}
var bag: Array = []
const BAG_SIZE := 20
var potion_ready_at := 0.0        # сервер: общее восстановление зелий

func gear_stats() -> Dictionary:
	var s := {}
	for slot in equip:
		var it := GameData.item(equip[slot])
		var w: float = GameData.ItemData.OFFHAND_RATIO if slot == "offhand" else 1.0
		for k in it.get("stats", {}):
			s[k] = float(s.get(k, 0.0)) + float(it["stats"][k]) * w
	return s

## Внешний вид: воин с оружием в левой руке держит второй топор вместо щита.
func update_weapon_visual(dual: bool) -> void:
	if class_id != "warrior" or model == null:
		return
	var skel := model.find_child("Skeleton3D", true, false)
	if skel == null:
		return
	for att in skel.get_children():
		if att is BoneAttachment3D and att.bone_name == "handslot.l":
			for m in att.get_children():
				if m.name == "1H_Axe_Offhand":
					(m as Node3D).visible = dual
				elif m.name == "Barbarian_Round_Shield":
					(m as Node3D).visible = not dual

func apply_level_stats(full_restore: bool) -> void:
	var cls: Dictionary = GameData.CLASSES[class_id]
	var race: Dictionary = GameData.RACES[race_id]
	var l := float(unit.level - 1)
	var hp_frac := unit.hp / unit.max_hp if unit.max_hp > 0.0 else 1.0
	var mana_frac := unit.mana / unit.max_mana if unit.max_mana > 0.0 else 1.0
	var gear := gear_stats()
	attrs = {}
	for k in cls["attrs"]:
		attrs[k] = float(cls["attrs"][k]) + float(cls["grow"][k]) * l + float(gear.get(k, 0.0))
	spell_power = attrs["int"] + float(gear.get("sp", 0.0))
	attack_power = attrs["str"] + float(gear.get("ap", 0.0))
	unit.resource = cls.get("resource", "mana")
	unit.max_hp = (float(cls["base_hp"]) + attrs["sta"] * 10.0) * float(race.get("hp_mult", 1.0)) * (1.0 + unit.mod("hp_pct"))
	if unit.resource == "rage":
		unit.max_mana = 100.0
	else:
		unit.max_mana = (float(cls["base_mana"]) + attrs["int"] * 15.0) * float(race.get("mana_mult", 1.0)) * (1.0 + unit.mod("mana_pct"))
	unit.armor = minf(0.75, float(cls["armor"]) + attrs["agi"] * 0.0015 + float(gear.get("armor", 0.0)) + unit.mod("armor"))
	var lvl: float = GameData.level_power(unit.level)
	var dm := float(cls.get("dmg_mult", 1.0))
	unit.power = lvl * (1.0 + spell_power / 100.0) * float(race.get("power_mult", 1.0)) * dm
	unit.phys_power = lvl * (1.0 + attack_power / 100.0) * dm
	unit.crit_base = 0.05 + attrs["agi"] * 0.001 + attrs["int"] * 0.0005
	unit.spirit = attrs["spi"]
	unit.heal_mult = float(race.get("heal_mult", 1.0))
	if full_restore:
		unit.hp = unit.max_hp
		unit.mana = 0.0 if unit.resource == "rage" else unit.max_mana
	else:
		unit.hp = unit.max_hp * hp_frac
		unit.mana = unit.max_mana * mana_frac

## Сумка: первая ячейка с предметом id (или -1).
func bag_find(id: String) -> int:
	for i in bag.size():
		if bag[i] != null and bag[i]["id"] == id:
			return i
	return -1

func bag_count(id: String) -> int:
	var n := 0
	for s in bag:
		if s != null and s["id"] == id:
			n += int(s["n"])
	return n

## Сервер: положить предмет в сумку (расходники складываются в стопки). false — нет места.
func bag_add(id: String, n: int = 1) -> bool:
	var it := GameData.item(id)
	if it.is_empty():
		return false
	if it["kind"] == "consumable":
		for s in bag:
			if s != null and s["id"] == id and int(s["n"]) + n <= GameData.ItemData.STACK:
				s["n"] = int(s["n"]) + n
				return true
	var free := bag.find(null)
	if free < 0:
		return false
	bag[free] = {"id": id, "n": n}
	return true
# ---------------------------------------------------------------- таланты

## Изученные таланты: id -> ранг. Сервер — истина, клиенты получают копию.
var talents: Dictionary = {}

func set_talents(ranks: Dictionary) -> void:
	talents = ranks.duplicate()
	unit.mods = GameData.compute_mods(class_id, talents, choices)
	apply_level_stats(false)

## Выбор в книге заклинаний {ряд: id}. Новое заклинание встаёт на панель в ячейку прежнего.
var choices: Dictionary = {}

func set_choices(c: Dictionary) -> void:
	var before: Array = spell_list()
	choices = c.duplicate()
	unit.mods = GameData.compute_mods(class_id, talents, choices)
	apply_level_stats(false)
	if is_local and controller:
		var after: Array = spell_list()
		var gone: Array = before.filter(func(s): return not after.has(s))
		var fresh: Array = after.filter(func(s): return not before.has(s))
		for k in mini(gone.size(), fresh.size()):
			controller.replace_spell(gone[k], fresh[k])
		controller.sync_bar()

func spell_list() -> Array:
	return GameData.hero_spells(class_id, talents, choices)

func talent_points_free() -> int:
	return GameData.talent_points_total(unit.level) - GameData.talent_points_spent(talents)

func _ready() -> void:
	collision_layer = 2
	collision_mask = 1
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.5
	cap.height = 2.2
	cs.shape = cap
	cs.position.y = 1.1
	add_child(cs)

	model = ModelFactory.build_hero(class_id, race_id)
	add_child(model)
	anim = ModelFactory.find_anim(model)
	_play("Idle")

	_shield = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.6
	sm.height = 3.2
	_shield.mesh = sm
	_shield.position.y = 1.2
	_shield.material_override = Vfx.dome_material(Color(1.0, 0.92, 0.55), 1.2)
	_shield.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shield.visible = false
	add_child(_shield)

	if is_local:
		controller = PlayerControllerScript.new()
		controller.name = "Controller"
		add_child(controller)
	else:
		_nameplate = Label3D.new()
		_nameplate.text = "%s" % player_name
		_nameplate.modulate = GameData.CLASSES[class_id]["color"]
		_nameplate.outline_modulate = Color(0, 0, 0, 0.85)
		_nameplate.outline_size = 10
		_nameplate.font_size = 42
		_nameplate.pixel_size = 0.006
		_nameplate.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_nameplate.position.y = 3.1
		add_child(_nameplate)

## Позиция для серверной логики: для чужих героев — последняя присланная.
func server_position() -> Vector3:
	if is_local or not _net_initialized:
		return global_position
	return _net_pos

func _physics_process(delta: float) -> void:
	if is_local:
		_local_move(delta)
		_send_accum += delta
		if _send_accum >= 0.05:
			_send_accum = 0.0
			net_move.rpc(global_position, rotation.y, anim_state)
	else:
		if _net_initialized:
			var k := 1.0 - exp(-14.0 * delta)
			global_position = global_position.lerp(_net_pos, k)
			rotation.y = lerp_angle(rotation.y, _net_yaw, k)
	if not world.is_server():
		unit.pos = global_position
	_update_anim(delta)
	_shield.visible = alive_visual and (net_absorb > 0.0 or _has_buff("immune"))
	_update_wings(delta)
	if Net.is_server():
		_server_tick()

func _local_move(delta: float) -> void:
	var c = controller
	var fwd := 0.0
	var strafe := 0.0
	var can_move: bool = unit.alive and net_stun_left <= 0.0 and alive_visual
	if can_move:
		rotation.y += c.turn_input * TURN_SPEED * delta
		if c.steering:
			rotation.y = c.cam_yaw
		fwd = c.move_forward
		strafe = c.move_strafe
	if can_move and world.now() < _fear_until:
		# страх: бежит прочь, управление не слушается
		var away := global_position - _fear_from
		away.y = 0.0
		if away.length() > 0.1:
			rotation.y = atan2(-away.x, -away.z)
		fwd = 1.0
		strafe = 0.0
	var dir := (-transform.basis.z * fwd + transform.basis.x * strafe)
	if dir.length() > 1.0:
		dir = dir.normalized()
	var spd := (RUN_SPEED if fwd >= 0.0 else BACK_SPEED) * net_speed
	velocity.x = dir.x * spd
	velocity.z = dir.z * spd
	if is_on_floor():
		if can_move and c.consume_jump():
			velocity.y = JUMP_VELOCITY
	else:
		velocity.y -= GRAVITY * delta
	move_and_slide()

	if not is_on_floor():
		anim_state = A.JUMP
	elif fwd > 0.1:
		anim_state = A.RUN
	elif fwd < -0.1:
		anim_state = A.BACK
	elif strafe > 0.1:
		anim_state = A.STRAFE_R
	elif strafe < -0.1:
		anim_state = A.STRAFE_L
	else:
		anim_state = A.IDLE

func is_moving() -> bool:
	return Vector2(velocity.x, velocity.z).length() > 0.3 or not is_on_floor()

@rpc("any_peer", "unreliable_ordered")
func net_move(p: Vector3, yaw: float, st: int) -> void:
	if multiplayer.get_remote_sender_id() != peer_id:
		return
	# под оглушением и в полёте после отбрасывания сервер не принимает движение героя
	if Net.is_server() and (unit.is_stunned(world.now()) or world.now() < unit.knock_until) and _net_initialized and p.distance_to(_net_pos) > 0.3:
		return
	_net_pos = p
	_net_yaw = yaw
	anim_state = st
	if not _net_initialized or global_position.distance_to(p) > 8.0:
		_net_initialized = true
		global_position = p

## Контроль от врагов (сервер решил — клиент героя выполняет). fear: герой бежит прочь от источника.
var _fear_until := 0.0
var _fear_from := Vector3.ZERO

@rpc("authority", "call_local", "reliable")
func ev_control(kind: String, dur: float, from: Vector3) -> void:
	if kind == "fear":
		_fear_until = world.now() + dur
		_fear_from = from
		Vfx.spawn(world, "taunt", global_position, from, 0.0, hero_id)

## Отбрасывание: своего героя относит в точку, которую посчитал сервер.
@rpc("authority", "call_local", "reliable")
func ev_knock(dest: Vector3) -> void:
	if not is_local:
		return
	velocity = Vector3.ZERO
	var tw := create_tween()
	tw.tween_property(self, "global_position", Vector3(dest.x, global_position.y, dest.z), 0.35).set_ease(Tween.EASE_OUT)

## Рывок воина: свой герой стремительно переносится к цели.
@rpc("authority", "reliable")
func ev_dash(dest: Vector3) -> void:
	if not is_local:
		return
	var to := dest - global_position
	to.y = 0.0
	if to.length() > 0.1:
		rotation.y = atan2(-to.x, -to.z)
	velocity = Vector3.ZERO
	var tw := create_tween()
	tw.tween_property(self, "global_position", Vector3(dest.x, global_position.y, dest.z), 0.22)
	Vfx.spawn(world, "charge_trail", global_position, dest, 0.0, hero_id)

## Скачок: сервер разрешил — свой герой переносится вперёд (стены и здания останавливают).
@rpc("authority", "reliable")
func ev_blink(dist: float) -> void:
	if not is_local:
		return
	var dir := -global_transform.basis.z
	if dist < 0.0:
		dir = -dir          # Смещение: прыжок назад
		dist = -dist
	dir.y = 0.0
	dir = dir.normalized()
	var from := global_position
	var space := get_world_3d().direct_space_state
	for h in [0.4, 1.4]:
		var q := PhysicsRayQueryParameters3D.create(from + Vector3(0, h, 0), from + Vector3(0, h, 0) + dir * dist, 1)
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			dist = minf(dist, maxf(0.0, (hit["position"] as Vector3 - (from + Vector3(0, h, 0))).length() - 0.8))
	global_position = from + dir * dist
	velocity = Vector3.ZERO
	_net_pos = global_position
	net_move.rpc(global_position, rotation.y, anim_state)
	Vfx.spawn(world, "blink", global_position, from, 0.0, hero_id)

## Сервер: телепорт при воскрешении.
@rpc("authority", "call_local", "reliable")
func ev_respawn(p: Vector3) -> void:
	_net_pos = p
	global_position = p
	velocity = Vector3.ZERO
	set_alive_visual(true)

func _server_tick() -> void:
	if not unit.alive and world.now() >= respawn_at and respawn_at > 0.0:
		unit.alive = true
		unit.hp = unit.max_hp
		unit.mana = 0.0 if unit.resource == "rage" else unit.max_mana
		respawn_at = 0.0
		ev_respawn.rpc(world.mode.respawn_point(self))

# ---------------------------------------------------------------- анимация

func set_alive_visual(alive: bool) -> void:
	if alive == alive_visual:
		return
	alive_visual = alive
	unit.alive = alive if not Net.is_server() else unit.alive
	if not alive:
		casting = false
		_play("Death_A", 0.1, true)
	else:
		_action_left = 0.0
		_play("Idle", 0.1, true)

func play_action(key: String) -> void:
	if not alive_visual:
		return
	var n: String = ACTION_ANIMS.get(key, "Spellcast_Shoot")
	if class_id == "paladin" and (key == "shoot" or key == "cast"):
		n = "Spellcast_Shoot"
	if anim and anim.has_animation(n):
		_play(n, 0.08, true)
		_action_left = minf(anim.get_animation(n).length, 1.0) * 0.85
	if key == "melee" or key == "melee2":
		# свист клинка, а в момент удара — металл
		var at := global_position + Vector3(0, 1.2, 0)
		Sfx.play_at("sword", at)
		if key == "melee2":
			get_tree().create_timer(0.16).timeout.connect(func(): Sfx.play_at("blade_hit", at))

func _update_anim(delta: float) -> void:
	if not alive_visual or anim == null:
		return
	if _action_left > 0.0:
		_action_left -= delta
		if anim_state == A.IDLE or anim_state == A.JUMP:
			return
	var want := "Idle"
	match anim_state:
		A.RUN: want = "Running_A"
		A.BACK: want = "Walking_Backwards"
		A.STRAFE_L: want = "Running_Strafe_Left"
		A.STRAFE_R: want = "Running_Strafe_Right"
		A.JUMP: want = "Jump_Idle"
		_: want = "Spellcasting" if casting else "Idle"
	_play(want)

func _play(n: String, blend: float = 0.15, force: bool = false) -> void:
	if anim == null or (n == _cur_anim and not force):
		return
	if anim.has_animation(n):
		_cur_anim = n
		anim.play(n, blend)
		if force:
			anim.seek(0.0, true)

# ---------------------------------------------------------------- крылья (Гнев карателя)

var _wings: MeshInstance3D
var _wings_t := 0.0

func _update_wings(delta: float) -> void:
	var on := alive_visual and _has_buff("avenging_wrath")
	if not on:
		if _wings:
			_wings.visible = false
		return
	if _wings == null:
		_wings = MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(4.4, 3.2)
		_wings.mesh = q
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.albedo_texture = load("res://assets/icons/fx/wings.svg")
		mat.albedo_color = Color(1.0, 0.82, 0.35)
		_wings.material_override = mat
		_wings.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_wings.position = Vector3(0, 1.95, 0.5)
		model.add_child(_wings)
		Vfx.particles(_wings, Color(1.0, 0.85, 0.4), 16, 1.0, {"shape": "box", "extents": Vector3(1.6, 0.8, 0.1),
			"vmin": 0.2, "vmax": 0.6, "smin": 0.3, "smax": 0.6, "size": 0.3, "gravity": Vector3(0, -0.5, 0), "local": true})
	_wings.visible = true
	_wings_t += delta
	var flap := sin(_wings_t * 3.0)
	_wings.scale = Vector3(1.0 + flap * 0.06, 1.0 + flap * 0.03, 1.0)

func _has_buff(key: String) -> bool:
	for b in net_buffs:
		if b[0] == key:
			return true
	return false
