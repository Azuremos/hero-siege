extends RefCounted
## Боссы фракций: фазы, способности фаз, действия при входе в фазу, подача и добыча.
## Сам босс — обычный моб из mob_data.gd (boss: true), способности — из mob_abilities.gd.
## Движок фаз — mob_manager.gd (раздел «боссы»); босс не зависит от осады (--bossarena=<id>).
##
## Поля босса:
##   rank — main (главный, каждая 10-я и финальная волна) | lieutenant (каждая 5-я)
##   intro — реплика при появлении; mechanics — строки подсказки на полосе босса (для игроков)
##   phases — список фаз по убыванию порога: {hp — порог доли здоровья, abilities — способности фазы,
##     say — реплика при входе, invuln — неуязвимость на переход (сек.), summon — [{type, count, ring}],
##     buff — {key, mods} на всю фазу, invuln_while — неуязвим, пока живы его призванные этого типа,
##     tele — множитель времени телеграфов (в последней фазе короче), hazard_ring — горящее кольцо арены {r, count, size},
##     pulse — периодический удар по всем героям {every, radius, effects, school, name},
##     aura — горящая земля вокруг босса {r, dps}, rotate — чередование наборов способностей {period, sets, say}}
##   on_death — {transform: тип, delay, say} — вместо смерти превращается (механоогр → король огров)
##   enrage — мягкий таймер ярости (сек.), только при 2+ игроках
##   loot — уникальные вещи (item_data.UNIQUES); главный — эпическое качество, лейтенант — редкое
##
## Механики «на группу» (min_players в способности) включаются только при 2+ героях.
## Способности с hard: true без рывка не пройти — у одного босса не чаще раза в HARD_GAP сек.

const HARD_GAP := 25.0
const BOSS_COLOR := Color(1.0, 0.45, 0.25)

