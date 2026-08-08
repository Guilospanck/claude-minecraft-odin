package main

import "core:math"
import "vendor:glfw"

@(private = "file")
EPS :: f32(0.001)

// Substep length: keep any single collision test under one block so a fast
// fall (up to TERMINAL_VEL*dt_max = 3 blocks) can't tunnel a 1-block floor.
@(private = "file")
MAX_STEP :: f32(0.5)

// Generic feet-centred AABB: x/z centred on pos, y spans [pos.y, pos.y+h].
body_collides :: proc(w: ^World, pos: Vec3, hw, h: f32) -> bool {
	minx := int(math.floor(pos.x - hw))
	maxx := int(math.floor(pos.x + hw))
	miny := int(math.floor(pos.y))
	maxy := int(math.floor(pos.y + h))
	minz := int(math.floor(pos.z - hw))
	maxz := int(math.floor(pos.z + hw))
	for by in miny ..= maxy {
		for bx in minx ..= maxx {
			for bz in minz ..= maxz {
				b := world_block(w, bx, by, bz)
				if !block_is_solid(b) do continue
				// An open door doesn't block movement even though .Door is
				// solid by default (so raycasts/interaction still find it
				// when open) — this is the one place that distinction
				// actually matters, so it's checked here rather than
				// teaching block_is_solid about per-instance state.
				if b == .Door && w.doors[Ivec3{bx, by, bz}].open do continue
				return true
			}
		}
	}
	return false
}

// Move one axis by `disp` (substepped); on collision, snap flush to the
// blocking face and zero that axis' velocity. Returns whether it collided.
body_move_axis :: proc(w: ^World, pos: ^Vec3, vel: ^Vec3, disp: f32, axis: int, hw, h: f32) -> bool {
	lo := axis == 1 ? f32(0) : -hw
	hi := axis == 1 ? h : hw
	remaining := disp
	for {
		step := clamp(remaining, -MAX_STEP, MAX_STEP)
		pos^[axis] += step
		if body_collides(w, pos^, hw, h) {
			if step > 0 {
				pos^[axis] = math.floor(pos^[axis] + hi) - hi - EPS
			} else if step < 0 {
				pos^[axis] = math.floor(pos^[axis] + lo) + 1 - lo + EPS
			}
			vel^[axis] = 0
			return true
		}
		remaining -= step
		if math.abs(remaining) < 1e-5 do break
	}
	return false
}

// Integrate gravity + axis-separated collision for any AABB. Returns on_ground.
// `gravity` lets callers use reduced pull (e.g. buoyancy in water).
body_physics :: proc(w: ^World, pos: ^Vec3, vel: ^Vec3, hw, h, dt: f32, gravity: f32 = GRAVITY) -> bool {
	vel.y -= gravity * dt
	if vel.y < -TERMINAL_VEL do vel.y = -TERMINAL_VEL

	body_move_axis(w, pos, vel, vel.x * dt, 0, hw, h)
	body_move_axis(w, pos, vel, vel.z * dt, 2, hw, h)
	body_move_axis(w, pos, vel, vel.y * dt, 1, hw, h)

	// Ground contact from a small probe below the feet, independent of whether
	// we collided this exact frame (robust at high frame rates).
	grounded := body_collides(w, pos^ - Vec3{0, 2 * EPS, 0}, hw, h)
	if grounded && vel.y < 0 {
		vel.y = 0
	}
	return grounded
}

CREATURE_AIR_MAX :: f32(11.0) // seconds a land creature can hold its breath underwater

// True when a land creature's feet AND head are in water (fully submerged, so it
// can't just wade — it has to swim for it).
body_submerged :: proc(w: ^World, pos: Vec3, h: f32) -> bool {
	x := int(math.floor(pos.x))
	z := int(math.floor(pos.z))
	feet := world_block(w, x, int(math.floor(pos.y + 0.2)), z) == .Water
	head := world_block(w, x, int(math.floor(pos.y + h * 0.7)), z) == .Water
	return feet && head
}

// A unit direction toward the nearest dry land (a column whose surface sits at
// or above sea level), scanning the 8 compass directions outward. Zero if no
// land is within reach — the creature then just treads toward the surface.
body_land_dir :: proc(w: ^World, pos: Vec3) -> Vec3 {
	dirs := [8][2]f32 {
		{1, 0},
		{-1, 0},
		{0, 1},
		{0, -1},
		{0.7, 0.7},
		{-0.7, 0.7},
		{0.7, -0.7},
		{-0.7, -0.7},
	}
	best := f32(999)
	bx, bz := f32(0), f32(0)
	for d in dirs {
		for dist in ([?]f32{2, 4, 6, 9, 13, 18}) {
			x := int(math.floor(pos.x + d[0] * dist))
			z := int(math.floor(pos.z + d[1] * dist))
			sy, _ := surface_y(w, x, z)
			if sy >= SEA_LEVEL { 	// dry ground at/above the waterline
				if dist < best {
					best = dist
					bx, bz = d[0], d[1]
				}
				break
			}
		}
	}
	if best < 999 do return Vec3{bx, 0, bz}
	return Vec3{0, 0, 0}
}

