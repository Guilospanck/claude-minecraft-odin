package main

import "core:math"

Arrow :: struct {
	pos:         Vec3,
	vel:         Vec3,
	age:         f32,
	stuck:       bool,
	from_player: bool,
	fire:        bool, // ghast fireball: flies flat, bursts on impact, hits harder
}

ARROW_DMG :: 2
FIRE_DMG :: 5
ARROW_GRAVITY :: f32(14.0) // arrows fall slower than the player
FIRE_GRAVITY :: f32(1.5) // fireballs barely drop

@(private = "file")
arrow_hits_player :: proc(pos: Vec3, p: ^Player) -> bool {
	return(
		pos.x > p.pos.x - PLAYER_HW &&
		pos.x < p.pos.x + PLAYER_HW &&
		pos.y > p.pos.y &&
		pos.y < p.pos.y + PLAYER_H &&
		pos.z > p.pos.z - PLAYER_HW &&
		pos.z < p.pos.z + PLAYER_HW \
	)
}

arrows_update :: proc(w: ^World, p: ^Player, dt: f32) {
	i := 0
	for i < len(w.arrows) {
		a := &w.arrows[i]
		a.age += dt

		if a.stuck {
			if a.age > 8 {
				w.arrows[i] = w.arrows[len(w.arrows) - 1]
				pop(&w.arrows)
				continue
			}
			i += 1
			continue
		}

		a.vel.y -= (a.fire ? FIRE_GRAVITY : ARROW_GRAVITY) * dt

		removed := false
		STEPS :: 4
		sub := dt / f32(STEPS)
		for s in 0 ..< STEPS {
			a.pos += a.vel * sub
			bx := int(math.floor(a.pos.x))
			by := int(math.floor(a.pos.y))
			bz := int(math.floor(a.pos.z))
			if block_is_solid(world_block(w, bx, by, bz)) {
				if a.fire { 	// fireball bursts against terrain
					w.arrows[i] = w.arrows[len(w.arrows) - 1]
					pop(&w.arrows)
					removed = true
				} else {
					a.stuck = true
					a.age = 0
				}
				break
			}
			if !a.from_player && arrow_hits_player(a.pos, p) {
				d := Vec3{a.vel.x, 0, a.vel.z}
				dl := math.sqrt(d.x * d.x + d.z * d.z) + 1e-4
				player_damage(p, a.fire ? FIRE_DMG : ARROW_DMG, Vec3{d.x / dl, 0, d.z / dl})
				w.arrows[i] = w.arrows[len(w.arrows) - 1]
				pop(&w.arrows)
				removed = true
				break
			}
			// A player's arrow strikes a mob it flies into.
			if a.from_player {
				hit_mob := -1
				for mi in 0 ..< len(w.mobs) {
					m := w.mobs[mi]
					if m.health <= 0 do continue
					dims := MOB_DIMS[m.kind]
					if a.pos.x > m.pos.x - dims.hw &&
					   a.pos.x < m.pos.x + dims.hw &&
					   a.pos.y > m.pos.y &&
					   a.pos.y < m.pos.y + dims.h &&
					   a.pos.z > m.pos.z - dims.hw &&
					   a.pos.z < m.pos.z + dims.hw {
						hit_mob = mi
						break
					}
				}
				if hit_mob >= 0 {
					d := Vec3{a.vel.x, 0, a.vel.z}
					dl := math.sqrt(d.x * d.x + d.z * d.z) + 1e-4
					mob_hit(w, hit_mob, Vec3{d.x / dl, 0, d.z / dl}, ARROW_DMG + 2)
					w.arrows[i] = w.arrows[len(w.arrows) - 1]
					pop(&w.arrows)
					removed = true
					break
				}
			}
		}
		if removed do continue

		if a.age > 12 || a.pos.y < -8 {
			w.arrows[i] = w.arrows[len(w.arrows) - 1]
			pop(&w.arrows)
			continue
		}
		i += 1
	}
}
