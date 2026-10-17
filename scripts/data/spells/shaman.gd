extends RefCounted
## Заклинания: Шаман. Формат полей — в начале scripts/data/game_data.gd (раздел «Заклинания»).
## Здесь же заклинания, которые класс получает из талантов. Новые поля (сессия 11):
##   delivery totem — тотем у ног шамана: зона, которая тикает, пока стоит тотем (spell_system, раздел «тотемы»).
##     totem: {element — огонь/земля/вода/воздух (у шамана одновременно по одному тотему каждой стихии,
##     новый заменяет старый), life — сколько стоит, shoot — сколько врагов бьёт за тик лучом (0 — всех в радиусе)};
##     radius и tick — как у зоны; enemy_fx / ally_fx — как у зоны.
##   from_totems — заклинание вокруг себя (self_aoe) срабатывает ещё и вокруг каждого своего тотема (Кольцо огня);
##   эффект damage: crit_if — гарантированный крит по цели с этим эффектом (Выброс лавы по Огненному шоку);
##   эффект dot: procs — тики считаются попаданием заклинания для проков (Волна лавы от Огненного шока);
##   эффект mana_pct — цель восполняет долю запаса маны (Тотем прилива маны).
##   Баффы: thorns — урон природой по врагу ближнего боя, ударившему героя (Щит молний);
##   heal_on_hit — лечение цели при получении удара, не чаще раза в 2 сек. (Щит земли).

const CLASS := "shaman"

## Книга заклинаний: столбец ряда = ветка талантов (Стихии / Совершенствование / Исцеление).
const BOOK := {
	"base": ["lightning_bolt", "healing_wave", "flame_shock", "wind_shear", "searing_totem", "lightning_shield"],
	"rows": [
		{"level": 2, "name": "Ротация", "role": "ротация", "options": ["lava_burst", "stormstrike", "riptide"]},
		{"level": 3, "name": "Мобильность", "role": "мобильность", "options": ["thunderstorm", "ghost_wolf", "spiritwalkers_grace"]},
		{"level": 5, "name": "Площадь", "role": "площадь", "options": ["chain_lightning", "magma_totem", "chain_heal"]},
		{"level": 7, "name": "Контроль", "role": "контроль", "options": ["frost_shock", "earthbind_totem", "hex"]},
		{"level": 9, "name": "Тотем поддержки", "role": "утилита", "options": ["wrath_of_air_totem", "windfury_totem", "healing_stream_totem"]},
		{"level": 11, "name": "Личная защита", "role": "защита", "options": ["astral_shift", "shamanistic_rage", "earth_shield"]},
		{"level": 14, "name": "Зона", "role": "площадь", "options": ["earthquake", "fire_nova", "healing_rain"]},
		{"level": 18, "name": "Большая", "role": "большая", "options": ["elemental_mastery", "heroism", "mana_tide_totem"]},
		{"level": 22, "name": "Мастерство", "role": "мастерство", "options": ["elemental_overload", "flametongue", "ancestral_awakening"]},
	],
}