// Walking-critter step logic, shared by mobs and villagers. Given feet `pos`,
// heading `fwd` and body dims, look at the block directly ahead:
//   - clear         -> (0, false): keep walking.
//   - a 1-block step with clear space above -> (hop_vy, false): hop it.
//   - a fence/gate/wall, or anything 2+ tall -> (0, true): blocked, turn away.
// Fences/walls/gates are deliberately un-hoppable (real fences are taller than
// a mob can jump) even though their collision box is only one block here.
step_or_block :: proc(w: ^World, pos, fwd: Vec3, hw, h: f32) -> (hop_vy: f32, blocked: bool) {
	ahead := pos + Vec3{fwd.x * (hw + 0.25), 0, fwd.z * (hw + 0.25)}
	if !body_collides(w, ahead, hw, 0.5) do return 0, false // nothing in the way
	fcell := world_block(w, int(math.floor(ahead.x)), int(math.floor(pos.y)), int(math.floor(ahead.z)))
	if fcell == .Fence || fcell == .FenceGate || fcell == .Wall do return 0, true // can't vault a fence
	if !body_collides(w, ahead + Vec3{0, 1, 0}, hw, h) do return 8.0, false // one-block step: hop
	return 0, true // too tall to climb
}

// Is the player's feet or chest in a water block?
player_in_water :: proc(w: ^World, pos: Vec3) -> bool {
	x := int(math.floor(pos.x))
	z := int(math.floor(pos.z))
	return(
		world_block(w, x, int(math.floor(pos.y + 0.2)), z) == .Water ||
		world_block(w, x, int(math.floor(pos.y + 1.2)), z) == .Water \
	)
}

// True when the player's body shares a cell with a ladder, so they can climb.
player_on_ladder :: proc(w: ^World, pos: Vec3) -> bool {
	x := int(math.floor(pos.x))
	z := int(math.floor(pos.z))
	for dy in ([?]f32{0.2, 1.0, 1.6}) {
		if world_block(w, x, int(math.floor(pos.y + dy)), z) == .Ladder do return true
	}
	return false
}

physics_update :: proc(w: ^World, p: ^Player, dt: f32) {
	if p.fly {
		// Fly with no gravity but still collide with solid blocks, so you can't
		// sink through the floor into lava / the void (Minecraft creative fly).
		body_move_axis(w, &p.pos, &p.vel, p.vel.x * dt, 0, PLAYER_HW, PLAYER_H)
		body_move_axis(w, &p.pos, &p.vel, p.vel.z * dt, 2, PLAYER_HW, PLAYER_H)
		body_move_axis(w, &p.pos, &p.vel, p.vel.y * dt, 1, PLAYER_HW, PLAYER_H)
		p.on_ground = body_collides(w, p.pos - Vec3{0, 2 * EPS, 0}, PLAYER_HW, PLAYER_H)
		p.in_water = false
		p.fall_speed = 0
		return
	}

	p.in_water = player_in_water(w, p.pos)

	if p.in_water {
		// buoyant, reduced-gravity water; swim velocity is set in process_input
		p.on_ground = body_physics(w, &p.pos, &p.vel, PLAYER_HW, PLAYER_H, dt, 6.0)
		if p.vel.y < -3 do p.vel.y = -3 // slow sink
		if p.vel.y > 5 do p.vel.y = 5
		p.fall_speed = 0 // splashing down never hurts
		return
	}

	if !p.fly && player_on_ladder(w, p.pos) {
		// Climb the rungs swiftly: W (or space) goes up, S (or shift) down; with
		// no climb input you cling in place. While climbing we cancel horizontal
		// drift so W means "up the ladder" instead of shoving you off it — once
		// you climb above the ladder, normal movement resumes and you walk off.
		up := glfw.GetKey(g_win, glfw.KEY_W) == glfw.PRESS || glfw.GetKey(g_win, glfw.KEY_SPACE) == glfw.PRESS
		down := glfw.GetKey(g_win, glfw.KEY_S) == glfw.PRESS || glfw.GetKey(g_win, glfw.KEY_LEFT_SHIFT) == glfw.PRESS
		if up || down {
			p.vel.x = 0
			p.vel.z = 0
			p.vel.y = up ? 4.8 : -4.8
		} else {
			p.vel.y = 0 // hang on the rung
		}
		p.on_ground = body_physics(w, &p.pos, &p.vel, PLAYER_HW, PLAYER_H, dt, 0.0)
		p.fall_speed = 0
		return
	}

	if !p.on_ground && p.vel.y < 0 {
		fs := -p.vel.y
		if fs > p.fall_speed do p.fall_speed = fs
	}
	was_air := !p.on_ground

	p.on_ground = body_physics(w, &p.pos, &p.vel, PLAYER_HW, PLAYER_H, dt)

	if p.on_ground {
		if was_air && p.fall_speed > FALL_SAFE {
			dmg := int((p.fall_speed - FALL_SAFE) * 0.5)
			if dmg > 0 do player_damage(p, dmg, Vec3{0, 0, 0})
		}
		p.fall_speed = 0
	}
}
