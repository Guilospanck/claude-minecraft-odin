package main

import "core:math"

// Unexpected world events — the "chaos" a static world lacks. Rolled once a frame
// (probability scaled by dt) and gated by weather and time of day so each fits
// the moment: lightning strikes during thunderstorms, shooting stars on clear
// nights, and wind gusts any time you're out in the open.

EVENT_LIGHTNING_CHANCE :: f32(0.30) // per second, only during a thunderstorm
EVENT_STAR_CHANCE :: f32(0.12) // per second, only on a clear night
EVENT_GUST_CHANCE :: f32(0.05) // per second, any time

events_update :: proc(w: ^World, p: ^Player, dt: f32) {
	if net_is_client() do return
	if w.dimension != .Overworld do return

	if w.active_precip == .Thunder && rng_f32() < dt * EVENT_LIGHTNING_CHANCE {
		lightning_strike(w, p)
	}
	night := w.time_of_day < 0.22 || w.time_of_day > 0.80
	if night && !w.raining && rng_f32() < dt * EVENT_STAR_CHANCE {
		shooting_star(w, p)
	}
	if rng_f32() < dt * EVENT_GUST_CHANCE {
		wind_gust(w, p)
	}
}

@(private = "file")
top_solid_y :: proc(w: ^World, x, z: int) -> int {
	for y := 122; y > 1; y -= 1 {
		if block_is_solid(world_block(w, x, y, z)) do return y
	}
	return SEA_LEVEL
}

// A bolt lands near the player: a jagged bright column of particles from the
// ground to the clouds, a screen flash, a thunderclap, a scorched strike point,
// and every nearby animal bolting in fright.
@(private = "file")
lightning_strike :: proc(w: ^World, p: ^Player) {
	ang := rng_range(0, 6.2831853)
	r := rng_range(8, 24)
	lightning_at(w, p, p.pos.x + math.cos(ang) * r, p.pos.z + math.sin(ang) * r)
}

@(private = "file")
lightning_at :: proc(w: ^World, p: ^Player, sx, sz: f32) {
	ix, iz := int(math.floor(sx)), int(math.floor(sz))
	gy := top_solid_y(w, ix, iz)

	jx, jz := sx, sz
	for k in 0 ..< 80 {
		yy := f32(gy) + f32(k) * 0.62
		jx += rng_range(-0.22, 0.22);jz += rng_range(-0.22, 0.22)
		append(
			&w.particles,
			Particle {
				pos = Vec3{jx, yy, jz},
				vel = Vec3{rng_range(-0.3, 0.3), rng_range(-0.3, 0.3), rng_range(-0.3, 0.3)},
				max_life = rng_range(0.3, 0.55),
				color = Vec3{0.90, 0.95, 1.0},
				size = rng_range(0.16, 0.30),
				float = true,
			},
		)
	}
	w.flash = 1.0
	audio_play(.Thunder, 0.9)
	if world_block(w, ix, gy, iz) == .Grass do world_set_block(w, ix, gy, iz, .CoarseDirt) // scorch

	for &m in w.mobs {
		dx := m.pos.x - sx;dz := m.pos.z - sz
		if dx * dx + dz * dz < 26 * 26 && !mob_is_hostile(m.kind) {
			m.flee_timer = max(m.flee_timer, 2.5)
			m.yaw = math.atan2(m.pos.x - p.pos.x, -(m.pos.z - p.pos.z))
			m.moving = true
		}
	}
}

// A streak of bright motes arcing across the night sky and burning out.
@(private = "file")
shooting_star :: proc(w: ^World, p: ^Player) {
	start := p.pos + Vec3{rng_range(-40, 40), rng_range(55, 85), rng_range(-40, 40)}
	dir := Vec3{rng_range(-1, 1), rng_range(-0.5, -0.2), rng_range(-1, 1)}
	L := math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z) + 1e-4
	dir = dir / L
	speed := rng_range(22, 34)
	for k in 0 ..< 14 {
		fade := 1.0 - f32(k) / 16.0
		append(
			&w.particles,
			Particle {
				pos = start + dir * f32(k) * 0.7,
				vel = dir * speed,
				max_life = rng_range(0.5, 0.9),
				color = Vec3{1.0, 0.95, 0.8 * fade + 0.2},
				size = rng_range(0.08, 0.16) * (0.5 + fade),
				float = true,
			},
		)
	}
}

// A sudden gust: shove the wind vector and sweep a scatter of dust/leaf motes
// past the player so the air visibly moves.
@(private = "file")
wind_gust :: proc(w: ^World, p: ^Player) {
	dirx := rng_range(-1, 1)
	dirz := rng_range(-1, 1)
	w.wind_x = clamp(w.wind_x + dirx * 2.0, -6, 6)
	w.wind_z = clamp(w.wind_z + dirz * 2.0, -6, 6)
	base := p.pos + Vec3{rng_range(-6, 6), rng_range(0, 4), rng_range(-6, 6)}
	for _ in 0 ..< 12 {
		append(
			&w.particles,
			Particle {
				pos = base + Vec3{rng_range(-3, 3), rng_range(-1, 3), rng_range(-3, 3)},
				vel = Vec3{dirx * rng_range(3, 6), rng_range(-0.3, 0.6), dirz * rng_range(3, 6)},
				max_life = rng_range(0.5, 1.0),
				color = Vec3{0.82, 0.80, 0.68},
				size = rng_range(0.03, 0.06),
				float = true,
			},
		)
	}
}
