class_name PreviewMode
extends GameMode
## Предпросмотр интерфейса из главного меню: тот же HUD, что в игре, но без волн и боя.
## Группа из 6 героев, враг в цели с эффектами и меткой, баффы, сигнал прока, счётчик с примером —
## чтобы расставить все рамки. Расположение сохраняется в user://ui_layout.cfg, как в игре.
## «Готово» или Esc — обратно в главное меню.

var hero_spawn := Vector3(0, 0, 14)
var _setup_at := 0.0
var _done := false
var _dummy := 0

func read_map(map: Node3D) -> void:
	hero_spawn = (map.get_node("HeroSpawn") as Node3D).position

func begin() -> void:
	_setup_at = world.now() + 0.4

func is_preview() -> bool:
	return true

func is_combat() -> bool:
	return false

func hero_spawn_point(index: int, count: int) -> Vector3:
	return hero_spawn + Vector3((index - (count - 1) * 0.5) * 2.2, 0, -absf(index - (count - 1) * 0.5) * 0.6)

func hero_spawn_yaw() -> float:
	return PI

func respawn_point(_hero) -> Vector3:
	return hero_spawn

# враг стоит на месте перед героями
func mob_start(_source: int) -> Array:
	var p := Vector2(hero_spawn.x, hero_spawn.z + 9.0)
	return [p, p + Vector2(0, -1)]

func mob_goal(m) -> Vector2:
	return m.pos2

func server_tick(_delta: float, t: float) -> void:
	if _done or t < _setup_at:
		return
	_done = true
	_fill_fake_data(t)

## Фальшивые данные для всех рамок.
func _fill_fake_data(t: float) -> void:
	var lh = world.local_hero
	if lh == null:
		return
	world.mobs.spawn("warrior", 0, 7, 1)
	var dummy: Unit = null
	for u in world.mobs.alive_units():
		dummy = u
	if dummy:
		_dummy = dummy.id
		dummy.stun_until = t + 1e6           # стоит и не нападает
		world.spells.apply_effects(lh.unit, dummy, [{"type": "slow", "pct": 0.4, "dur": 1e6}, {"type": "chill", "stacks": 3, "dur": 3.0},
			{"type": "chill", "stacks": 3, "dur": 3.0}, {"type": "dot", "total": 1.0, "dur": 1e6, "tick": 1e5, "key": "ignite"}], "frostbolt", "frost")
		world.marks.request_mark(dummy.id, 8)
		lh.controller.target_id = dummy.id
	# свои баффы и прок
	for key in ["kings", "fortitude", "battle_shout"]:
		lh.unit.add_buff(key, t + 1e6, {})
	var known: Array = lh.spell_list()
	for pk in GameData.PROC_BUFFS:
		for s in GameData.PROC_BUFFS[pk]["spells"]:
			if known.has(s):
				lh.unit.add_buff(pk, t + 1e6, {})
				break
		if lh.unit.buffs.any(func(b): return GameData.PROC_BUFFS.has(b["key"])):
			break
	# группа: кто-то ранен, на ком-то «Ослабленная душа»
	var i := 0
	for h in world.heroes.values():
		if h != lh:
			h.unit.hp = h.unit.max_hp * [0.92, 0.55, 0.78, 0.35, 0.66][i % 5]
			if i == 1:
				h.unit.add_buff("weakened_soul", t + 1e6, {})
			i += 1
	world.hud.set_meter_preview(true)
	world.hud.set_edit_mode(true)

# ---------------------------------------------------------------- интерфейс

func hud_panel(_alive_mobs: int) -> Dictionary:
	return {"title": "Волна 7 / 20\nследующая через 25 сек.", "bar_visible": true, "bar": 4200.0, "bar_max": 6000.0,
		"bar_text": "Замок: 4200 / 6000      Врагов: 23", "can_skip": true, "skip_text": "Начать волну сейчас"}

func game_over_text(_victory: bool) -> String:
	return ""
