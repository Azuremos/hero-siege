extends RefCounted
## Аффиксы элитных мобов — общие для всех фракций (по образцу Diablo и эпохальных подземелий WoW).
## У элитного 1–3 аффикса, у чемпиона фракции — 3. Механики — в mob_manager.gd и spell_system.gd
## (ищите по id аффикса), часть — способностями из mob_abilities.gd (ability).

const ELITE_HP := 3.5          # здоровье элитного (чемпиона — CHAMPION_HP)
const CHAMPION_HP := 5.0
const ELITE_DMG := 1.3
const ELITE_REWARD := 4.0      # опыт и золото
const ELITE_SCALE := 1.25

## Шанс, что моб волны элитный: с 4-й волны, растёт до 12%.
static func elite_chance(wave: int) -> float:
	if wave < 4:
		return 0.0
	return minf(0.12, 0.015 + 0.006 * float(wave))

const AFFIXES := {
	"armored": {"name": "Бронированный", "color": Color(0.7, 0.75, 0.85), "desc": "Броня выше на 35%."},
	"fast": {"name": "Быстрый", "color": Color(0.4, 0.9, 1.0), "desc": "Бегает на 40% и бьёт на 25% быстрее."},
	"vampiric": {"name": "Вампирический", "color": Color(0.85, 0.1, 0.15), "desc": "Лечится на 30% нанесённого урона."},
	"explosive": {"name": "Взрывной", "color": Color(1.0, 0.45, 0.1), "desc": "Взрывается через 1,5 сек. после смерти — отойдите из круга."},
	"reflect": {"name": "Отражающий", "color": Color(0.9, 0.9, 0.4), "desc": "Возвращает 20% полученного урона нападающему."},
	"inspiring": {"name": "Вдохновляющий", "color": Color(1.0, 0.75, 0.3), "desc": "Союзники рядом наносят на 20% больше урона и бегают быстрее.", "ability": "affix_inspire"},
	"summoner": {"name": "Призыватель", "color": Color(0.6, 0.3, 0.9), "desc": "Время от времени зовёт подмогу.", "ability": "affix_summon"},
	"fire_trail": {"name": "Огненный след", "color": Color(1.0, 0.3, 0.05), "desc": "Оставляет за собой горящую землю."},
	"unstoppable": {"name": "Неудержимый", "color": Color(0.95, 0.95, 0.95), "desc": "Не поддаётся оглушению, заморозке, страху и отбрасыванию. Замедлить можно."},
}
