extends RefCounted
## Классовые сеты и именные легендарки (сессия 07б).
##
## Сет — по одному на ветку талантов каждого класса, 6 частей: голова, плечи, доспех, обувь, кольцо, амулет.
## Оружие и левая рука в сеты не входят (решение пользователя) — это место для именных легендарок.
## Часть сета — экземпляр вещи: шаблон из bases, качество фиолетовое, уровень — как у обычной добычи,
## поле экземпляра set_id. Свойства части фиксированы (affixes сета), проков у частей нет.
##
## Бонусы за число надетых частей (bonuses: {число: бонус}):
##   stats  — характеристики (как у вещей);
##   mods   — модификаторы, как у талантов: [область, ключ, значение]. "spell:X" для заклинания из ряда книги
##            действует на любой выбранный вариант ряда (как таланты, решение пользователя из сессии 04);
##   proc   — прок в общей системе проков (spell_system._trigger_procs): buff, spell, every и т.д.;
##   flags  — особые флаги героя (spell_system).
## look — цвет ткани и металла частей на модели; полный сет (5+) светится этим цветом.

const SLOTS := ["helm", "shoulders", "chest", "boots", "ring", "amulet"]
## Шаблоны частей по типу брони класса.
const BASES := {
	"cloth": {"helm": "hat", "shoulders": "pads_cloth", "chest": "robe", "boots": "boots", "ring": "ring_mind", "amulet": "amulet"},
	"cloth_hood": {"helm": "hood", "shoulders": "pads_cloth", "chest": "robe", "boots": "boots", "ring": "ring_mind", "amulet": "amulet"},
	"plate": {"helm": "helm", "shoulders": "pads_plate", "chest": "plate", "boots": "boots", "ring": "ring_might", "amulet": "amulet"},
	"mail": {"helm": "hood", "shoulders": "pads_mail", "chest": "mail", "boots": "boots", "ring": "ring_might", "amulet": "amulet"},
	# шаман-заклинатель: кольчуга стихий и шапка духов (сессия 11); Совершенствование носит обычную кольчугу
	"mail_shaman": {"helm": "spirit_hat", "shoulders": "pads_mail", "chest": "mail_caster", "boots": "boots", "ring": "ring_mind", "amulet": "amulet"},
	# разбойник: кожа на ловкость
	"leather": {"helm": "leather_hood", "shoulders": "pads_mail", "chest": "leather", "boots": "boots", "ring": "ring_agile", "amulet": "amulet_hunt"},
	"mail_shaman_melee": {"helm": "spirit_hat", "shoulders": "pads_mail", "chest": "mail", "boots": "boots", "ring": "ring_might", "amulet": "amulet"},
}
const SLOT_NOUN := {"helm": "Венец", "shoulders": "Наплечье", "chest": "Облачение", "boots": "Поступь", "ring": "Перстень", "amulet": "Медальон"}

