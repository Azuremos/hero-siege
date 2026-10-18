class_name Unit
extends RefCounted
## Боевые данные любого существа (герой, моб, замок).
## На сервере это «истина», на клиентах — копия из снимков сервера.

## Сторона (сессия 13): герои — номер своей команды (в осаде все 0), их питомцы и база — та же сторона,
## мобы — SIDE_MOBS (враждебны всем). Кто кому враг — is_enemy_of: одна проверка на весь бой, ИИ, цели и подсказки.
const SIDE_MOBS := 100

var id: int = 0
var side: int = 0
## Дуэль (Арена): участники дуэли (и их питомцы) — в своём «круге» (duel != 0): с остальными не взаимодействуют
## ни как враги, ни как союзники — зрители не помогают и не мешают.
var duel: int = 0
var kind: String = "mob"        # hero | mob | pet | castle
var owner_id: int = 0           # питомец: id героя-хозяина (урон в счётчик, лечение, рамки)
var type_id: String = ""        # класс героя или тип моба
var display_name: String = ""
var pos: Vector3 = Vector3.ZERO
var radius: float = 0.6
var alive: bool = true

var hp: float = 100.0
var max_hp: float = 100.0
var mana: float = 0.0
var max_mana: float = 0.0
var level: int = 1
var armor: float = 0.0          # доля снижения физического урона
var power: float = 1.0          # множитель заклинаний (уровень × сила заклинаний)
var phys_power: float = 1.0     # множитель физического урона (уровень × сила атаки)
var crit_base: float = 0.05     # базовый шанс крита (ловкость, интеллект)
var spirit: float = 0.0         # дух — восполнение маны и здоровья
var resource: String = "mana"  # mana | rage | focus (концентрация охотника) | energy (энергия разбойника)
var combat_until: float = 0.0   # в бою до этого момента (ярость не угасает)
var unseen_until: float = 0.0   # враги не выбирают целью и не реагируют на удары (Зеркальные копии, Притворство мёртвым)
var mana_spent_at := -100.0      # правило 5 секунд: когда последний раз тратил ману
## Счётчики для --manalog и баланса (урон, лечение, потраченная мана)
var stat_dmg := 0.0
var stat_heal := 0.0
var stat_spent := 0.0
var heal_mult: float = 1.0

# Состояния (время — серверное, сек)
var absorb: float = 0.0
var absorb_until: float = 0.0
var immune_until: float = 0.0
var stun_until: float = 0.0
var root_until: float = 0.0
var freeze_until: float = 0.0       # заморожен: не двигается и не атакует
var chill: int = 0                  # накопленный холод (на N-м попадании — заморозка)
var chill_until: float = 0.0
var slow_pct: float = 0.0
var slow_until: float = 0.0
## Кто наложил контроль и ослабления (ключ эффекта -> id) — свои эффекты в рамке цели крупнее
var fx_src: Dictionary = {}
## Контроль от врагов: страх (герой бежит прочь), немота (нельзя колдовать), отбрасывание (полёт)
var fear_until: float = 0.0
var fear_from := Vector3.ZERO
var silence_until: float = 0.0
var knock_until: float = 0.0
var incap := false              # «превращён»: урон снимает оглушение
var def_ranged := false         # моб дальнего боя (для отражения в ближнем бою)
## Элитные мобы: 0 — обычный, 1 — элитный, 2 — чемпион фракции; аффиксы — id из affixes.gd
var elite := 0
var affixes: Array = []
## «Война линий»: враг, которого отправил игрок (id героя), и золото за его убийство (доля цены отправки)
var sent_by := 0
var bounty := 0
var route := 0                  # откуда вышел (данные режима: у «Линий» — команда × 3 + линия)
var damage_taken_mult: float = 1.0   # пересчитывается каждый тик (барьеры)

## Периодические эффекты: {key, kind: "dot"/"hot", per_tick, tick, next, until, school, source}
var auras: Array = []

## Временные усиления: {key, until, mods: {ключ: значение}}
var buffs: Array = []
## Модификаторы из талантов: {global, school, spell, flags} (см. GameData.compute_mods)
var mods: Dictionary = {}

var last_attacker: int = 0
## Смерть: кто убил (id героя; питомец — его хозяин). 0 — не герой.
var killer_id: int = 0
## Охотник: питомец призван (сервер и клиенты — по появлению и гибели питомца). «Одинокий волк» — без питомца.
var has_pet := false
## Разбойник: приёмы серии (0–5, тратят завершающие приёмы) и незаметность (враги не видят и не выбирают целью).
var combo: int = 0
var stealthed := false
## PvP (сессия 13): схватка героев — с какого момента и когда последний раз был урон между героями;
## убывание контроля: категория -> [сколько раз подряд, до какого времени считается].
var pvp_since := -100.0
var pvp_last := -100.0
var dr: Dictionary = {}
var node: Node3D = null              # визуальный узел (если есть)

## Модификаторы от характеристик снаряжения (сопротивление магии, восполнение маны, скорость) — hero.apply_level_stats.
var gear_mods: Dictionary = {}

## Сумма модификатора по всем источникам: таланты (общие, школа, заклинание) + снаряжение + баффы.
## Бафф может усиливать одну школу: ключ «amount@fire».
func mod(key: String, sid: String = "", school: String = "") -> float:
	var v := float(gear_mods.get(key, 0.0))
	if not mods.is_empty():
		v += float(mods["global"].get(key, 0.0))
		if school != "":
			v += float(mods["school"].get(school, {}).get(key, 0.0))
		if sid != "":
			v += float(mods["spell"].get(sid, {}).get(key, 0.0))
	var sk := key + "@" + school if school != "" else ""
	for b in buffs:
		v += float(b["mods"].get(key, 0.0))
		if sk != "":
			v += float(b["mods"].get(sk, 0.0))
	return v

func flag(name: String) -> float:
	if mods.is_empty():
		return 0.0
	return float(mods["flags"].get(name, 0.0))

func has_buff(key: String) -> bool:
	for b in buffs:
		if b["key"] == key:
			return true
	return false

func add_buff(key: String, until: float, buff_mods: Dictionary) -> void:
	remove_buff(key)
	buffs.append({"key": key, "until": until, "mods": buff_mods})

func remove_buff(key: String) -> void:
	for i in buffs.size():
		if buffs[i]["key"] == key:
			buffs.remove_at(i)
			return

## Правила враждебности задаёт режим (GameMode.setup → Unit.pvp): разные стороны героев враждуют, только если
## режим разрешил бой героев (Арена, --pvptest); мобы враждебны всем; своя сторона — всегда союзники.
static var pvp := false

func is_enemy_of(other: Unit) -> bool:
	if other == null or side == other.side or duel != other.duel:
		return false
	return pvp or side == SIDE_MOBS or other.side == SIDE_MOBS

## Союзник — та же сторона (лечение, баффы, ауры). В «Линиях» герои другой команды — не враги и не союзники.
func is_ally_of(other: Unit) -> bool:
	return other != null and side == other.side and duel == other.duel

func is_stunned(now: float) -> bool:
	return now < stun_until or now < freeze_until

func is_frozen(now: float) -> bool:
	return now < freeze_until

func is_rooted(now: float) -> bool:
	return now < root_until or now < stun_until or now < freeze_until

func speed_mult(now: float) -> float:
	var k := maxf(0.2, 1.0 + mod("speed"))     # баффы скорости (Боевые барабаны, Ускорение)
	if now < slow_until:
		return (1.0 - slow_pct) * k
	return k

func hp_frac() -> float:
	return clampf(hp / max_hp, 0.0, 1.0) if max_hp > 0.0 else 0.0
