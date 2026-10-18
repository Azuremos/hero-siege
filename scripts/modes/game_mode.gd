class_name GameMode
extends Node
## Режим игры — правила партии поверх общего мира (герои, мобы, бой, добыча).
## Мир знает только об активном режиме: где появляются герои, куда идут враги, когда победа
## и поражение, что показывает панель режима. Осада — первый режим (SiegeMode);
## подземелья и открытый мир будут новыми наследниками, без правок world.gd.
##
## Жизненный цикл: setup() → read_map() → begin() (только сервер) → server_tick() каждый кадр.
## Состояние для клиентов: state_snapshot() на сервере → apply_snapshot() у клиентов (2 раза в секунду).

var world: Node3D
## Общая стадия партии. Режим может добавлять свои (у осады есть break и clearing).
var state := "prep"          # prep | running | victory | defeat

func setup(w: Node3D) -> void:
	world = w
	Unit.pvp = hero_pvp()

# ---------------------------------------------------------------- стороны и PvP (сессия 13)
## Сторона юнита — Unit.side: герои — номер команды, мобы — Unit.SIDE_MOBS. Враждебность — одна функция
## Unit.is_enemy_of; режим настраивает её здесь: бьют ли друг друга герои разных сторон.

func hero_pvp() -> bool:
	return false

## Числа боя героев (устойчивость, убывание контроля, утомление, коэффициенты) — pvp_data.gd; режим может поменять поля.
func pvp_config() -> Dictionary:
	return GameData.PvpData.DEFAULT

## Утомление боем: с какого момента у героя идёт дуэль (тогда утомление растёт с её начала). -1 — дуэли нет.
func dampen_since(_hero) -> float:
	return -1.0

## Сервер: героя убил вражеский герой killer (для счёта, объявлений и наград режима).
func on_hero_killed(_victim, _killer) -> void:
	pass

## Враги ли a и b (для кода режима и интерфейса; бой зовёт Unit.is_enemy_of напрямую — то же правило).
func are_enemies(a: Unit, b: Unit) -> bool:
	return a != null and a.is_enemy_of(b)

## Прочитать из карты то, что нужно режиму (маршруты, точки, цели).
func read_map(_map: Node3D) -> void:
	pass

## Сервер: партия началась (все загрузились).
func begin() -> void:
	pass

func server_tick(_delta: float, _t: float) -> void:
	pass

func is_over() -> bool:
	return state == "victory" or state == "defeat"

## Отдых: здоровье и мана восполняются быстрее.
func is_resting() -> bool:
	return false

## Предпросмотр интерфейса из главного меню (PreviewMode).
func is_preview() -> bool:
	return false

## Идёт бой — играет боевая музыка.
func is_combat() -> bool:
	return state == "running"

## Сервер: закончить партию.
func finish(victory: bool) -> void:
	if is_over():
		return
	state = "victory" if victory else "defeat"
	world.announce_all(game_over_text(victory), Color(1, 0.85, 0.3) if victory else Color(1, 0.3, 0.3))

# ---------------------------------------------------------------- герои

## Где появляется герой номер index из count.
func hero_spawn_point(index: int, count: int) -> Vector3:
	return Vector3((index - (count - 1) * 0.5) * 2.5, 0, 0)

func hero_spawn_yaw() -> float:
	return 0.0

func respawn_point(_hero) -> Vector3:
	return hero_spawn_point(0, 1)

## Где держится бот автотестов (--bot), если не задан --post.
func bot_post() -> Vector3:
	return Vector3(0, 0, 26)

# ---------------------------------------------------------------- события (сервер)

func on_mob_killed(_u: Unit, _killer: Unit, _boss: bool) -> void:
	pass

func on_hero_died(_hero) -> void:
	pass

## Погиб юнит, который не моб и не герой (у осады — замок).
func on_unit_destroyed(_u: Unit) -> void:
	pass