const SETS := {
	# ---------------- Маг
	"set_arcane": {"class": "mage", "tree": 0, "name": "Чародея Звёздной Бездны", "armor": "cloth", "affixes": ["int", "sp"],
		"look": Color(0.75, 0.5, 1.1),
		"bonuses": {
			2: {"stats": {"int": 12, "regen": 0.05}, "desc": "+12 к интеллекту, мана восполняется на 5% быстрее."},
			3: {"mods": [["spell:arcane_missiles", "amount", 0.15], ["spell:arcane_barrage", "amount", 0.15], ["spell:arcane_explosion", "amount", 0.15]],
				"desc": "Чародейские стрелы, Чародейский обстрел и Чародейский взрыв (и их варианты в книге) на 15% сильнее."},
			5: {"proc": {"on": "spell_hit", "school": "arcane", "chance": 0.15, "icd": 6.0, "buff": "arcane_surge"},
				"desc": "Заклинания тайной магии с вероятностью 15% вызывают Всплеск тайной магии: следующие Чародейские стрелы или Обстрел бесплатны, мгновенно готовы и на 50% сильнее."}}},
	"set_fire": {"class": "mage", "tree": 1, "name": "Пепельного Владыки", "armor": "cloth", "affixes": ["int", "crit"],
		"look": Color(1.15, 0.55, 0.3),
		"bonuses": {
			2: {"stats": {"sp": 18, "crit": 0.02}, "desc": "+18 к силе заклинаний, +2% к шансу крит. удара."},
			3: {"mods": [["spell:fireball", "amount", 0.15], ["spell:flamestrike", "amount", 0.15], ["school:fire", "crit", 0.03]],
				"desc": "Огненный шар и Огненный столб (и их варианты в книге) на 15% сильнее, шанс крита огнём +3%."},
			5: {"proc": {"on": "spell_hit", "spells": ["fireball"], "every": 5, "icd": 1.0, "spell": "meteor"},
				"desc": "Каждый 5-й Огненный шар обрушивает на цель Огненную глыбу: 55–70 урона огнём в 6 м и горение."}}},
	"set_frost": {"class": "mage", "tree": 2, "name": "Вечной Мерзлоты", "armor": "cloth", "affixes": ["int", "sta"],
		"look": Color(0.55, 0.85, 1.15),
		"bonuses": {
			2: {"stats": {"int": 10, "sta": 10}, "desc": "+10 к интеллекту и выносливости."},
			3: {"mods": [["spell:frostbolt", "amount", 0.15], ["spell:blizzard", "amount", 0.15], ["spell:frost_nova", "cd_add", -4.0]],
				"desc": "Ледяная стрела и Снежная буря (и их варианты) на 15% сильнее, перезарядка заклинания ряда «Контроль» −4 сек."},
			5: {"proc": {"on": "spell_hit", "school": "frost", "chance": 0.15, "icd": 4.0, "buff": "fingers_of_frost"},
				"desc": "Заклинания льда с вероятностью 15% дают Ледяные пальцы: Ледяное копьё сразу готово, бесплатно, на 50% сильнее и летит ещё в 2 врагов."}}},
	# ---------------- Паладин
	"set_holy_pal": {"class": "paladin", "tree": 0, "name": "Утренней Зари", "armor": "plate", "affixes": ["int", "spi"],
		"look": Color(1.15, 1.0, 0.6),
		"bonuses": {
			2: {"stats": {"int": 10, "spi": 8}, "desc": "+10 к интеллекту, +8 к духу."},
			3: {"mods": [["spell:holy_light", "amount", 0.15], ["spell:holy_light", "mana", -0.1]],
				"desc": "Свет небес (и его варианты) лечит на 15% сильнее и стоит на 10% меньше маны."},
			5: {"proc": {"on": "heal", "crit": true, "chance": 0.5, "icd": 8.0, "spell": "holy_word_sanctify"},
				"desc": "Критическое лечение с вероятностью 50% вызывает Слово Света: Освящение — 60–72 лечения союзникам в 7 м."}}},
	"set_prot_pal": {"class": "paladin", "tree": 1, "name": "Несломленного Бастиона", "armor": "plate", "affixes": ["sta", "str"],
		"look": Color(0.75, 0.85, 1.1),
		"bonuses": {
			2: {"stats": {"sta": 16, "armor": 0.03}, "desc": "+16 к выносливости, броня +3%."},
			3: {"mods": [["spell:consecration", "amount", 0.2], ["global", "dmg_taken", -0.05]],
				"desc": "Освящение (и его варианты) на 20% сильнее, получаемый урон −5%."},
			5: {"proc": {"on": "hit_taken", "chance": 0.12, "icd": 4.0, "spell": "divine_burst"},
				"desc": "Получая удар, с вероятностью 12% паладин вспыхивает Светом: 28–34 урона всем врагам в 6 м."}}},
	"set_ret_pal": {"class": "paladin", "tree": 2, "name": "Карающего Рассвета", "armor": "plate", "affixes": ["str", "crit"],
		"look": Color(1.15, 0.7, 0.75),
		"bonuses": {
			2: {"stats": {"str": 12, "crit": 0.02}, "desc": "+12 к силе, +2% к шансу крит. удара."},
			3: {"mods": [["spell:crusader_strike", "amount", 0.15], ["spell:judgement", "amount", 0.15]],
				"desc": "Удар воина Света и Правосудие (и их варианты) на 15% сильнее."},
			5: {"proc": {"on": "auto", "chance": 0.12, "icd": 6.0, "spell": "hammer_of_heaven"},
				"desc": "Автоатаки с вероятностью 12% обрушивают Молот небес: 50–62 урона врагам и 28–34 лечения союзникам в 6 м."}}},
	# ---------------- Жрец
	"set_disc": {"class": "priest", "tree": 0, "name": "Безмолвного Обета", "armor": "cloth_hood", "affixes": ["int", "spi"],
		"look": Color(0.85, 0.85, 1.15),
		"bonuses": {
			2: {"stats": {"int": 10, "spi": 10}, "desc": "+10 к интеллекту и духу."},
			3: {"mods": [["spell:pw_shield", "amount", 0.2], ["spell:pw_shield", "mana", -0.1]],
				"desc": "Слово силы: Щит (и его варианты) поглощает на 20% больше и стоит на 10% меньше маны."},
			5: {"proc": {"on": "heal", "chance": 0.1, "icd": 8.0, "spell": "holy_star"},
				"desc": "Лечение с вероятностью 10% призывает Звезду Света: 40–50 урона врагам и 30–36 лечения союзникам в 6 м."}}},
	"set_holy_pr": {"class": "priest", "tree": 1, "name": "Сияющего Наару", "armor": "cloth_hood", "affixes": ["int", "sp"],
		"look": Color(1.15, 1.05, 0.75),
		"bonuses": {
			2: {"stats": {"sp": 16, "regen": 0.05}, "desc": "+16 к силе заклинаний, мана восполняется на 5% быстрее."},
			3: {"mods": [["spell:flash_heal", "amount", 0.15], ["spell:renew", "amount", 0.15], ["spell:circle_of_healing", "amount", 0.15]],
				"desc": "Быстрое исцеление, Обновление и Круг исцеления (и их варианты) лечат на 15% сильнее."},
			5: {"proc": {"on": "heal", "every": 5, "icd": 2.0, "spell": "holy_word_sanctify"},
				"desc": "Каждое 5-е лечение вызывает Слово Света: Освящение — 60–72 лечения союзникам в 7 м."}}},
	"set_shadow_pr": {"class": "priest", "tree": 2, "name": "Шёпота Бездны", "armor": "cloth_hood", "affixes": ["int", "sp"],
		"look": Color(0.75, 0.5, 1.1),
		"bonuses": {
			2: {"stats": {"int": 10, "sp": 12}, "desc": "+10 к интеллекту, +12 к силе заклинаний."},
			3: {"mods": [["spell:sw_pain", "amount", 0.15], ["spell:mind_blast", "amount", 0.15]],
				"desc": "Слово Тьмы: Боль и Взрыв разума (и вариант ряда) на 15% сильнее."},
			5: {"proc": {"on": "spell_hit", "school": "shadow", "chance": 0.12, "icd": 4.0, "spell": "shadowy_apparition"},
				"desc": "Заклинания Тьмы с вероятностью 12% выпускают Призрачное явление: 26–32 урона тьмой цели и врагам рядом."}}},
	# ---------------- Разбойник
	"set_assassin": {"class": "rogue", "tree": 0, "name": "Ядовитого Шёпота", "armor": "leather", "affixes": ["agi", "crit"],
		"look": Color(0.6, 1.0, 0.55),
		"bonuses": {
			2: {"stats": {"agi": 12, "crit": 0.02}, "desc": "+12 к ловкости, +2% к шансу крит. удара."},
			3: {"mods": [["school:nature", "amount", 0.15], ["spell:mutilate", "amount", 0.1]],
				"desc": "Яды на 15% сильнее, заклинание ряда «Ротация» (любой вариант) — на 10%."},
			5: {"proc": {"on": "cast", "spells": ["eviscerate", "envenom", "kidney_shot", "slice_and_dice", "nightblade"], "chance": 0.35, "icd": 1.0, "combo": 2},
				"desc": "Завершающий приём с вероятностью 35% сразу даёт 2 приёма серии."}}},
	"set_combat_r": {"class": "rogue", "tree": 1, "name": "Кровавых Клинков", "armor": "leather", "affixes": ["agi", "sta"],
		"look": Color(1.1, 0.55, 0.45),
		"bonuses": {
			2: {"stats": {"agi": 12, "ap": 12}, "desc": "+12 к ловкости, +12 к силе атаки."},
			3: {"mods": [["spell:sinister_strike", "amount", 0.15], ["spell:eviscerate", "amount", 0.15]],
				"desc": "Коварный удар и Потрошение на 15% сильнее."},
			5: {"proc": {"on": "auto", "chance": 0.15, "icd": 2.0, "mana_pct": 0.2, "combo": 1},
				"desc": "Автоатака с вероятностью 15% восполняет 20 энергии и даёт 1 приём серии."}}},
	"set_shadow_r": {"class": "rogue", "tree": 2, "name": "Ночной Тени", "armor": "leather", "affixes": ["agi", "crit"],
		"look": Color(0.65, 0.55, 1.1),
		"bonuses": {
			2: {"stats": {"agi": 12, "crit": 0.02}, "desc": "+12 к ловкости, +2% к шансу крит. удара."},
			3: {"mods": [["spell:ambush", "amount", 0.15], ["spell:hemorrhage", "amount", 0.15]],
				"desc": "Внезапный удар и заклинание ряда «Ротация» (любой вариант) на 15% сильнее."},
			5: {"proc": {"on": ["auto", "spell_hit"], "school": "physical", "chance": 0.08, "icd": 15.0, "buff": "shadow_dance", "dur": 5.0},
				"desc": "Удары оружием с вероятностью 8% дают 5 сек. Танца теней (не чаще раза в 15 сек.)."}}},
	# ---------------- Воин
	"set_arms": {"class": "warrior", "tree": 0, "name": "Полководца Старых Войн", "armor": "plate", "affixes": ["str", "crit"],
		"look": Color(0.9, 0.7, 0.5),
		"bonuses": {
			2: {"stats": {"str": 12, "ap": 12}, "desc": "+12 к силе, +12 к силе атаки."},
			3: {"mods": [["spell:execute", "amount", 0.2], ["spell:rend", "amount", 0.2]],
				"desc": "Казнь и Кровопускание (и их варианты в книге) на 20% сильнее."},
			5: {"proc": {"on": "auto", "chance": 0.08, "icd": 6.0, "buff": "sudden_death"},
				"desc": "Автоатаки с вероятностью 8% дают Внезапную смерть: Казнь доступна по любой цели и бесплатна."}}},
	"set_fury": {"class": "warrior", "tree": 1, "name": "Кровавого Безумия", "armor": "plate", "affixes": ["str", "agi"],
		"look": Color(1.1, 0.45, 0.4),
		"bonuses": {
			2: {"stats": {"str": 10, "haste": 0.04}, "desc": "+10 к силе, скорость атак +4%."},
			3: {"mods": [["spell:bloodthirst", "amount", 0.15], ["spell:whirlwind", "amount", 0.15]],
				"desc": "Жажда крови и Вихрь (и их варианты) на 15% сильнее."},
			5: {"proc": {"on": "spell_hit", "spells": ["bloodthirst", "whirlwind", "rend", "shield_slam", "sweeping_strikes", "thunder_clap"], "chance": 0.2, "icd": 3.0, "buff": "bloodsurge"},
				"desc": "Удар ряда «Ротация» или «Площадь» с вероятностью 20% даёт Прилив крови: следующий Удар героя бесплатен, мгновенно готов и на 50% сильнее."}}},
	"set_prot_w": {"class": "warrior", "tree": 2, "name": "Каменного Стража", "armor": "plate", "affixes": ["sta", "str"],
		"look": Color(0.7, 0.75, 0.85),
		"bonuses": {
			2: {"stats": {"sta": 16, "block": 0.04}, "desc": "+16 к выносливости, шанс блока +4%."},
			3: {"mods": [["spell:thunder_clap", "amount", 0.2], ["spell:shield_wall", "cd_add", -30.0]],
				"desc": "Удар грома (и его варианты) на 20% сильнее, перезарядка заклинания ряда «Личная защита» −30 сек."},
			5: {"proc": {"on": "hit_taken", "chance": 0.12, "icd": 4.0, "buff": "revenge"},
				"desc": "Получая удар, с вероятностью 12% воин получает Возмездие: следующий Удар грома бесплатен, сразу готов и на 50% сильнее."}}},
	# ---------------- Охотник
	"set_marks": {"class": "hunter", "tree": 0, "name": "Меткого Ветра", "armor": "mail", "affixes": ["agi", "crit"],
		"look": Color(0.85, 1.0, 0.6),
		"bonuses": {
			2: {"stats": {"agi": 12, "crit": 0.02}, "desc": "+12 к ловкости, +2% к шансу крит. удара."},
			3: {"mods": [["spell:arcane_shot", "amount", 0.15], ["spell:steady_shot", "amount", 0.15]],
				"desc": "Верный выстрел и выстрел ряда «Удар по готовности» (любой вариант) на 15% сильнее."},
			5: {"proc": {"on": "spell_hit", "spells": ["steady_shot"], "chance": 0.3, "icd": 4.0, "buff": "master_marksman"},
				"desc": "Верный выстрел с вероятностью 30% даёт Меткого стрелка: следующий Прицельный, Чародейский выстрел или Выстрел химеры — мгновенно, бесплатно и на 30% сильнее."}}},
	"set_beast": {"class": "hunter", "tree": 1, "name": "Вожака Стаи", "armor": "mail", "affixes": ["agi", "sta"],
		"look": Color(1.0, 0.7, 0.4),
		"bonuses": {
			2: {"stats": {"agi": 10, "sta": 10}, "flags": [["pet_hp", 0.15]], "desc": "+10 к ловкости и выносливости, здоровье питомца +15%."},
			3: {"flags": [["pet_dmg", 0.2]], "mods": [["spell:kill_command", "amount", 0.15]],
				"desc": "Урон питомца +20%, Команда «Взять!» (и варианты ряда) на 15% сильнее."},
			5: {"proc": {"on": "auto", "chance": 0.15, "icd": 4.0, "buff": "cobra_strikes"},
				"desc": "Автоатаки с вероятностью 15% дают Удары кобры: Команда «Взять!» сразу готова, бесплатна и на 50% сильнее."}}},
	"set_survival": {"class": "hunter", "tree": 2, "name": "Ловчего Пустошей", "armor": "mail", "affixes": ["agi", "crit"],
		"look": Color(0.6, 0.85, 0.95),
		"bonuses": {
			2: {"stats": {"agi": 12, "sta": 6}, "desc": "+12 к ловкости, +6 к выносливости."},
			3: {"flags": [["trap_power", 0.25]], "mods": [["spell:explosive_shot", "amount", 0.15]],
				"desc": "Урон и длительность эффектов ловушек +25%, Разрывной выстрел на 15% сильнее."},
			5: {"proc": {"on": "spell_hit", "spells": ["explosive_trap", "immolation_trap", "explosive_shot", "serpent_sting", "chimera_shot", "black_arrow", "multi_shot", "volley"], "chance": 0.15, "icd": 4.0, "buff": "lock_and_load"},
				"desc": "Ловушки, яды и выстрелы по площади с вероятностью 15% дают Наготове: следующий выстрел по готовности или добивающий — мгновенно, бесплатно и на 25% сильнее."}}},
	# ---------------- Шаман (сессия 11)
	"set_elemental": {"class": "shaman", "tree": 0, "name": "Повелителя Бури", "armor": "mail_shaman", "affixes": ["int", "crit"],
		"look": Color(0.55, 0.75, 1.15),
		"bonuses": {
			2: {"stats": {"int": 12, "sp": 10}, "desc": "+12 к интеллекту, +10 к силе заклинаний."},
			3: {"mods": [["spell:lightning_bolt", "amount", 0.15], ["spell:chain_lightning", "amount", 0.15], ["spell:lava_burst", "amount", 0.15]],
				"desc": "Молния, заклинание ряда «Ротация» и заклинание ряда «Площадь» (любой вариант) на 15% сильнее."},
			5: {"proc": {"on": "spell_hit", "spells": ["lightning_bolt", "chain_lightning"], "every": 4, "icd": 1.0, "spell": "lava_eruption"},
				"desc": "Каждая 4-я Молния или Цепная молния вызывает Извержение лавы под целью: 46–56 урона огнём в 6 м и горение."}}},
	"set_enhancement": {"class": "shaman", "tree": 1, "name": "Духа Волка", "armor": "mail_shaman_melee", "affixes": ["str", "crit"],
		"look": Color(0.75, 0.95, 1.1),
		"bonuses": {
			2: {"stats": {"str": 12, "crit": 0.02}, "desc": "+12 к силе, +2% к шансу крит. удара."},
			3: {"mods": [["spell:stormstrike", "amount", 0.15], ["global", "auto", 0.1]],
				"desc": "Удар бури (и варианты ряда «Ротация») на 15% сильнее, урон автоатакой +10%."},
			5: {"proc": {"on": "auto", "chance": 0.15, "icd": 3.0, "buff": "maelstrom_weapon"},
				"desc": "Автоатаки с вероятностью 15% дают Оружие водоворота: следующая Молния, Цепная молния, Выброс лавы, Волна или Цепное исцеление — мгновенно, бесплатно и на 20% сильнее."}}},
	"set_restoration": {"class": "shaman", "tree": 2, "name": "Хранителя Приливов", "armor": "mail_shaman", "affixes": ["int", "spi"],
		"look": Color(0.5, 1.05, 0.9),
		"bonuses": {
			2: {"stats": {"int": 10, "spi": 10}, "desc": "+10 к интеллекту и духу."},
			3: {"mods": [["spell:healing_wave", "amount", 0.15], ["spell:riptide", "amount", 0.15], ["spell:chain_heal", "amount", 0.15]],
				"desc": "Волна исцеления, заклинание ряда «Ротация» и заклинание ряда «Площадь» (любой вариант) на 15% сильнее."},
			5: {"proc": {"on": "heal", "every": 4, "icd": 1.0, "spell": "tidal_surge"},
				"desc": "Каждое 4-е лечение вызывает Всплеск прилива: 36–42 лечения союзникам в 8 м от цели."}}},
}

