extends RefCounted
## Враги: характеристики, модели, оружие. Состав волн и рост силы врагов — в formulas.gd.

const MOBS := {
	"minion": {"name": "Скелет-прислужник", "model": "Skeleton_Minion", "weapons": {"r": "Skeleton_Blade"},
		"hp": 90.0, "min": 7.0, "max": 10.0, "atk_speed": 1.6, "range": 2.4, "speed": 4.4,
		"xp": 14, "gold": 2, "scale": 1.0, "radius": 0.6, "armor": 0.0},
	"warrior": {"name": "Скелет-воин", "model": "Skeleton_Warrior", "weapons": {"r": "Skeleton_Axe", "l": "Skeleton_Shield_Large_A"},
		"hp": 220.0, "min": 13.0, "max": 17.0, "atk_speed": 2.0, "range": 2.6, "speed": 3.5,
		"xp": 30, "gold": 4, "scale": 1.05, "radius": 0.75, "armor": 0.15},
	"rogue": {"name": "Скелет-разбойник", "model": "Skeleton_Rogue", "weapons": {"r": "Skeleton_Blade", "l": "Skeleton_Blade"},
		"hp": 120.0, "min": 11.0, "max": 14.0, "atk_speed": 1.2, "range": 2.4, "speed": 5.6,
		"xp": 20, "gold": 3, "scale": 1.0, "radius": 0.6, "armor": 0.0},
	"mage": {"name": "Скелет-маг", "model": "Skeleton_Mage", "weapons": {"r": "Skeleton_Staff"},
		"hp": 100.0, "min": 15.0, "max": 19.0, "atk_speed": 2.4, "range": 18.0, "speed": 3.7,
		"xp": 26, "gold": 4, "scale": 1.0, "radius": 0.6, "armor": 0.0, "ranged": true},
	"boss_warlord": {"name": "Костяной полководец", "model": "Skeleton_Warrior", "weapons": {"r": "Skeleton_Axe", "l": "Skeleton_Shield_Large_B"},
		"hp": 2400.0, "min": 40.0, "max": 55.0, "atk_speed": 2.4, "range": 4.0, "speed": 3.3,
		"xp": 420, "gold": 60, "scale": 1.9, "radius": 1.4, "armor": 0.3, "cleave": 4.0, "boss": true},
	"boss_lich": {"name": "Лич-некромант", "model": "Skeleton_Mage", "weapons": {"r": "Skeleton_Staff"},
		"hp": 1900.0, "min": 45.0, "max": 60.0, "atk_speed": 2.6, "range": 22.0, "speed": 3.2,
		"xp": 480, "gold": 70, "scale": 1.8, "radius": 1.3, "armor": 0.1, "ranged": true, "splash": 5.0, "boss": true},
}
