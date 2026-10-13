extends SceneTree
# Печатает дерево узлов сцены (для отладки импорта моделей).
func _p(n: Node, d: int) -> void:
	var extra := ""
	if n is BoneAttachment3D: extra = " bone=" + (n as BoneAttachment3D).bone_name
	if n is AnimationPlayer: extra = " libs=" + str((n as AnimationPlayer).get_animation_library_list())
	print("  ".repeat(d), n.name, " <", n.get_class(), ">", extra)
	for c in n.get_children(): _p(c, d + 1)
func _init() -> void:
	for f in OS.get_cmdline_user_args():
		var inst := (load(f) as PackedScene).instantiate()
		_p(inst, 0)
		inst.free()
	quit()