## Именные легендарки: свой шаблон (оружие, левая рука или аксессуар), класс (пусто — любой), название и
## эффект, меняющий игру. effect — то же, что бонус сета (proc / flags / mods), desc — описание с числами.
## Флаги легендарок: extra:<заклинание> — снаряд летит ещё в N врагов рядом; overheal_shield — избыточное
## лечение становится щитом (доля); execute_chain — Казнь при убийстве перескакивает на соседа;
## judgement_ground — Правосудие оставляет освящённую землю.
const LEGENDARIES := {
	"leg_ash_staff": {"name": "Посох Пепельного Шторма", "base": "staff", "class": "mage", "icon": "staff",
		"effect": {"flags": [["extra:fireball", 1.0]]},
		"desc": "Огненный шар раздваивается: второй летит в соседнего врага в 10 м от цели."},
	"leg_rime_orb": {"name": "Око Стужи", "base": "orb", "class": "mage", "icon": "orb",
		"effect": {"flags": [["extra:frostbolt", 1.0]], "mods": [["spell:frostbolt", "amount", 0.1]]},
		"desc": "Ледяная стрела летит ещё в одного врага рядом с целью и на 10% сильнее."},
	"leg_dawn_hammer": {"name": "Молот Рассвета", "base": "mace", "class": "paladin", "icon": "mace",
		"effect": {"flags": [["judgement_ground", 1.0]]},
		"desc": "Правосудие оставляет под целью освящённую землю, как Освящение."},
	"leg_dawn_bulwark": {"name": "Бастион Зари", "base": "shield", "class": "paladin", "icon": "shield",
		"effect": {"proc": {"on": "hit_taken", "chance": 0.15, "icd": 8.0, "absorb_pct": 0.1, "dur": 6.0}, "stats": {"block": 0.06}},
		"desc": "Шанс блока +6%. Получая удар, с вероятностью 15% паладин получает щит на 10% здоровья на 6 сек."},
	"leg_dawn_greatsword": {"name": "Вершитель Света", "base": "greatsword", "class": "paladin", "icon": "greatsword_legend", "model": "sword_E",
		"effect": {"proc": {"on": ["auto", "spell_hit"], "chance": 0.15, "icd": 2.0, "reset": "divine_storm"}, "stats": {"crit": 0.02}},
		"desc": "Двуручный. Шанс крита +2%. Удары оружием и заклинаниями с вероятностью 15% сразу восстанавливают Божественную бурю (вершина ветки Воздаяния)."},
	"leg_storm_reaper": {"name": "Буревой Жнец", "base": "greatsword", "class": "warrior", "icon": "greatsword_legend", "model": "sword_E",
		"effect": {"proc": {"on": ["auto_crit", "spell_hit"], "school": "physical", "crit": true, "chance": 0.2, "icd": 4.0, "reset": "bladestorm"},
			"mods": [["global", "crit", 0.03]]},
		"desc": "Двуручный. Шанс крита +3%. Критические удары оружием с вероятностью 20% сразу восстанавливают заклинание ряда «Мастерство» — Вихрь клинков (если выбран в книге)."},
	"leg_light_wand": {"name": "Жезл Вечного Света", "base": "wand", "class": "priest", "icon": "wand",
		"effect": {"flags": [["overheal_shield", 0.5]]},
		"desc": "Половина избыточного лечения превращается в щит на цели на 10 сек."},
	"leg_naaru_tome": {"name": "Писание Наару", "base": "tome", "class": "priest", "icon": "tome",
		"effect": {"proc": {"on": "heal", "every": 4, "icd": 1.0, "spell": "holy_star"}},
		"desc": "Каждое 4-е лечение призывает Звезду Света: урон врагам и лечение союзникам в 6 м."},
	"leg_rift_axe": {"name": "Секира Раскола", "base": "axe", "class": "warrior", "icon": "axe",
		"effect": {"flags": [["execute_chain", 1.0]]},
		"desc": "Казнь, убившая врага, тут же обрушивается на соседа в 6 м (если у него меньше 25% здоровья — с полной силой, иначе вполсилы)."},
	"leg_ancestor_wall": {"name": "Стена Предков", "base": "shield", "class": "warrior", "icon": "shield",
		"effect": {"mods": [["spell:shield_wall", "cd_add", -45.0], ["global", "dmg_taken", -0.05]], "stats": {"block": 0.05}},
		"desc": "Шанс блока +5%, получаемый урон −5%, перезарядка заклинания ряда «Личная защита» −45 сек."},
	# разбойник (после сессии 13)
	"leg_night_fang": {"name": "Клык Ночи", "base": "dagger", "class": "rogue", "icon": "dagger",
		"effect": {"stats": {"agi": 10}, "proc": {"on": ["auto", "spell_hit"], "school": "physical", "chance": 0.15, "icd": 2.0, "combo": 1}},
		"desc": "Ловкость +10. Удары оружием с вероятностью 15% дают 1 приём серии."},
	"leg_thousand_cuts": {"name": "Клинок Тысячи Порезов", "base": "sword", "class": "rogue", "icon": "sword",
		"effect": {"mods": [["global", "crit", 0.03]], "proc": {"on": "auto_crit", "crit": true, "chance": 0.5, "icd": 5.0, "reset": "row:0"}},
		"desc": "Шанс крита +3%. Критическая автоатака с вероятностью 50% сразу восстанавливает заклинание ряда «Ротация»."},
	"leg_wind_bow": {"name": "Лук Северного Ветра", "base": "bow", "class": "hunter", "icon": "bow",
		"effect": {"flags": [["extra:steady_shot", 2.0]]},
		"desc": "Верный выстрел пробивает цель и летит ещё в 2 врагов рядом."},
	"leg_demon_crossbow": {"name": "Арбалет Охотника на Демонов", "base": "crossbow", "class": "hunter", "icon": "crossbow",
		"effect": {"mods": [["global", "crit", 0.04]], "proc": {"on": "auto_crit", "crit": true, "chance": 0.5, "icd": 6.0, "spell": "flame_burst"}},
		"desc": "Шанс крита +4%. Критическая автоатака с вероятностью 50% взрывается пламенем вокруг цели."},
	# шаман (сессия 11). Флаги: totem_power — сила тотемов (доля), totem_dur — их время (доля).
	"leg_thunder_staff": {"name": "Посох Повелителя Молний", "base": "storm_staff", "class": "shaman", "icon": "storm_staff",
		"effect": {"flags": [["extra:lightning_bolt", 2.0]], "mods": [["spell:chain_lightning", "chain_add", 2.0]]},
		"desc": "Молния бьёт ещё 2 врагов рядом с целью, Цепная молния перескакивает ещё на 2 врага."},
	"leg_storm_hammer": {"name": "Молот Бури Предков", "base": "totem_hammer", "class": "shaman", "icon": "totem_hammer",
		"effect": {"proc": {"on": "auto", "chance": 0.15, "icd": 3.0, "reset": "stormstrike"}, "stats": {"crit": 0.02}},
		"desc": "Шанс крита +2%. Автоатаки с вероятностью 15% сразу восстанавливают Удар бури (ряд «Ротация»)."},
	"leg_tide_shield": {"name": "Щит Бездонного Прилива", "base": "totem_shield", "class": "shaman", "icon": "totem_shield",
		"effect": {"flags": [["totem_power", 0.25], ["totem_dur", 1.0]]},
		"desc": "Тотемы действуют на 25% сильнее и стоят вдвое дольше."},
	# общие: аксессуары
	"leg_phoenix": {"name": "Сердце Феникса", "base": "tr_flask", "class": "", "icon": "tr_flask",
		"effect": {"proc": {"on": "hit_taken", "below": 0.25, "chance": 1.0, "icd": 120.0, "heal_pct": 0.5}},
		"desc": "Когда здоровье падает ниже 25%, герой мгновенно восстанавливает 50% здоровья. Не чаще раза в 2 минуты."},
	"leg_storm_stone": {"name": "Камень Тысячи Гроз", "base": "tr_thunder", "class": "", "icon": "tr_thunder",
		"effect": {"proc": {"on": ["auto", "spell_hit"], "every": 3, "icd": 1.0, "spell": "chain_spark"}},
		"desc": "Каждый 3-й удар или попадание заклинанием бьёт молнией врагов вокруг цели."},
}