const BOSSES := {
	# ======================= НЕЖИТЬ =======================
	"boss_lich": {"rank": "main", "intro": "Лич-некромант: «Ваши кости послужат мне лучше, чем служили вам!»",
		"mechanics": ["Ледяные стрелы замедляют.", "Поднять мёртвых — СБИВАЙТЕ, иначе встанут скелеты.",
			"60%: Ледяная гробница — разбейте её, чтобы освободить союзника. Кольцо холода — встаньте вплотную к личу или отойдите далеко.",
			"25%: лич неуязвим, пока стоят 3 филактерии. Разбейте их; уходите от теневых волн."],
		"phases": [
			{"hp": 1.0, "abilities": ["lich_raise"]},
			{"hp": 0.6, "say": "Лич-некромант: «Холод могилы — вот ваша награда!»", "invuln": 2.0,
				"abilities": ["lich_raise", "lich_tomb", "lich_cold_ring"]},
			{"hp": 0.25, "say": "Лич-некромант: «Моя душа не здесь, глупцы. Вам меня не убить!»", "invuln": 2.0, "tele": 0.8,
				"summon": [{"type": "phylactery", "count": 3, "ring": 11.0}], "invuln_while": "phylactery",
				"abilities": ["lich_shadow_waves", "lich_raise", "lich_cold_ring"]},
		],
		"enrage": 420.0, "loot": ["u_lich_staff", "u_lich_hood"]},
	"boss_warlord": {"rank": "lieutenant", "intro": "Костяной полководец: «Строй! Щиты вперёд!»",
		"mechanics": ["Рывок по линии — отойдите в сторону от полосы.", "Вихрь клинков — отбегите из круга.",
			"Призыв щитоносцев — СБИВАЙТЕ, иначе придут скелеты-воины."],
		"phases": [
			{"hp": 1.0, "abilities": ["warlord_charge", "warlord_whirl", "warlord_shields"]},
			{"hp": 0.35, "say": "Костяной полководец: «Ни шагу назад!»", "tele": 0.85,
				"buff": {"key": "enraged", "mods": {"dmg": 0.3, "haste": 0.2}},
				"abilities": ["warlord_charge", "warlord_whirl", "warlord_shields"]},
		],
		"loot": ["u_warlord_axe"]},

	# ======================= ОРКИ =======================
	"boss_warchief": {"rank": "main", "intro": "Вождь орды: «Лок'тар огар! Кровь и гром!»",
		"mechanics": ["Тяжёлый удар — конус перед вождём.", "Боевой рёв — отбегите из круга, иначе страх.",
			"Зов орды — СБИВАЙТЕ, иначе прибегут рубаки.",
			"60%: Жажда крови на орков рядом; веер топоров — встаньте между линиями.",
			"30%: бешенство. Землетрясение — волны идут от вождя, ПЕРЕПРЫГИВАЙТЕ их (Пробел)."],
		"phases": [
			{"hp": 1.0, "abilities": ["chief_smash", "chief_roar", "chief_call"]},
			{"hp": 0.6, "say": "Вождь орды: «Кровь! Больше крови!»", "invuln": 1.5,
				"summon": [{"type": "grunt", "count": 3, "ring": 6.0}],
				"abilities": ["chief_bloodlust", "chief_axes", "chief_smash", "chief_call"]},
			{"hp": 0.3, "say": "Вождь орды: «Я раздавлю вас, как букашек!»", "invuln": 1.5, "tele": 0.8,
				"buff": {"key": "enraged", "mods": {"dmg": 0.35, "haste": 0.25}},
				"abilities": ["chief_quake", "chief_axes", "chief_smash", "chief_call"]},
		],
		"enrage": 420.0, "loot": ["u_chief_axe", "u_chief_mail"]},
	"boss_wolf_leader": {"rank": "lieutenant", "intro": "Вожак волчьей стаи: «Стая! Взять их!»",
		"mechanics": ["С вожаком стая волков. По его команде волки бросаются на самого раненого героя — лечите и прикрывайте его.",
			"Вой стаи — СБИВАЙТЕ, иначе придут новые волки.", "Прыжок — отойдите из круга."],
		"phases": [
			{"hp": 1.0, "summon": [{"type": "pack_wolf", "count": 3, "ring": 3.0}],
				"abilities": ["pack_hunt", "pack_howl", "pack_leap"]},
		],
		"loot": ["u_wolf_boots"]},

	# ======================= ДЕМОНЫ =======================
	"boss_fel_lord": {"rank": "main", "intro": "Владыка Скверны: «Этот мир сгорит, как сгорели другие!»",
		"mechanics": ["Огненный дождь — уходите из кругов.", "Врата легиона — СБИВАЙТЕ; открытый портал выпускает бесов, закрывается уроном.",
			"60%: Метка Скверны (в группе) — через 5 сек. взрыв по союзникам рядом: отойдите от них.",
			"30%: Буря Скверны выжигает ману всем. Выжигание души — СБИВАЙТЕ любой ценой."],
		"phases": [
			{"hp": 1.0, "abilities": ["fel_rain", "fel_gate", "fel_cleave"]},
			{"hp": 0.6, "say": "Владыка Скверны: «Легион, ко мне!»", "invuln": 1.5,
				"summon": [{"type": "fel_portal", "count": 2, "ring": 12.0}],
				"abilities": ["fel_rain", "fel_mark", "fel_gate", "fel_cleave"]},
			{"hp": 0.3, "say": "Владыка Скверны: «Ваша магия — моя пища!»", "invuln": 2.0, "tele": 0.8,
				"hazard_ring": {"r": 19.0, "count": 12, "size": 3.0},
				"pulse": {"every": 4.0, "radius": 60.0, "name": "Буря Скверны", "school": "shadow",
					"effects": [{"type": "mana_burn_pct", "pct": 0.04}, {"type": "damage", "min": 6.0, "max": 9.0}]},
				"abilities": ["fel_soulburn", "fel_rain", "fel_mark", "fel_cleave"]},
		],
		"enrage": 420.0, "loot": ["u_fel_wand", "u_fel_robe"]},
	"boss_infernal": {"rank": "lieutenant", "intro": "Инфернал-исполин падает с неба. Земля вокруг раскалена!",
		"mechanics": ["Земля вокруг исполина раскалена — бойцам ближнего боя больно.", "Падение с неба — уходите из круга; там останется огонь.",
			"Огненный вал — СБИВАЙТЕ или убегайте далеко."],
		"phases": [
			{"hp": 1.0, "aura": {"r": 4.5, "dps": 9.0}, "abilities": ["giant_drop", "giant_nova"]},
			{"hp": 0.4, "say": "Инфернал-исполин ревёт, пламя разгорается!", "tele": 0.85, "aura": {"r": 6.0, "dps": 12.0},
				"abilities": ["giant_drop", "giant_nova"]},
		],
		"loot": ["u_infernal_plate"]},

	# ======================= ГОБЛИНЫ И ОГРЫ =======================
	"boss_mecha": {"rank": "main", "intro": "Гоблин-пилот: «Механоогр, к бою! Платите за ремонт, неудачники!»",
		"mechanics": ["Мины по полю — не наступайте, взрываются.", "Ракетный залп — уходите из кругов.",
			"Ремонт — СБИВАЙТЕ, иначе машина подлатается.", "Машина взрывается — и на поле выходит король огров!"],
		"phases": [
			{"hp": 1.0, "abilities": ["mecha_mines", "mecha_rockets", "mecha_repair"]},
			{"hp": 0.5, "say": "Гоблин-пилот: «Перегрев! Жми все кнопки!»", "tele": 0.85,
				"abilities": ["mecha_mines", "mecha_rockets", "mecha_flame", "mecha_repair"]},
		],
		"on_death": {"transform": "boss_ogre_king", "delay": 2.5, "radius": 7.0,
			"say": "Король огров: «Глупые гоблины! Всё самому делать!»"},
		"loot": []},
	"boss_ogre_king": {"rank": "main", "intro": "",
		"mechanics": ["Сокрушение — конус перед королём.", "Сотрясение — волны от короля, ПЕРЕПРЫГИВАЙТЕ их.",
			"Сокрушительный удар (в группе) — встаньте в круг вместе, урон делится.", "Пир — СБИВАЙТЕ, иначе король лечится."],
		"phases": [
			{"hp": 1.0, "abilities": ["king_smash", "king_share", "king_feast", "king_quake"]},
			{"hp": 0.35, "say": "Король огров: «Сейчас я разозлюсь!»", "invuln": 1.5, "tele": 0.8,
				"summon": [{"type": "ogre", "count": 1, "ring": 5.0}],
				"buff": {"key": "enraged", "mods": {"dmg": 0.3, "haste": 0.2}},
				"abilities": ["king_smash", "king_share", "king_feast", "king_quake"]},
		],
		"enrage": 360.0, "loot": ["u_king_mace", "u_king_ring"]},
	"boss_two_headed": {"rank": "lieutenant", "intro": "Двухголовый огр: «Я буду бить!» — «Нет, я буду!»",
		"mechanics": ["Головы командуют по очереди.", "Левая голова: сокрушение (конус) и таран по линии.",
			"Правая голова: огненный шар (круг) и Пламя огров — СБИВАЙТЕ."],
		"phases": [
			{"hp": 1.0, "rotate": {"period": 12.0, "sets": [["ogre2_smash", "ogre2_charge"], ["ogre2_fireball", "ogre2_flames"]],
				"say": ["Левая голова: «Моя очередь бить!»", "Правая голова: «Нет, теперь я колдую!»"]}},
			{"hp": 0.35, "say": "Двухголовый огр: «Обе головы злые!»", "tele": 0.85,
				"buff": {"key": "enraged", "mods": {"dmg": 0.25, "haste": 0.2}},
				"rotate": {"period": 9.0, "sets": [["ogre2_smash", "ogre2_charge", "ogre2_fireball"], ["ogre2_fireball", "ogre2_flames", "ogre2_smash"]],
					"say": ["Левая голова: «Бей!»", "Правая голова: «Жги!»"]}},
		],
		"loot": ["u_ogre2_staff"]},
}

## Кто выходит на босс-волнах: лейтенанты и главные по фракциям (по очереди сторон).
const BY_FACTION := {
	"undead": {"lieutenant": "boss_warlord", "main": "boss_lich"},
	"orcs": {"lieutenant": "boss_wolf_leader", "main": "boss_warchief"},
	"demons": {"lieutenant": "boss_infernal", "main": "boss_fel_lord"},
	"goblins": {"lieutenant": "boss_two_headed", "main": "boss_mecha"},
}
