extends Node3D
## Снимок героев в снаряжении (флаг --heroshot=<out.png>): ряд моделей «классы × расы» на сером фоне.
## Запускается из главного меню вместо него. Дополнительно: --classes=mage,warrior|all --races=all
## --outfit=<уровень>:<качество>:<вариант>|none (как в бою) --yaw=<поворот°> --zoom=<крупность> --anim=<анимация>. --leg=<id> — именная легендарка в руке.

func _ready() -> void:
	var cli: Dictionary = Net.cli
	var out: String = cli["heroshot"]
	var classes: Array = GameData.CLASSES.keys() if cli.get("classes", "all") == "all" else Array(str(cli["classes"]).split(","))
	var races: Array = GameData.RACES.keys() if cli.get("races", "all") == "all" else Array(str(cli["races"]).split(","))
	var outfit: String = cli.get("outfit", "25:4:0")
	var yaw: float = float(cli.get("yaw", 20.0))
	var zoom: float = float(cli.get("zoom", 1.0))
	var op := (outfit + "::").split(":")
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.22, 0.24, 0.28)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.65)
	e.ambient_light_energy = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 30, 0)
	sun.light_energy = 1.3
	add_child(sun)
	var n := 0
	var cols := classes.size() * races.size()
	if cli.has("mobs"):
		# --mobs=id,id: вместо героев — враги (проверить оружие в руках)
		classes = []
		var ids: Array = Array(str(cli["mobs"]).split(","))
		cols = ids.size()
		for mid: String in ids:
			var mm := ModelFactory.build_mob(mid)
			add_child(mm)
			mm.position = Vector3((n - (cols - 1) * 0.5) * 2.4, 0, 0)
			mm.rotation_degrees.y = yaw
			var map := ModelFactory.find_anim(mm)
			if map:
				var an: String = cli.get("anim", "idle")
				var mdef: Dictionary = GameData.MOBS[mid]
				var monster: bool = mdef.get("src", "enemy") == "monster"
				if an == "attack":       # --anim=attack — своя анимация удара каждого моба
					var kk: String = mdef.get("attack_anim", "1H_Melee_Attack_Chop")
					an = ModelFactory.monster_anim(mid, kk) if monster else kk
				elif an == "idle":
					an = ModelFactory.monster_anim(mid, "Idle") if monster else "Idle"
				map.play(an)
				if cli.has("animt"):       # --animt= — кадр анимации (сек.), например середина удара
					map.seek(float(cli["animt"]), true)
					map.pause()
			n += 1
	var hi: int = int(op[2]) if op[2].is_valid_int() else 0
	for cid: String in classes:
		for rid: String in races:
			var m := ModelFactory.build_hero(cid, rid)
			add_child(m)
			m.position = Vector3((n - (cols - 1) * 0.5) * 2.2, 0, 0)
			m.rotation_degrees.y = 180.0 + yaw
			var ap := ModelFactory.find_anim(m)
			if ap:
				ap.play(cli.get("anim", "Idle"))
			if outfit != "none":
				var looks := {}
				for b: String in outfit_bases(cid, hi + n):
					var id: String = GameData.make_gear(b, int(op[0]), int(op[1]), 1000 + n)
					var slot: String = GameData.item(id)["slot"]
					if slot == "weapon" and looks.has("weapon"):
						continue
					looks[slot] = GameData.ItemData.look(id)
				# --leg=<id>: в руке именная легендарка своего класса
				var lid := str(cli.get("leg", ""))
				if GameData.SetData.LEGENDARIES.has(lid) and GameData.SetData.LEGENDARIES[lid]["class"] == cid:
					looks["weapon"] = GameData.ItemData.look(GameData.make_legendary(lid, int(op[0]), 7))
				if looks.get("weapon", {}).get("two_hand", false):
					looks.erase("offhand")
				ModelFactory.apply_outfit(m, cid, looks)
				if cli.has("debug"):
					await get_tree().process_frame
					var pd := m.find_child("OutfitPad_r", true, false) as Node3D
					if pd:
						print(cid, " pad ", pd.global_transform, " ", pd.get_child(0).get_children())
			n += 1
	var cam := Camera3D.new()
	add_child(cam)
	var dist := maxf(4.5, cols * 2.2 * 0.95) / zoom
	var cy := float(cli.get("camy", 1.1))      # --camy= — высота, куда смотрит камера
	cam.look_at_from_position(Vector3(0, cy + 0.5 + dist * 0.08, dist), Vector3(0, cy, 0))
	cam.fov = 40.0
	cam.make_current()
	for i in 30:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("saved ", out)
	get_tree().quit()

## Набор вещей для класса (тот же, что надевает --outfit=): оружие, головной убор, доспех, наплечники, сапоги, левая рука.
## hi — вариант: сдвигает выбор по спискам.
static func outfit_bases(cid: String, hi: int) -> Array:
	var weapons: Array = []
	var offs: Array = []
	for b in GameData.ItemData.TEMPLATES:
		var tb: Dictionary = GameData.ItemData.TEMPLATES[b]
		if tb.get("classes", []).has(cid):
			(offs if tb["slot"] == "offhand" else weapons).append(b)
	var phys: bool = cid in ["warrior", "paladin"]
	var helms: Array = ["helm", "warhelm"] if phys else ["hat", "hood"]
	var chests: Array = ["plate", "mail"] if phys else ["robe"]
	var pads: Array = ["pads_plate", "pads_mail"] if phys else ["pads_cloth"]
	if cid == "hunter":       # охотник — кольчуга и капюшон
		helms = ["hood", "warhelm"]
		chests = ["mail"]
		pads = ["pads_mail"]
	var out: Array = [weapons[hi % weapons.size()], helms[hi % 2], chests[hi % chests.size()], pads[hi % pads.size()], "boots"]
	if not offs.is_empty():
		out.append(offs[hi % offs.size()])
	return out
