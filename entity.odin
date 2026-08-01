package main

import "core:math"

MobKind :: enum {
	Pig,
	Sheep,
	Cow,
	Chicken,
	Rabbit,
	Zombie,
	Skeleton,
}

MOB_KIND_COUNT :: len(MobKind)
PASSIVE_COUNT :: 5 // Pig..Rabbit; hostiles spawn separately

ZOMBIE_DETECT :: f32(18.0)
ZOMBIE_REACH :: f32(1.5)
ZOMBIE_DMG :: 3

mob_is_hostile :: proc(k: MobKind) -> bool {
	return k == .Zombie || k == .Skeleton
}

Mob :: struct {
	kind:         MobKind,
	pos:          Vec3, // feet centre
	vel:          Vec3,
	yaw:          f32,
	on_ground:    bool,
	moving:       bool,
	walk_phase:   f32, // drives leg animation
	ai_timer:     f32,
	attack_timer: f32, // hostile melee cooldown
	burn_accum:   f32, // fractional daylight-burn damage
	health:       int,
}

MobDims :: struct {
	hw:    f32, // half width/depth
	h:     f32, // height
	speed: f32,
}

MOB_DIMS := [MobKind]MobDims {
	.Pig      = {0.45, 0.9, 2.2},
	.Sheep    = {0.45, 1.2, 2.0},
	.Cow      = {0.5, 1.4, 1.9},
	.Chicken  = {0.3, 0.7, 2.6},
	.Rabbit   = {0.25, 0.5, 2.8},
	.Zombie   = {0.35, 1.9, 3.2},
	.Skeleton = {0.33, 1.85, 3.8},
}

MOB_CAP :: 22
MOB_DESPAWN_DIST :: f32(60)

// --- AI + physics for one mob ---
@(private = "file")
ai_wander :: proc(m: ^Mob, dt: f32, move_chance: f32) {
	m.ai_timer -= dt
	if m.ai_timer <= 0 {
		m.ai_timer = rng_range(1.5, 4.0)
		m.moving = rng_f32() < move_chance
		if m.moving {
			m.yaw = rng_range(0, 2 * math.PI)
		}
	}
}

@(private = "file")
ai_hostile :: proc(w: ^World, p: ^Player, m: ^Mob, dt: f32) {
	dx := p.pos.x - m.pos.x
	dz := p.pos.z - m.pos.z
	d2 := dx * dx + dz * dz
	if d2 < ZOMBIE_DETECT * ZOMBIE_DETECT {
		m.moving = true
		m.yaw = math.atan2(dx, -dz) // face the player
		m.attack_timer -= dt
		if d2 < ZOMBIE_REACH * ZOMBIE_REACH &&
		   math.abs(p.pos.y - m.pos.y) < 2.0 &&
		   m.attack_timer <= 0 {
			inv := 1.0 / math.sqrt(d2 + 1e-4)
			player_damage(p, ZOMBIE_DMG, Vec3{dx * inv, 0, dz * inv})
			m.attack_timer = 1.0
		}
	} else {
		ai_wander(m, dt, 0.4)
	}
}

mob_update :: proc(w: ^World, p: ^Player, m: ^Mob, dt: f32) {
	dims := MOB_DIMS[m.kind]

	if mob_is_hostile(m.kind) {
		ai_hostile(w, p, m, dt)
	} else {
		ai_wander(m, dt, 0.6)
	}

	if m.moving {
		fwd := Vec3{math.sin(m.yaw), 0, -math.cos(m.yaw)}
		m.vel.x = fwd.x * dims.speed
		m.vel.z = fwd.z * dims.speed
		m.walk_phase += dt * 9.0

		// hop over a one-block step when blocked and grounded
		if m.on_ground {
			ahead := m.pos + Vec3{fwd.x * (dims.hw + 0.25), 0, fwd.z * (dims.hw + 0.25)}
			if body_collides(w, ahead, dims.hw, 0.5) {
				m.vel.y = 7.5
			}
		}
	} else {
		m.vel.x = 0
		m.vel.z = 0
	}

	m.on_ground = body_physics(w, &m.pos, &m.vel, dims.hw, dims.h, dt)
}

// --- spawning ---
@(private = "file")
surface_y :: proc(w: ^World, wx, wz: int) -> (int, BlockId) {
	for y := CHUNK_H - 2; y >= 1; y -= 1 {
		b := world_block(w, wx, y, wz)
		if b != .Air && b != .Water do return y, b
	}
	return -1, .Air
}

mob_try_spawn :: proc(w: ^World, mobs: ^[dynamic]Mob, player_pos: Vec3) {
	if len(mobs^) >= MOB_CAP do return
	ang := rng_range(0, 2 * math.PI)
	dist := rng_range(20, 44)
	wx := int(player_pos.x + math.cos(ang) * dist)
	wz := int(player_pos.z + math.sin(ang) * dist)

	sy, surf := surface_y(w, wx, wz)
	if sy < 0 do return
	if surf != .Grass && surf != .Sand && surf != .Snow do return
	if world_block(w, wx, sy + 1, wz) == .Water do return // don't spawn on seabed
	if block_is_solid(world_block(w, wx, sy + 1, wz)) do return // needs headroom

	kind := MobKind(rng_int(PASSIVE_COUNT))
	append(
		mobs,
		Mob {
			kind = kind,
			pos = Vec3{f32(wx) + 0.5, f32(sy + 1), f32(wz) + 0.5},
			yaw = rng_range(0, 2 * math.PI),
			ai_timer = rng_range(0, 2),
			health = 6,
		},
	)
}

