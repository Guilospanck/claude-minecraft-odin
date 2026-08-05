package main

import "core:math"

// Short-lived cube shards flung out when a block breaks.
Particle :: struct {
	pos, vel:       Vec3,
	life, max_life: f32,
	color:          Vec3,
	size:           f32,
}

particle_spawn_break :: proc(ps: ^[dynamic]Particle, block: BlockId, bx, by, bz: int) {
	base := block_color(block)
	for _ in 0 ..< 10 {
		t := rng_range(0.8, 1.1)
		append(
			ps,
			Particle {
				pos = Vec3{f32(bx) + rng_f32(), f32(by) + rng_f32(), f32(bz) + rng_f32()},
				vel = Vec3{rng_range(-2.2, 2.2), rng_range(1.5, 4.5), rng_range(-2.2, 2.2)},
				max_life = rng_range(0.4, 0.8),
				color = Vec3{base.r * t, base.g * t, base.b * t},
				size = rng_range(0.05, 0.12),
			},
		)
	}
}

// A small burst of crumbs at the player's mouth when eating.
particle_spawn_eat :: proc(ps: ^[dynamic]Particle, pos: Vec3, color: Vec3) {
	for _ in 0 ..< 6 {
		t := rng_range(0.8, 1.1)
		append(
			ps,
			Particle {
				pos = pos +
				Vec3{rng_range(-0.08, 0.08), rng_range(-0.05, 0.05), rng_range(-0.08, 0.08)},
				vel = Vec3{rng_range(-0.6, 0.6), rng_range(0.4, 1.0), rng_range(-0.6, 0.6)},
				max_life = rng_range(0.25, 0.4),
				color = Vec3{color.r * t, color.g * t, color.b * t},
				size = rng_range(0.03, 0.06),
			},
		)
	}
}

particles_update :: proc(w: ^World, ps: ^[dynamic]Particle, dt: f32) {
	i := 0
	for i < len(ps^) {
		pt := &ps^[i]
		pt.life += dt
		if pt.life >= pt.max_life {
			ps^[i] = ps^[len(ps^) - 1]
			pop(ps)
			continue
		}
		pt.vel.y -= 20.0 * dt
		next := pt.pos + pt.vel * dt
		bx := int(math.floor(next.x))
		by := int(math.floor(next.y))
		bz := int(math.floor(next.z))
		if block_is_solid(world_block(w, bx, by, bz)) {
			pt.vel = Vec3{pt.vel.x * 0.4, 0, pt.vel.z * 0.4} // settle on the surface
		} else {
			pt.pos = next
		}
		i += 1
	}
}
