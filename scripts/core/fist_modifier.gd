class_name FistModifier
extends SkeletonModifier3D
## Сжатый кулак: после анимации сгибает пальцы руки, в которой оружие (модели Quaternius держат ладонь раскрытой).
## bones — кости пальцев, curl — угол сгиба каждого сустава вокруг оси axis (в пространстве кости).

var bones: PackedInt32Array = PackedInt32Array()
var curl := deg_to_rad(-75.0)
var axis := Vector3.RIGHT

## side "R" или "L": все фаланги (Index/Middle/Ring/Pinky 1–3, Thumb 1–2) этой руки.
func setup(skel: Skeleton3D, side: String) -> void:
	for f in ["Index", "Middle", "Ring", "Pinky", "Thumb"]:
		for i in [1, 2, 3]:
			var b := skel.find_bone("%s%d.%s" % [f, i, side])
			if b >= 0:
				bones.append(b)

func _process_modification() -> void:
	var skel := get_skeleton()
	if skel == null:
		return
	var q := Quaternion(axis, curl)
	for b in bones:
		skel.set_bone_pose_rotation(b, skel.get_bone_pose_rotation(b) * q)