const SPELLS := {
	# ======================= ШАМАН: базовые =======================
	"lightning_bolt": {
		"name": "Молния", "school": "nature", "icon": "Мл",
		"desc": "Разряд молнии бьёт врага: 36–42 урона силами природы.",
		"target": "enemy", "delivery": "projectile", "speed": 60.0,
		"cast": 2.0, "cd": 0.0, "mana": 20.0, "range": 34.0,
		"effects": [{"type": "damage", "min": 36.0, "max": 42.0}],
		"vfx": "bolt_nature", "anim": "cast",
	},
	"healing_wave": {
		"name": "Волна исцеления", "school": "nature", "icon": "ВИ",
		"desc": "Волна воды исцеляет союзника на 95–110 здоровья.",
		"target": "ally", "delivery": "instant",
		"cast": 2.5, "cd": 0.0, "mana": 26.0, "range": 36.0,
		"effects": [{"type": "heal", "min": 95.0, "max": 110.0}],
		"vfx": "heal_burst", "anim": "cast",
	},
	"flame_shock": {
		"name": "Огненный шок", "school": "fire", "icon": "ОгШ",
		"desc": "Опаляет врага: 22–26 урона огнём сразу и ещё 36 за 12 сек.",
		"target": "enemy", "delivery": "instant",
		"cast": 0.0, "cd": 6.0, "mana": 18.0, "range": 25.0,
		"effects": [{"type": "damage", "min": 22.0, "max": 26.0}, {"type": "dot", "total": 36.0, "dur": 12.0, "tick": 3.0, "key": "flame_shock", "procs": true}],
		"vfx": "hit_fire", "anim": "shoot",
	},
	"wind_shear": {
		"name": "Пронизывающий ветер", "school": "nature", "icon": "ПВ", "no_gcd": true,
		"desc": "Порыв ветра сбивает заклинание врага; школа сбитого заклинания заблокирована на 3 сек. Перезарядка короче, чем у других прерываний. Не тратит общую перезарядку.",
		"target": "enemy", "delivery": "instant",
		"cast": 0.0, "cd": 15.0, "mana": 8.0, "range": 25.0,
		"effects": [{"type": "interrupt", "lock": 3.0}],
		"vfx": "chain_nature", "anim": "shoot",
	},
	"searing_totem": {
		"name": "Тотем жара", "school": "fire", "icon": "ТЖ",
		"desc": "Тотем огня у ног шамана на 45 сек.: каждые 1,5 сек. бьёт лучом пламени врага в 22 м (10–13 урона).",
		"target": "self", "delivery": "totem", "radius": 22.0, "tick": 1.5,
		"totem": {"element": "fire", "life": 45.0, "shoot": 1},
		"cast": 0.0, "cd": 0.0, "mana": 16.0, "range": 0.0,
		"enemy_fx": [{"type": "damage", "min": 10.0, "max": 13.0}],
		"vfx": "totem_fire", "anim": "raise",
	},
	"lightning_shield": {
		"name": "Щит молний", "school": "nature", "icon": "ЩМ",
		"desc": "Шары молний кружат вокруг шамана 10 минут: враг ближнего боя, ударивший его, получает 12 урона силами природы (не чаще раза в секунду).",
		"target": "self", "delivery": "instant",
		"cast": 0.0, "cd": 0.0, "mana": 14.0, "range": 0.0,
		"effects": [{"type": "buff", "key": "lightning_shield", "dur": 600.0, "mods": {"thorns": 12.0}}],
		"vfx": "aura_nature", "anim": "raise",
	},

	# ======================= книга: ряды =======================
	# --- Ротация
	"lava_burst": {
		"name": "Выброс лавы", "school": "fire", "icon": "ВЛ",
		"desc": "Сгусток лавы: 62–74 урона огнём. По врагу с Огненным шоком — всегда критический удар.",
		"target": "enemy", "delivery": "projectile", "speed": 30.0,
		"cast": 2.0, "cd": 8.0, "mana": 24.0, "range": 34.0,
		"effects": [{"type": "damage", "min": 62.0, "max": 74.0, "crit_if": "flame_shock"}],
		"vfx": "bolt_fire", "anim": "cast",
	},
	"stormstrike": {
		"name": "Удар бури", "school": "physical", "icon": "УБ",
		"desc": "Удар оружием, заряженным бурей: 48–56 урона. 12 сек. цель получает на 20% больше урона от заклинаний.",
		"target": "enemy", "delivery": "instant",
		"cast": 0.0, "cd": 8.0, "mana": 14.0, "range": 5.0,
		"effects": [{"type": "damage", "min": 48.0, "max": 56.0}, {"type": "buff", "key": "stormstrike", "dur": 12.0, "mods": {"magic_taken": 0.2}}],
		"vfx": "chain_nature", "anim": "melee2",
	},
	"riptide": {
		"name": "Быстрина", "school": "nature", "icon": "Бс",
		"desc": "Мгновенно исцеляет союзника на 40–48 и ещё на 60 за 12 сек.",
		"target": "ally", "delivery": "instant",
		"cast": 0.0, "cd": 6.0, "mana": 18.0, "range": 36.0,
		"effects": [{"type": "heal", "min": 40.0, "max": 48.0}, {"type": "hot", "total": 60.0, "dur": 12.0, "tick": 3.0, "key": "riptide"}],
		"vfx": "heal_small", "anim": "shoot",
	},
	# --- Мобильность
	"thunderstorm": {
		"name": "Гром и молния", "school": "nature", "icon": "ГМ",
		"desc": "Раскат грома вокруг шамана (8 м): 28–34 урона, враги отброшены на 8 м. Шаман восполняет 8% маны.",
		"target": "self", "delivery": "self_aoe", "radius": 8.0,
		"cast": 0.0, "cd": 25.0, "mana": 0.0, "range": 0.0,
		"enemy_fx": [{"type": "damage", "min": 28.0, "max": 34.0}, {"type": "knockback", "dist": 8.0}],
		"self_fx": [{"type": "mana_pct", "pct": 0.08}],
		"vfx": "nova_nature", "anim": "raise",
	},
	"ghost_wolf": {
		"name": "Призрачный волк", "school": "nature", "icon": "ПрВ", "no_gcd": true,
		"desc": "Дух волка: скорость бега +40% на 8 сек.",
		"target": "self", "delivery": "instant",
		"cast": 0.0, "cd": 20.0, "mana": 10.0, "range": 0.0,
		"effects": [{"type": "buff", "key": "ghost_wolf", "dur": 8.0, "mods": {"speed": 0.4}}],
		"vfx": "aura_nature", "anim": "raise",
	},
	"spiritwalkers_grace": {
		"name": "Благосклонность предков", "school": "nature", "icon": "БП", "no_gcd": true,
		"desc": "10 сек. шаман произносит заклинания на ходу, а скорость бега +15%.",
		"target": "self", "delivery": "instant",
		"cast": 0.0, "cd": 45.0, "mana": 12.0, "range": 0.0,
		"effects": [{"type": "buff", "key": "spiritwalkers_grace", "dur": 10.0, "mods": {"speed": 0.15}}],
		"vfx": "aura_nature", "anim": "raise",
	},
	# --- Площадь
	"chain_lightning": {
		"name": "Цепная молния", "school": "nature", "icon": "ЦМ",
		"desc": "Молния бьёт врага (40–46 урона) и перескакивает ещё на 3 врагов в 10 м (70% урона).",
		"target": "enemy", "delivery": "instant",
		"cast": 2.0, "cd": 6.0, "mana": 32.0, "range": 32.0,
		"effects": [{"type": "damage", "min": 40.0, "max": 46.0}, {"type": "chain", "count": 3, "radius": 10.0, "mult": 0.7}],
		"vfx": "chain_nature", "anim": "cast",
	},
	"magma_totem": {
		"name": "Тотем магмы", "school": "fire", "icon": "ТМ",
		"desc": "Тотем огня на 20 сек.: каждые 2 сек. извергает магму — 14–17 урона всем врагам в 8 м.",
		"target": "self", "delivery": "totem", "radius": 8.0, "tick": 2.0,
		"totem": {"element": "fire", "life": 20.0, "shoot": 0},
		"cast": 0.0, "cd": 0.0, "mana": 26.0, "range": 0.0,
		"enemy_fx": [{"type": "damage", "min": 14.0, "max": 17.0}],
		"vfx": "totem_fire", "anim": "raise",
	},
	"chain_heal": {
		"name": "Цепное исцеление", "school": "nature", "icon": "ЦИ",
		"desc": "Исцеляет до 4 самых раненых союзников в 14 м от цели на 48–56.",
		"target": "ally", "delivery": "ally_aoe", "radius": 14.0, "max_targets": 4,
		"cast": 2.5, "cd": 0.0, "mana": 34.0, "range": 36.0,
		"effects": [{"type": "heal", "min": 48.0, "max": 56.0}],
		"vfx": "heal_circle", "anim": "cast",
	},
	# --- Контроль
	"frost_shock": {
		"name": "Ледяной шок", "school": "frost", "icon": "ЛШ",
		"desc": "Сковывает врага холодом: 30–36 урона и замедление на 50% на 8 сек.",
		"target": "enemy", "delivery": "instant",
		"cast": 0.0, "cd": 8.0, "mana": 18.0, "range": 25.0,
		"effects": [{"type": "damage", "min": 30.0, "max": 36.0}, {"type": "slow", "pct": 0.5, "dur": 8.0}],
		"vfx": "frozen", "anim": "shoot",
	},
	"earthbind_totem": {
		"name": "Тотем оков земли", "school": "nature", "icon": "ТОЗ",
		"desc": "Тотем земли на 20 сек.: враги в 10 м замедлены на 50%.",
		"target": "self", "delivery": "totem", "radius": 10.0, "tick": 1.0,
		"totem": {"element": "earth", "life": 20.0, "shoot": 0},
		"cast": 0.0, "cd": 15.0, "mana": 14.0, "range": 0.0,
		"enemy_fx": [{"type": "slow", "pct": 0.5, "dur": 1.5}],
		"vfx": "totem_earth", "anim": "raise",
	},
	"hex": {
		"name": "Сглаз", "school": "nature", "icon": "Сг",
		"desc": "Превращает врага в лягушку на 8 сек. (боссов — на 4). Урон снимает чары.",
		"target": "enemy", "delivery": "instant",
		"cast": 1.5, "cd": 30.0, "mana": 14.0, "range": 25.0,
		"effects": [{"type": "incapacitate", "dur": 8.0}],
		"vfx": "chain_nature", "anim": "cast",
	},
	# --- Тотем поддержки
	"wrath_of_air_totem": {
		"name": "Тотем гнева воздуха", "school": "nature", "icon": "ТГВ",
		"desc": "Тотем воздуха на 2 минуты: союзники в 30 м произносят заклинания и атакуют на 10% быстрее.",
		"target": "self", "delivery": "totem", "radius": 30.0, "tick": 1.0,
		"totem": {"element": "air", "life": 120.0, "shoot": 0},
		"cast": 0.0, "cd": 0.0, "mana": 12.0, "range": 0.0,
		"ally_fx": [{"type": "buff", "key": "wrath_of_air", "dur": 2.5, "mods": {"haste": 0.1}}],
		"vfx": "totem_air", "anim": "raise",
	},
	"windfury_totem": {
		"name": "Тотем неистовства ветра", "school": "nature", "icon": "ТНВ",
		"desc": "Тотем воздуха на 2 минуты: союзники в 30 м наносят автоатакой на 20% больше урона и атакуют на 6% быстрее.",
		"target": "self", "delivery": "totem", "radius": 30.0, "tick": 1.0,
		"totem": {"element": "air", "life": 120.0, "shoot": 0},
		"cast": 0.0, "cd": 0.0, "mana": 12.0, "range": 0.0,
		"ally_fx": [{"type": "buff", "key": "windfury", "dur": 2.5, "mods": {"auto": 0.2, "haste": 0.06}}],
		"vfx": "totem_air", "anim": "raise",
	},
	"healing_stream_totem": {
		"name": "Тотем исцеляющего потока", "school": "nature", "icon": "ТИП",
		"desc": "Тотем воды на 30 сек.: каждые 2 сек. исцеляет всех союзников в 20 м на 12–15.",
		"target": "self", "delivery": "totem", "radius": 20.0, "tick": 2.0,
		"totem": {"element": "water", "life": 30.0, "shoot": 0},
		"cast": 0.0, "cd": 0.0, "mana": 22.0, "range": 0.0,
		"ally_fx": [{"type": "heal", "min": 12.0, "max": 15.0}],
		"vfx": "totem_water", "anim": "raise",
	},
	# --- Личная защита
	"astral_shift": {
		"name": "Астральный сдвиг", "school": "nature", "icon": "АС", "no_gcd": true,
		"desc": "Шаман уходит в астрал: получаемый урон −40% на 8 сек.",
		"target": "self", "delivery": "instant",
		"cast": 0.0, "cd": 90.0, "mana": 0.0, "range": 0.0,
		"effects": [{"type": "buff", "key": "astral_shift", "dur": 8.0, "mods": {"dmg_taken": -0.4}}],
		"vfx": "aura_nature", "anim": "raise",
	},
	"shamanistic_rage": {
		"name": "Ярость шамана", "school": "nature", "icon": "ЯШ", "no_gcd": true,
		"desc": "15 сек. получаемый урон −30%, а мана восполняется втрое быстрее.",
		"target": "self", "delivery": "instant",
		"cast": 0.0, "cd": 60.0, "mana": 0.0, "range": 0.0,
		"effects": [{"type": "buff", "key": "shamanistic_rage", "dur": 15.0, "mods": {"dmg_taken": -0.3, "regen": 2.0}}],
		"vfx": "aura_war", "anim": "raise",
	},
	"earth_shield": {
		"name": "Щит земли", "school": "nature", "icon": "ЩЗ",
		"desc": "Каменный щит на союзнике на 60 сек.: каждый полученный удар лечит его на 22 (не чаще раза в 2 сек.).",
		"target": "ally", "delivery": "instant",
		"cast": 0.0, "cd": 0.0, "mana": 22.0, "range": 36.0,
		"effects": [{"type": "buff", "key": "earth_shield", "dur": 60.0, "mods": {"heal_on_hit": 22.0}, "from_caster": true}],
		"vfx": "shield", "anim": "shoot",
	},
	# --- Зона
	"earthquake": {
		"name": "Землетрясение", "school": "nature", "icon": "Зт",
		"desc": "Земля дрожит 8 сек. (8 м): толчок оглушает врагов на 1,5 сек., затем 9–11 урона каждую секунду и замедление на 30%.",
		"target": "ground", "delivery": "zone", "radius": 8.0, "duration": 8.0, "tick": 1.0,
		"cast": 0.0, "cd": 25.0, "mana": 46.0, "range": 34.0,
		"impact_fx": [{"type": "stun", "dur": 1.5}],
		"enemy_fx": [{"type": "damage", "min": 9.0, "max": 11.0}, {"type": "slow", "pct": 0.3, "dur": 1.5}],
		"vfx": "zone_earthquake", "anim": "raise",
	},
	"fire_nova": {
		"name": "Кольцо огня", "school": "fire", "icon": "КО",
		"desc": "Пламя вырывается из шамана и из каждого его тотема: 26–31 урона врагам в 8 м.",
		"target": "self", "delivery": "self_aoe", "radius": 8.0, "from_totems": true,
		"cast": 0.0, "cd": 10.0, "mana": 30.0, "range": 0.0,
		"enemy_fx": [{"type": "damage", "min": 26.0, "max": 31.0}],
		"vfx": "explosion_fire", "anim": "raise",
	},
	"healing_rain": {
		"name": "Целительный ливень", "school": "nature", "icon": "ЦЛ",
		"desc": "Ливень в точке (10 м) на 10 сек.: союзники внутри исцеляются на 11–13 каждую секунду.",
		"target": "ground", "delivery": "zone", "radius": 10.0, "duration": 10.0, "tick": 1.0,
		"cast": 0.0, "cd": 20.0, "mana": 44.0, "range": 34.0,
		"ally_fx": [{"type": "heal", "min": 11.0, "max": 13.0}],
		"vfx": "zone_healing_rain", "anim": "raise",
	},
	# --- Большая
	"elemental_mastery": {
		"name": "Покорение стихий", "school": "nature", "icon": "ПС", "no_gcd": true,
		"desc": "15 сек. урон +25%, заклинания произносятся на 20% быстрее.",
		"target": "self", "delivery": "instant",
		"cast": 0.0, "cd": 120.0, "mana": 0.0, "range": 0.0,
		"effects": [{"type": "buff", "key": "elemental_mastery", "dur": 15.0, "mods": {"dmg": 0.25, "haste": 0.2}}],
		"vfx": "aura_nature", "anim": "raise",
	},
	"heroism": {
		"name": "Героизм", "school": "nature", "icon": "Гр",
		"desc": "Союзники в 40 м 30 сек. атакуют и произносят заклинания на 25% быстрее и наносят на 10% больше урона.",
		"target": "self", "delivery": "party", "radius": 40.0,
		"cast": 0.0, "cd": 300.0, "mana": 0.0, "range": 0.0,
		"effects": [{"type": "buff", "key": "heroism", "dur": 30.0, "mods": {"haste": 0.25, "dmg": 0.1}}],
		"vfx": "aura_war", "anim": "raise",
	},
	"mana_tide_totem": {
		"name": "Тотем прилива маны", "school": "nature", "icon": "ТПМ",
		"desc": "Тотем воды на 12 сек.: каждые 2 сек. союзники в 30 м восполняют 4% маны (всего 24%).",
		"target": "self", "delivery": "totem", "radius": 30.0, "tick": 2.0,
		"totem": {"element": "water", "life": 12.0, "shoot": 0},
		"cast": 0.0, "cd": 180.0, "mana": 0.0, "range": 0.0,
		"ally_fx": [{"type": "mana_pct", "pct": 0.04}],
		"vfx": "totem_water", "anim": "raise",
	},
	# --- Мастерство (пассивные)
	"elemental_overload": {
		"name": "Перегрузка", "school": "nature", "icon": "Пг", "passive": true,
		"desc": "Пассивно: Молния, Цепная молния и Выброс лавы с вероятностью 20% бьют ещё раз разрядом с неба — 20–24 урона в 2,5 м от цели.",
		"target": "self", "delivery": "instant", "cast": 0.0, "cd": 0.0, "mana": 0.0, "range": 0.0,
		"proc": {"on": "spell_hit", "spells": ["lightning_bolt", "chain_lightning", "lava_burst"], "chance": 0.2, "icd": 1.0, "spell": "overload"},
		"vfx": "beam_nature", "anim": "raise",
	},
	"flametongue": {
		"name": "Оружие языка пламени", "school": "fire", "icon": "ЯП", "passive": true,
		"desc": "Пассивно: оружие охвачено пламенем — каждая автоатака наносит ещё 8–10 урона огнём цели и врагам вплотную к ней.",
		"target": "self", "delivery": "instant", "cast": 0.0, "cd": 0.0, "mana": 0.0, "range": 0.0,
		"proc": {"on": "auto", "chance": 1.0, "icd": 0.5, "spell": "flametongue_hit"},
		"vfx": "hit_fire", "anim": "raise",
	},
	"ancestral_awakening": {
		"name": "Пробуждение предков", "school": "nature", "icon": "ПП", "passive": true,
		"desc": "Пассивно: критическое исцеление пробуждает духов предков — 28–34 лечения союзникам в 8 м от цели.",
		"target": "self", "delivery": "instant", "cast": 0.0, "cd": 0.0, "mana": 0.0, "range": 0.0,
		"proc": {"on": "heal", "crit": true, "chance": 1.0, "icd": 1.0, "spell": "ancestral_awakening"},
		"vfx": "heal_circle", "anim": "raise",
	},

	# ======================= заклинания талантов =======================
	"lava_eruption": {
		"name": "Извержение лавы", "school": "fire", "icon": "ИЛ", "talent": true,
		"desc": "Из земли в точке бьёт лава: 46–56 урона огнём врагам в 6 м и ещё 16 за 4 сек. Перезарядку сбрасывает прок «Волна лавы».",
		"target": "ground", "delivery": "auto_spell", "auto": "lava_eruption", "radius": 6.0,
		"cast": 0.0, "cd": 30.0, "mana": 40.0, "range": 36.0,
		"vfx": "eruption", "anim": "raise",
	},
	"totem_of_wrath": {
		"name": "Тотем гнева", "school": "fire", "icon": "ТГ", "talent": true,
		"desc": "Тотем огня на 60 сек.: каждые 2 сек. бьёт лучом пламени врага в 30 м (30–36 урона), а союзники в 30 м наносят на 10% больше урона и лечат на 10% сильнее.",
		"target": "self", "delivery": "totem", "radius": 30.0, "tick": 2.0,
		"totem": {"element": "fire", "life": 60.0, "shoot": 1},
		"cast": 0.0, "cd": 60.0, "mana": 30.0, "range": 0.0,
		"enemy_fx": [{"type": "damage", "min": 30.0, "max": 36.0}],
		"ally_fx": [{"type": "buff", "key": "totem_of_wrath", "dur": 3.0, "mods": {"dmg": 0.1, "heal": 0.1}}],
		"vfx": "totem_wrath", "anim": "raise",
	},
	"feral_spirit": {
		"name": "Дух дикого зверя", "school": "physical", "icon": "ДДЗ", "talent": true,
		"desc": "Призрачные волки 20 сек. кружат рядом с шаманом: каждую секунду кусают врагов в 6 м на 16–20 урона.",
		"target": "self", "delivery": "instant",
		"cast": 0.0, "cd": 90.0, "mana": 24.0, "range": 0.0,
		"effects": [{"type": "pulse", "key": "feral_spirit", "tick": 1.0, "dur": 20.0, "radius": 6.0, "vfx": "spirit_wolves",
			"effects": [{"type": "damage", "min": 16.0, "max": 20.0}]},
			{"type": "buff", "key": "feral_spirit", "dur": 20.0, "mods": {}}],
		"vfx": "aura_nature", "anim": "raise",
	},
	"healing_tide_totem": {
		"name": "Тотем целительного прилива", "school": "nature", "icon": "ТЦП", "talent": true,
		"desc": "Тотем воды на 12 сек.: каждые 2 сек. исцеляет всех союзников в 30 м на 38–44.",
		"target": "self", "delivery": "totem", "radius": 30.0, "tick": 2.0,
		"totem": {"element": "water", "life": 12.0, "shoot": 0},
		"cast": 0.0, "cd": 90.0, "mana": 40.0, "range": 0.0,
		"ally_fx": [{"type": "heal", "min": 38.0, "max": 44.0}],
		"vfx": "totem_tide", "anim": "raise",
	},
}
