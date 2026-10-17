#include "mob_sim.h"

#include <godot_cpp/core/class_db.hpp>

#include <cmath>

using namespace godot;

void MobSimNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_obstacles", "a", "b", "r"), &MobSimNative::set_obstacles);
	ClassDB::bind_method(D_METHOD("set_mobs", "pos", "radius", "alive"), &MobSimNative::set_mobs);
	ClassDB::bind_method(D_METHOD("query_radius", "p", "r"), &MobSimNative::query_radius);
	ClassDB::bind_method(D_METHOD("move_batch", "movers", "goals", "speeds", "can_wall", "dt", "wall_a", "wall_b", "wall_ids"), &MobSimNative::move_batch);
	ClassDB::bind_method(D_METHOD("encode_snapshot", "ids", "pos", "yaw", "anim_swing", "hp_frac"), &MobSimNative::encode_snapshot);
}

// Как Geometry2D::get_closest_point_to_segment в Godot.
Vector2 MobSimNative::closest_on_segment(const Vector2 &p, const Vector2 &a, const Vector2 &b) {
	Vector2 pp = p - a;
	Vector2 n = b - a;
	real_t l2 = n.length_squared();
	if (l2 < 1e-20f) {
		return a;
	}
	real_t d = n.dot(pp) / l2;
	if (d <= 0.0f) {
		return a;
	} else if (d >= 1.0f) {
		return b;
	}
	return a + n * d;
}

void MobSimNative::set_obstacles(const PackedVector2Array &a, const PackedVector2Array &b, const PackedFloat32Array &r) {
	obstacles.clear();
	obs_grid.clear();
	int64_t n = a.size();
	for (int64_t i = 0; i < n; i++) {
		Obstacle ob{ a[i], b[i], (double)r[i] };
		int idx = (int)obstacles.size();
		obstacles.push_back(ob);
		// клетки — как в _add_static: габарит отрезка плюс радиус и 2 м запаса
		double lox = std::fmin(ob.a.x, ob.b.x) - (ob.r + 2.0);
		double loy = std::fmin(ob.a.y, ob.b.y) - (ob.r + 2.0);
		double hix = std::fmax(ob.a.x, ob.b.x) + (ob.r + 2.0);
		double hiy = std::fmax(ob.a.y, ob.b.y) + (ob.r + 2.0);
		for (int64_t cx = (int64_t)std::floor(lox / CELL); cx <= (int64_t)std::floor(hix / CELL); cx++) {
			for (int64_t cy = (int64_t)std::floor(loy / CELL); cy <= (int64_t)std::floor(hiy / CELL); cy++) {
				obs_grid[key(cx, cy)].push_back(idx);
			}
		}
	}
}

void MobSimNative::set_mobs(const PackedVector2Array &pos, const PackedFloat32Array &radius, const PackedByteArray &alive) {
	int64_t n = pos.size();
	mob_pos.resize(n);
	mob_r.resize(n);
	mob_alive.resize(n);
	for (auto &kv : grid) {
		kv.second.clear();
	}
	for (auto &kv : sep_grid) {
		kv.second.clear();
	}
	for (int64_t i = 0; i < n; i++) {
		Vector2 p = pos[i];
		mob_pos[i] = p;
		mob_r[i] = (double)radius[i];
		mob_alive[i] = alive[i];
		grid[key((int64_t)std::floor(p.x / CELL), (int64_t)std::floor(p.y / CELL))].push_back((int)i);
		sep_grid[key((int64_t)std::floor(p.x / SEP_CELL), (int64_t)std::floor(p.y / SEP_CELL))].push_back((int)i);
	}
}

PackedInt32Array MobSimNative::query_radius(const Vector2 &p, double r) const {
	PackedInt32Array out;
	int64_t x0 = (int64_t)std::floor((p.x - r) / CELL), x1 = (int64_t)std::floor((p.x + r) / CELL);
	int64_t y0 = (int64_t)std::floor((p.y - r) / CELL), y1 = (int64_t)std::floor((p.y + r) / CELL);
	for (int64_t cx = x0; cx <= x1; cx++) {
		for (int64_t cy = y0; cy <= y1; cy++) {
			auto it = grid.find(key(cx, cy));
			if (it == grid.end()) {
				continue;
			}
			for (int i : it->second) {
				if (mob_alive[i] && mob_pos[i].distance_to(p) <= r + mob_r[i]) {
					out.push_back(i);
				}
			}
		}
	}
	return out;
}

