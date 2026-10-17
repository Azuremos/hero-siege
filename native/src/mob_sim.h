// Горячие циклы серверной симуляции мобов Hero Siege (GDExtension).
// Логика — та же, что в GDScript-пути scripts/world/mob_manager.gd (_move_calc, _rebuild_grid, query_radius,
// _encode_snapshot): порядок обхода клеток и соседей совпадает, поэтому оба пути дают одни и те же позиции
// (проверка — tools/mobsim_equiv.gd). Решения мобов (погоня, способности, боссы) остаются в GDScript.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace godot {

class MobSimNative : public RefCounted {
	GDCLASS(MobSimNative, RefCounted)

public:
	static constexpr double CELL = 6.0;       // сетка для запросов по радиусу и препятствий
	static constexpr double SEP_CELL = 2.0;   // мелкая сетка для расталкивания
	static constexpr int MAX_NEIGHBORS = 6;

	// Статические препятствия (стены города, деревья): отрезок a–b радиуса r. Один раз после загрузки карты.
	void set_obstacles(const PackedVector2Array &a, const PackedVector2Array &b, const PackedFloat32Array &r);
	// Мобы на этот шаг (порядок — как в GDScript, mobs.values()): позиции, радиусы, живые.
	void set_mobs(const PackedVector2Array &pos, const PackedFloat32Array &radius, const PackedByteArray &alive);
	// Индексы мобов в круге (живые, расстояние <= r + радиус моба) — тот же порядок, что у GDScript query_radius.
	PackedInt32Array query_radius(const Vector2 &p, double r) const;
	// Движение пачки: movers — индексы мобов, goals — куда идут, speeds — скорость с замедлениями,
	// can_wall — при упоре в ледяную стену моб начнёт её бить. Стены: отрезки и id.
	// Возвращает [новые позиции, yaw (NAN — не менялся), id стены, в которую упёрся (0 — нет)].
	Array move_batch(const PackedInt32Array &movers, const PackedVector2Array &goals, const PackedFloat32Array &speeds,
			const PackedByteArray &can_wall, double dt, const PackedVector2Array &wall_a, const PackedVector2Array &wall_b,
			const PackedInt32Array &wall_ids) const;
	// Снимок для клиентов: 2 байта числа + 11 байт на моба (id u32, x/y s16 ×100, yaw u8, анимация|взмах u8, здоровье u8).
	PackedByteArray encode_snapshot(const PackedInt32Array &ids, const PackedVector2Array &pos, const PackedFloat32Array &yaw,
			const PackedByteArray &anim_swing, const PackedFloat32Array &hp_frac) const;

protected:
	static void _bind_methods();

private:
	struct Obstacle {
		Vector2 a, b;
		double r;
	};
	std::vector<Obstacle> obstacles;
	std::unordered_map<int64_t, std::vector<int>> obs_grid;

	std::vector<Vector2> mob_pos;
	std::vector<double> mob_r;
	std::vector<uint8_t> mob_alive;
	std::unordered_map<int64_t, std::vector<int>> grid;
	std::unordered_map<int64_t, std::vector<int>> sep_grid;

	static int64_t key(int64_t cx, int64_t cy) { return (cx + 1048576) * 2097152 + (cy + 1048576); }
	static Vector2 closest_on_segment(const Vector2 &p, const Vector2 &a, const Vector2 &b);
};

} // namespace godot
