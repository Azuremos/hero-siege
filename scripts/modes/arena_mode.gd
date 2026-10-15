class_name ArenaMode
extends GameMode
## --bossarena=<id>: босс на пустой площадке перед героями, без волн и замка.
## Проверка боссов и заготовка под подземелья: босс не знает об осаде, режим только ставит его и судит бой.
## Сила босса — как на волне --arenawave=N (по умолчанию 1: базовые числа из mob_data). Герои воскресают.
## Победа — босс убит (и не превращается в следующего). Поражение — все герои мертвы одновременно.

var hero_spawn := Vector3(0, 0, 26)
var boss_id := ""
var _spawn_at := 0.0
var _spawned := false

func read_map(map: Node3D) -> void:
	hero_spawn = (map.get_node("HeroSpawn") as Node3D).position
	boss_id = str(Net.cli.get("bossarena", "boss_lich"))
	if not GameData.BOSSES.has(boss_id):
		push_warning("--bossarena: нет босса %s, беру boss_lich" % boss_id)
		boss_id = "boss_lich"

func begin() -> void:
	state = "running"
	_spawn_at = world.now() + 3.0

func hero_spawn_point(index: int, count: int) -> Vector3:
	return hero_spawn + Vector3((index - (count - 1) * 0.5) * 2.5, 0, 0)

func hero_spawn_yaw() -> float:
	return PI

func respawn_point(_hero) -> Vector3:
	return hero_spawn

## Бот держится центра площадки.
func bot_post() -> Vector3:
	return hero_spawn + Vector3(0, 0, 7)

func server_tick(_delta: float, t: float) -> void:
	if is_over():
		return
	if not _spawned:
		if t >= _spawn_at:
			_spawned = true
			var p := hero_spawn + Vector3(0, 0, 15)
			var wave := int(Net.cli.get("arenawave", 1))
			world.mobs.spawn(boss_id, 0, wave, world.online_hero_count(), 1.0, {"pos": Vector2(p.x, p.z)})
		return
	var boss_alive := false
	for u in world.mobs.alive_units():
		if GameData.MOBS[u.type_id].get("boss", false):
			boss_alive = true
			break
	if not boss_alive and not world.mobs.boss_pending():
		finish(true)

func mob_start(_source: int) -> Array:
	var p := Vector2(hero_spawn.x, hero_spawn.z + 15.0)
	return [p, p + Vector2(0, -1)]

## Враги на арене идут к ближайшему живому герою.
func mob_goal(m) -> Vector2:
	var best: Vector2 = m.pos2
	var bd := INF
	for h in world.heroes.values():
		if h.unit.alive:
			var hp := Vector2(h.unit.pos.x, h.unit.pos.z)
			if hp.distance_to(m.pos2) < bd:
				bd = hp.distance_to(m.pos2)
				best = hp
	return best

func mob_leash_dist(_m) -> float:
	return 0.0

func hud_panel(_alive_mobs: int) -> Dictionary:
	return {"title": "Арена: %s" % GameData.MOBS[boss_id]["name"], "bar_visible": false, "bar": 0.0, "bar_max": 1.0,
		"bar_text": "", "can_skip": false, "skip_text": ""}

func game_over_text(victory: bool) -> String:
	return "Босс повержен!" if victory else "Отряд погиб..."

func on_hero_died(hero) -> void:
	var boss_hp := -1.0
	for u in world.mobs.alive_units():
		if GameData.MOBS[u.type_id].get("boss", false):
			boss_hp = u.hp_frac()
	print("ARENA hero died: %s, boss hp=%.2f, t=%.0f" % [hero.player_name, boss_hp, world.now()])