Array MobSimNative::move_batch(const PackedInt32Array &movers, const PackedVector2Array &goals, const PackedFloat32Array &speeds,
		const PackedByteArray &can_wall, double dt, const PackedVector2Array &wall_a, const PackedVector2Array &wall_b,
		const PackedInt32Array &wall_ids) const {
	int64_t n = movers.size();
	PackedVector2Array out_pos;
	PackedFloat32Array out_yaw;
	PackedInt32Array out_wall;
	out_pos.resize(n);
	out_yaw.resize(n);
	out_wall.resize(n);
	int64_t nw = wall_a.size();
	for (int64_t k = 0; k < n; k++) {
		int i = movers[k];
		Vector2 pos = mob_pos[i];
		double r = mob_r[i];
		out_pos.set(k, pos);
		out_yaw.set(k, NAN);
		out_wall.set(k, 0);
		Vector2 to = goals[k] - pos;
		if (to.length() < 0.05f) {
			continue;
		}
		Vector2 dir = to.normalized();
		Vector2 v = dir * (real_t)speeds[k];
		// расталкивание соседей (мелкая сетка 3×3, не больше MAX_NEIGHBORS толчков)
		int64_t kx = (int64_t)std::floor(pos.x / SEP_CELL);
		int64_t ky = (int64_t)std::floor(pos.y / SEP_CELL);
		int pushes = 0;
		for (int64_t cx = kx - 1; cx <= kx + 1 && pushes < MAX_NEIGHBORS; cx++) {
			for (int64_t cy = ky - 1; cy <= ky + 1 && pushes < MAX_NEIGHBORS; cy++) {
				auto it = sep_grid.find(key(cx, cy));
				if (it == sep_grid.end()) {
					continue;
				}
				for (int j : it->second) {
					if (j == i) {
						continue;
					}
					Vector2 diff = pos - mob_pos[j];
					double min_d = r + mob_r[j];
					double d2 = diff.length_squared();
					if (d2 < min_d * min_d && d2 > 0.0001) {
						double d = std::sqrt(d2);
						v += diff / (real_t)d * (real_t)((min_d - d) * 5.0);
						pushes++;
						if (pushes >= MAX_NEIGHBORS) {
							break;
						}
					}
				}
			}
		}
		Vector2 np = pos + v * (real_t)dt;
		// ледяные стены: упёрся — стоит (и начнёт бить стену, если может)
		for (int64_t w = 0; w < nw; w++) {
			Vector2 cp = closest_on_segment(np, wall_a[w], wall_b[w]);
			if (cp.distance_to(np) < r + 0.9) {
				Vector2 was = closest_on_segment(pos, wall_a[w], wall_b[w]);
				if (cp.distance_to(np) < was.distance_to(pos) + 0.01) {
					np = pos;
					if (can_wall[k]) {
						out_wall.set(k, wall_ids[w]);
					}
					break;
				}
			}
		}
		// стены города, здания, деревья — выталкивание из препятствий клетки
		auto ot = obs_grid.find(key((int64_t)std::floor(np.x / CELL), (int64_t)std::floor(np.y / CELL)));
		if (ot != obs_grid.end()) {
			for (int idx : ot->second) {
				const Obstacle &ob = obstacles[idx];
				Vector2 cp = closest_on_segment(np, ob.a, ob.b);
				Vector2 diff = np - cp;
				double min_d = ob.r + r;
				double d = diff.length();
				if (d < min_d) {
					if (d < 0.001) {
						diff = -dir;
						d = 1.0;
					}
					np = cp + diff / (real_t)d * (real_t)min_d;
				}
			}
		}
		out_pos.set(k, np);
		if (v.length_squared() > 0.01f) {
			out_yaw.set(k, (float)std::atan2(-v.x, -v.y));
		}
	}
	Array res;
	res.push_back(out_pos);
	res.push_back(out_yaw);
	res.push_back(out_wall);
	return res;
}

static inline int clampi_(double v, int lo, int hi) {
	int x = (int)v;
	return x < lo ? lo : (x > hi ? hi : x);
}

PackedByteArray MobSimNative::encode_snapshot(const PackedInt32Array &ids, const PackedVector2Array &pos, const PackedFloat32Array &yaw,
		const PackedByteArray &anim_swing, const PackedFloat32Array &hp_frac) const {
	int64_t n = ids.size();
	PackedByteArray buf;
	buf.resize(2 + n * 11);
	uint8_t *w = buf.ptrw();
	w[0] = (uint8_t)(n & 0xFF);
	w[1] = (uint8_t)((n >> 8) & 0xFF);
	const double TAU_ = 6.283185307179586;
	for (int64_t i = 0; i < n; i++) {
		uint8_t *o = w + 2 + i * 11;
		uint32_t id = (uint32_t)ids[i];
		o[0] = id & 0xFF;
		o[1] = (id >> 8) & 0xFF;
		o[2] = (id >> 16) & 0xFF;
		o[3] = (id >> 24) & 0xFF;
		Vector2 p = pos[i];
		int16_t x = (int16_t)clampi_(std::fmax(-32767.0, std::fmin(32767.0, (double)p.x * 100.0)), -32767, 32767);
		int16_t y = (int16_t)clampi_(std::fmax(-32767.0, std::fmin(32767.0, (double)p.y * 100.0)), -32767, 32767);
		o[4] = (uint8_t)(x & 0xFF);
		o[5] = (uint8_t)((x >> 8) & 0xFF);
		o[6] = (uint8_t)(y & 0xFF);
		o[7] = (uint8_t)((y >> 8) & 0xFF);
		double yy = std::fmod((double)yaw[i], TAU_);
		if (yy < 0.0) {
			yy += TAU_;
		}
		o[8] = (uint8_t)(int)(yy / TAU_ * 255.0);
		o[9] = anim_swing[i];
		o[10] = (uint8_t)(int)((double)hp_frac[i] * 255.0);
	}
	return buf;
}
