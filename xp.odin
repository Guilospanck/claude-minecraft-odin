package main

import "core:math/linalg"

// Experience orbs: small glowing motes dropped by kills. They bob on the ground
// until the player wanders near, then home in and are absorbed, adding to the
// player's experience level — the Minecraft XP loop.

XpOrb :: struct {
	pos:       Vec3,
	vel:       Vec3,
	amount:    int, // experience points this orb is worth
	age:       f32,
	on_ground: bool,
}

XP_ORB_HW :: f32(0.12)
XP_ORB_H :: f32(0.24)
XP_ATTRACT :: f32(5.0) // orbs within this range home in on the player
XP_PICKUP :: f32(0.9) // ... and are absorbed once this close
XP_ORB_LIFETIME :: f32(300.0)

// Experience needed to advance FROM `level` to the next one. A gentle linear
// ramp (cheaper than Minecraft's piecewise curve, same feel: later levels cost
// more).
xp_need :: proc(level: int) -> int {
	return 10 + 4 * level
}

// Fraction of the way to the next level, for the HUD bar.
xp_progress :: proc(p: ^Player) -> f32 {
	need := xp_need(p.xp_level)
	if need <= 0 do return 0
	return clamp(f32(p.xp_points) / f32(need), 0, 1)
}

// Bank experience, rolling over into as many level-ups as it covers.
xp_add :: proc(p: ^Player, n: int) {
	p.xp_points += n
	for p.xp_points >= xp_need(p.xp_level) {
		p.xp_points -= xp_need(p.xp_level)
		p.xp_level += 1
		audio_play(.Pickup, 0.7)
	}
}

// Spawn `total` experience as a small cluster of orbs that pop out of `pos`, so
// a kill scatters a handful of motes rather than one lump.
xp_orb_spawn :: proc(orbs: ^[dynamic]XpOrb, pos: Vec3, total: int) {
	remaining := total
	guard := 0
	for remaining > 0 && guard < 8 {
		a := min(remaining, 3)
		remaining -= a
		guard += 1
		append(
			orbs,
			XpOrb {
				pos = pos + Vec3{0, 0.4, 0},
				vel = Vec3{rng_range(-1.6, 1.6), rng_range(2.0, 3.5), rng_range(-1.6, 1.6)},
				amount = a,
			},
		)
	}
}

xp_orbs_update :: proc(w: ^World, p: ^Player, dt: f32) {
	target := p.pos + Vec3{0, 0.9, 0}
	i := 0
	for i < len(w.xp_orbs) {
		o := &w.xp_orbs[i]
		o.age += dt

		to := target - o.pos
		d := linalg.length(to)
		if d < XP_PICKUP {
			xp_add(p, o.amount)
			w.xp_orbs[i] = w.xp_orbs[len(w.xp_orbs) - 1]
			pop(&w.xp_orbs)
			continue
		}
		if d < XP_ATTRACT {
			// Home in: fly straight at the player, ghosting past terrain so orbs
			// never get stuck behind a lip of ground on the way in.
			o.vel = (to / d) * 8.0
			o.pos += o.vel * dt
			o.on_ground = false
		} else {
			// Idle: settle to the ground with a little friction.
			o.on_ground = body_physics(w, &o.pos, &o.vel, XP_ORB_HW, XP_ORB_H, dt)
			if o.on_ground {
				o.vel.x *= 0.7
				o.vel.z *= 0.7
			}
		}

		if o.age > XP_ORB_LIFETIME {
			w.xp_orbs[i] = w.xp_orbs[len(w.xp_orbs) - 1]
			pop(&w.xp_orbs)
			continue
		}
		i += 1
	}
}