// Hostile spawn: zombies/skeletons appear at night on solid ground.
hostile_try_spawn :: proc(w: ^World, mobs: ^[dynamic]Mob, player_pos: Vec3) {
	if len(mobs^) >= MOB_CAP do return
	ang := rng_range(0, 2 * math.PI)
	dist := rng_range(24, 46)
	wx := int(player_pos.x + math.cos(ang) * dist)
	wz := int(player_pos.z + math.sin(ang) * dist)

	sy, surf := surface_y(w, wx, wz)
	if sy < 0 do return
	if surf == .Water do return
	if world_block(w, wx, sy + 1, wz) == .Water do return
	if block_is_solid(world_block(w, wx, sy + 1, wz)) do return

	kind: MobKind = rng_f32() < 0.5 ? .Zombie : .Skeleton
	hp := kind == .Zombie ? 12 : 8
	append(
		mobs,
		Mob {
			kind = kind,
			pos = Vec3{f32(wx) + 0.5, f32(sy + 1), f32(wz) + 0.5},
			yaw = rng_range(0, 2 * math.PI),
			ai_timer = rng_range(0, 2),
			health = hp,
		},
	)
}

// Debug: force-spawn n mobs (cycling kinds) on surfaces around `center`.
mob_debug_populate :: proc(w: ^World, mobs: ^[dynamic]Mob, center: Vec3, n: int) {
	for k in 0 ..< n {
		wx := int(center.x) + (rng_int(20) - 10)
		wz := int(center.z) + (rng_int(20) - 10)
		world_ensure_chunk(w, Ivec2{floor_div(wx, CHUNK_W), floor_div(wz, CHUNK_D)})
		sy, _ := surface_y(w, wx, wz)
		if sy < 0 do continue
		if world_block(w, wx, sy + 1, wz) == .Water do continue
		if block_is_solid(world_block(w, wx, sy + 1, wz)) do continue
		append(
			mobs,
			Mob {
				kind = MobKind(k % MOB_KIND_COUNT),
				pos = Vec3{f32(wx) + 0.5, f32(sy + 1), f32(wz) + 0.5},
				yaw = rng_range(0, 2 * math.PI),
				ai_timer = rng_range(0, 2),
				health = 6,
			},
		)
	}
}

// Update all mobs: spawning (passive anytime, zombies at night), per-mob AI,
// daylight burn for zombies, and far-away / dead despawn.
mobs_update :: proc(w: ^World, p: ^Player, mobs: ^[dynamic]Mob, dt: f32) {
	player_pos := p.pos
	if rng_f32() < 0.03 do mob_try_spawn(w, mobs, player_pos)
	if is_night(w.time_of_day) && rng_f32() < 0.05 do hostile_try_spawn(w, mobs, player_pos)

	i := 0
	for i < len(mobs^) {
		m := &mobs^[i]
		if mob_is_hostile(m.kind) && is_day(w.time_of_day) {
			// dt-scaled burn: ~6 hp/s, so a 12-hp zombie lasts ~2s in daylight
			m.burn_accum += 6.0 * dt
			if m.burn_accum >= 1.0 {
				d := int(m.burn_accum)
				m.health -= d
				m.burn_accum -= f32(d)
			}
		}
		dx := m.pos.x - player_pos.x
		dz := m.pos.z - player_pos.z
		if dx * dx + dz * dz > MOB_DESPAWN_DIST * MOB_DESPAWN_DIST ||
		   m.pos.y < -8 ||
		   m.health <= 0 {
			mobs^[i] = mobs^[len(mobs^) - 1]
			pop(mobs)
			continue
		}
		mob_update(w, p, m, dt)
		i += 1
	}
}

// --- interaction ---
// Slab test: distance along a (normalised) ray to an AABB, if hit.
ray_aabb :: proc(orig, dir, bmin, bmax: Vec3) -> (bool, f32) {
	tmin: f32 = 0
	tmax: f32 = 1e30
	for a in 0 ..< 3 {
		if math.abs(dir[a]) < 1e-8 {
			if orig[a] < bmin[a] || orig[a] > bmax[a] do return false, 0
		} else {
			inv := 1.0 / dir[a]
			t1 := (bmin[a] - orig[a]) * inv
			t2 := (bmax[a] - orig[a]) * inv
			if t1 > t2 do t1, t2 = t2, t1
			if t1 > tmin do tmin = t1
			if t2 < tmax do tmax = t2
			if tmin > tmax do return false, 0
		}
	}
	return true, tmin
}

// Nearest mob under the ray within `reach`; returns index or -1.
mob_pick :: proc(mobs: ^[dynamic]Mob, eye, dir: Vec3, reach: f32) -> (int, f32) {
	best := -1
	best_t: f32 = reach
	for i in 0 ..< len(mobs^) {
		m := &mobs^[i]
		dims := MOB_DIMS[m.kind]
		bmin := Vec3{m.pos.x - dims.hw, m.pos.y, m.pos.z - dims.hw}
		bmax := Vec3{m.pos.x + dims.hw, m.pos.y + dims.h, m.pos.z + dims.hw}
		ok, t := ray_aabb(eye, dir, bmin, bmax)
		if ok && t < best_t {
			best = i
			best_t = t
		}
	}
	return best, best_t
}

// Hit a mob: knockback + damage; on death drop food (passive) and remove.
mob_hit :: proc(w: ^World, idx: int, dir: Vec3) {
	m := &w.mobs[idx]
	m.health -= 3
	m.vel.x += dir.x * 6.0
	m.vel.z += dir.z * 6.0
	m.vel.y = 6.0
	audio_play(.Hurt, 0.7)
	if m.health <= 0 {
		if !mob_is_hostile(m.kind) {
			item_spawn_food(&w.items, m.pos)
			item_spawn_food(&w.items, m.pos)
		}
		w.mobs[idx] = w.mobs[len(w.mobs) - 1]
		pop(&w.mobs)
	}
}