# ---------------------------------------------------------------- цель движения мобов
## Моб не знает о полосах: режим говорит, откуда он выходит, куда идёт и что атакует в конце пути.
## Поля m.route и m.wp — данные режима (у осады это полоса и точка маршрута).

## Начальная точка и следующая за ней (для разворота) для источника source.
func mob_start(_source: int) -> Array:
	return [Vector2.ZERO, Vector2(0, -1)]

func mob_spawned(m) -> void:
	m.route = 0
	m.wp = 0

## Куда моб идёт сейчас, когда ни с кем не дерётся.
func mob_goal(m) -> Vector2:
	return m.pos2

## Что моб атакует, дойдя до конца пути (или null).
func mob_objective(_m) -> Unit:
	return null

## Моб бросил погоню — продолжить путь с ближайшего места впереди.
func mob_resume(_m) -> void:
	pass

## Насколько моб отошёл от своего пути (для поводка). INF — поводка нет.
func mob_leash_dist(_m) -> float:
	return 0.0

# ---------------------------------------------------------------- сеть

func state_snapshot() -> Array:
	return [state]

func apply_snapshot(s: Array) -> void:
	state = s[0]

# ---------------------------------------------------------------- интерфейс

## Что показать в панели режима:
## {title, bar_visible, bar, bar_max, bar_text, can_skip, skip_text}
func hud_panel(_alive_mobs: int) -> Dictionary:
	return {"title": "", "bar_visible": false, "bar": 0.0, "bar_max": 1.0, "bar_text": "", "can_skip": false, "skip_text": ""}

## Хост нажал кнопку панели режима («Начать волну сейчас» у осады).
func skip() -> void:
	pass

func game_over_text(victory: bool) -> String:
	return "ПОБЕДА!" if victory else "Поражение..."

## Строка под заголовком в окне итогов партии.
func game_over_details(_victory: bool) -> String:
	return ""

## Окно итогов у этого игрока — победа? (в режиме «команда на команду» — своя команда победила)
func local_victory() -> bool:
	return state == "victory"

# ---------------------------------------------------------------- хуки режима (значения по умолчанию — как в осаде)
## Режимы с другими правилами («Война линий») переопределяют их; осада пользуется значениями отсюда,
## поэтому баланс осады от новых режимов не меняется.

func map_path() -> String:
	return "res://scenes/map.tscn"

## Где появляется герой игрока info (у режимов с командами — у своей базы).
func hero_spawn_for(_info: Dictionary, index: int, count: int) -> Vector3:
	return hero_spawn_point(index, count)

func hero_spawn_yaw_for(_info: Dictionary) -> float:
	return hero_spawn_yaw()

## Сколько героев считать для силы врагов и механик «на группу».
func mob_players() -> int:
	return world.online_hero_count()

## Получает ли герой h опыт и золото за врага u (у «Линий» — только своя команда).
func can_share(_h, _u: Unit) -> bool:
	return true

## Опыт и золото за убийство врага u: [xp, gold].
func kill_reward(_u: Unit, xp: int, gold: int) -> Array:
	return [xp, gold]

## Множитель доли вещей в добыче врага u (0 — только зелья).
func loot_gear_k(_u: Unit) -> float:
	return 1.0

## Синие вещи в лавке кузнеца: {} — как в осаде (60% ротаций, 1–2 штуки).
func shop_blue() -> Dictionary:
	return {}

## Можно ли герою торговать у этого торговца (у «Линий» — только у своей базы).
func vendor_allowed(_hero, _vid: String) -> bool:
	return true

## Показывать ли героя other в рамках группы игрока me.
func party_visible(_me, _other) -> bool:
	return true

## Команда для игрока, вошедшего посреди партии.
func team_for_new() -> int:
	return 0

## Сервер: герой вошёл посреди партии.
func on_hero_joined(_h) -> void:
	pass

## Дополнительные поля итогов героя (у «Линий» — золото, отправки, прорывы).
func summary_extra(_h) -> Dictionary:
	return {}
