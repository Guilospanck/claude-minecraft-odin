package main

import "core:math"

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
				if block_is_solid(world_block(w, bx, by, bz)) do return true
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
body_physics :: proc(w: ^World, pos: ^Vec3, vel: ^Vec3, hw, h, dt: f32) -> bool {
	vel.y -= GRAVITY * dt
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

physics_update :: proc(w: ^World, p: ^Player, dt: f32) {
	if p.fly {
		p.pos += p.vel * dt // noclip free-fly
		p.on_ground = false
		return
	}
	p.on_ground = body_physics(w, &p.pos, &p.vel, PLAYER_HW, PLAYER_H, dt)
}
