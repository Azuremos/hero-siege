extends RefCounted
## Бой героев против героев (сессия 13) — общая основа для всех режимов с PvP (Арена, Footman Frenzy, дуэли).
## Режим берёт DEFAULT и переопределяет нужные поля (GameMode.pvp_config). Вещи под PvP не правим — только
## встроенная устойчивость по уровню, убывание контроля, утомление боем и PvP-коэффициенты заклинаний.
## Действует только между враждующими героями (и их питомцами): урон и контроль мобов не меняются.

const DEFAULT := {
	# встроенная устойчивость героя: режет урон от героев, силу критов по героям и длительность контроля
	"resil_base": 0.10,          # на 1-м уровне
	"resil_per_level": 0.0104,   # +за уровень: на 30-м ≈ 0,40 (ориентир задания −40%)
	"resil_max": 0.6,
	"crit_mult": 1.35,           # крит по герою (вместо ×1,5), сверх ×1 ещё режется устойчивостью
	"cc_mult": 0.5,              # контроль по героям вдвое короче…
	"cc_resil": 0.5,             # …и ещё короче с устойчивостью (доля устойчивости)
	"cc_cap": {"stun": 4.0, "fear": 4.0, "incap": 6.0, "root": 5.0, "silence": 4.0},
	# убывание одного типа контроля: 100% → 50% → 25% → неуязвимость, сброс через dr_reset сек. после последнего
	"dr": [1.0, 0.5, 0.25, 0.0],
	"dr_reset": 15.0,
	# утомление боем: PvP-схватка дольше dampen_after сек. (или дуэль) — получаемое лечение −dampen_step каждые dampen_every
	"dampen_after": 30.0,
	"dampen_every": 10.0,
	"dampen_step": 0.05,
	"dampen_max": 0.9,
	"pvp_combat_reset": 8.0,     # столько сек. без урона между героями — схватка закончилась
	# общий множитель урона героя по героям (дуэль на 20–60 сек., а не на 2)
	"dmg_mult": 0.6,
	"heal_mult": 1.0,
}

## Как контроль действует на героя: тип эффекта → [тип на герое, категория убывания].
## Заморозка по герою — обездвиживание (колдовать можно, как Кольцо льда в WoW), превращение и ослепление — выключение,
## которое снимает урон. Холод на героев не копится (замедление ледяных заклинаний остаётся). Провокация героев не трогает.
## Поле эффекта pvp_as (в данных заклинания) переопределяет тип: Глубокая заморозка — оглушение.
const CC := {
	"stun": ["stun", "stun"],
	"freeze": ["root", "root"],
	"root": ["root", "root"],
	"incapacitate": ["incapacitate", "incap"],
	"fear": ["fear", "fear"],
	"silence": ["silence", "silence"],
	"chill": ["", ""],
	"taunt": ["", ""],
}

## Названия категорий для всплывающего «Невосприимчив» и подсказок.
const CC_NAMES := {"stun": "оглушение", "root": "обездвиживание", "incap": "выключение", "fear": "страх", "silence": "немота"}

## PvP-коэффициенты урона заклинаний по героям (поверх dmg_mult). Ключ — id заклинания или автозаклинания.
## Взрывные проки и сбросы перезарядки — с отдельным коэффициентом: иначе дуэль решает одна удача.
## Поле pvp_mult в данных самого заклинания важнее этой таблицы.
const SPELL_MULT := {
	# проки-глыбы и взрывы (spell_effects.AUTO_SPELLS)
	"meteor": 0.45, "earthsplitter": 0.5, "lava_eruption": 0.5, "hammer_of_heaven": 0.5, "holy_star": 0.6,
	"holy_word_sanctify": 0.6, "divine_burst": 0.6, "flame_burst": 0.6, "chain_spark": 0.6, "purgatory_flash": 0.7,
	# площадь охотника — её сбрасывает «Шквал стрел»
	"multi_shot": 0.6, "volley": 0.6, "explosive_trap": 0.6, "barrage": 0.7,
	# большие одиночные удары
	"execute": 0.7, "kill_shot": 0.7, "pyroblast": 0.8, "living_bomb": 0.7, "mortal_strike": 0.85,
	"lava_burst": 0.85, "aimed_shot": 0.8, "chimera_shot": 0.85,
}

## Множитель урона класса по героям (подгонка таблицы «класс × класс»).
const CLASS_MULT := {"mage": 1.0, "paladin": 1.0, "priest": 1.0, "warrior": 1.0, "hunter": 1.0, "shaman": 1.0}

## Устойчивость героя уровня level по настройкам режима cfg.
static func resil(cfg: Dictionary, level: int) -> float:
	return clampf(float(cfg["resil_base"]) + float(cfg["resil_per_level"]) * float(level - 1), 0.0, float(cfg["resil_max"]))

## Коэффициент урона заклинания sid героя класса cls по герою (без устойчивости).
static func spell_k(cfg: Dictionary, sid: String, cls: String, spell: Dictionary) -> float:
	var k := float(cfg["dmg_mult"]) * float(CLASS_MULT.get(cls, 1.0))
	if spell.has("pvp_mult"):
		return k * float(spell["pvp_mult"])
	return k * float(SPELL_MULT.get(sid, 1.0))
