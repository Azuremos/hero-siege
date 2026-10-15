extends RefCounted
## Стволы в модели рощи: меш делится на связные части (по общим вершинам треугольников),
## ствол — часть, что стоит на земле и узкая по горизонтали. Возвращает [Vector3(x, z, радиус)] при масштабе 1.

static func _parts(path: String) -> Array:
	var parts: Array = []
	var inst := (load(path) as PackedScene).instantiate() as Node3D
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		var local := Transform3D.IDENTITY
		var n: Node = mi
		while n != inst:
			local = (n as Node3D).transform * local
			n = n.get_parent()
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		for s in mesh.get_surface_count():
			var arr := mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if idx.is_empty():
				for i in verts.size():
					idx.append(i)
			# одинаковые позиции — одна вершина (у gltf швы по нормалям)
			var key_of := {}
			var parent := PackedInt32Array()
			var vid := PackedInt32Array()
			vid.resize(verts.size())
			for i in verts.size():
				var k := Vector3i((verts[i] * 1000.0).round())
				if not key_of.has(k):
					key_of[k] = parent.size()
					parent.append(parent.size())
				vid[i] = key_of[k]
			for t in range(0, idx.size(), 3):
				var a := _find(parent, vid[idx[t]])
				for j in [1, 2]:
					var b := _find(parent, vid[idx[t + j]])
					if a != b:
						parent[b] = a
			var groups := {}
			for i in verts.size():
				var r := _find(parent, vid[i])
				if not groups.has(r):
					groups[r] = PackedVector3Array()
				groups[r].append(local * verts[i])
			for g in groups.values():
				parts.append(g)
	inst.free()
	return parts

static func _find(parent: PackedInt32Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i

static func _info(g: PackedVector3Array) -> Dictionary:
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := -lo
	for v in g:
		lo = lo.min(v); hi = hi.max(v)
	return {"lo": lo, "hi": hi, "c": Vector2((lo.x + hi.x) * 0.5, (lo.z + hi.z) * 0.5), "r": maxf(hi.x - lo.x, hi.z - lo.z) * 0.5, "n": g.size()}

static func debug(path: String) -> String:
	var s := ""
	for g in _parts(path):
		var f := _info(g)
		s += "\n   n=%d y=[%.2f,%.2f] c=(%.2f,%.2f) r=%.2f" % [f["n"], f["lo"].y, f["hi"].y, f["c"].x, f["c"].y, f["r"]]
	return s

## Деревья модели: части выше 0,3 высоты модели и уже 0,5 — кроны (у рощ ствол и крона одним куском).
## Vector3(x, z, радиус кроны).
static func trees(path: String) -> Array:
	var out: Array = []
	for g in _parts(path):
		var f := _info(g)
		var h: float = f["hi"].y - f["lo"].y
		if h > 0.3 and f["r"] < 0.5:
			out.append(Vector3(f["c"].x, f["c"].y, f["r"]))
	return out
