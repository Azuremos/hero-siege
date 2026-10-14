extends RefCounted
## Четыре фракции осаждают замок, каждая со своей стороны света, со своим логовом на карте.
## Полосы: 0 — север, 1 — восток, 2 — юг, 3 — запад. Направления открываются в порядке
## юг → восток → запад → север (как и раньше), поэтому при 1 направлении — нежить,
## при 2 — нежить и орки, при 3 — плюс демоны, при 4 — все.
##
## Поля: name, side, lane — полоса по умолчанию, color — цвет на интерфейсе и в логове,
## champion — кто выходит вместо босса на «босс-волнах» (у нежити — свои боссы), bosses,
## sounds — death (смерть), war_cry (клич на старте волны), pitch — высота голоса.

const FACTIONS := {
	"undead": {"name": "Нежить", "side": "юга", "lane": 2, "color": Color(0.6, 0.85, 0.7),
		"champion": "", "bosses": ["boss_warlord", "boss_lich"],
		"sounds": {"death": "bones_fall", "war_cry": "horde", "pitch": 1.0}},
	"orcs": {"name": "Орки", "side": "востока", "lane": 1, "color": Color(0.45, 0.8, 0.3),
		"champion": "berserker", "bosses": [],
		"sounds": {"death": "hurt", "war_cry": "boss_roar", "pitch": 0.85}},
	"demons": {"name": "Демоны", "side": "запада", "lane": 3, "color": Color(1.0, 0.35, 0.2),
		"champion": "felguard", "bosses": [],
		"sounds": {"death": "fire_burn", "war_cry": "boss_roar", "pitch": 0.6}},
	"goblins": {"name": "Гоблины и огры", "side": "севера", "lane": 0, "color": Color(0.85, 0.75, 0.3),
		"champion": "ogre", "bosses": [],
		"sounds": {"death": "hurt", "war_cry": "horde", "pitch": 1.45}},
}

const ORDER := ["undead", "orcs", "demons", "goblins"]

## Особые волны: роли, которые в такой волне встречаются чаще.
const SPECIAL_WAVES := {
	"scout": {"name": "Разведка", "roles": {"fast": 3.0, "swarm": 1.0}},
	"siege": {"name": "Осада", "roles": {"heavy": 2.5, "special": 2.0, "swarm": 0.6}},
	"arcane": {"name": "Колдовская волна", "roles": {"support": 3.0, "ranged": 1.5, "swarm": 0.6}},
}

## Обычные веса ролей в волне.
const ROLE_WEIGHTS := {"swarm": 4.5, "heavy": 1.8, "fast": 1.5, "ranged": 1.7, "support": 0.8, "special": 0.7}
