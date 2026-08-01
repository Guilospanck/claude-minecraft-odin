package main

import "core:math"

// AABB offsets from the feet position, per axis (x, y, z).
@(private = "file")
LO := [3]f32{-PLAYER_HW, 0, -PLAYER_HW}
@(private = "file")
HI := [3]f32{PLAYER_HW, PLAYER_H, PLAYER_HW}

@(private = "file")
EPS :: f32(0.001)

// Does the player AABB at `pos` overlap any solid block?
player_collides :: proc(w: ^World, pos: Vec3) -> bool {
	minx := int(math.floor(pos.x - PLAYER_HW))
	maxx := int(math.floor(pos.x + PLAYER_HW))
	miny := int(math.floor(pos.y))
	maxy := int(math.floor(pos.y + PLAYER_H))
	minz := int(math.floor(pos.z - PLAYER_HW))
	maxz := int(math.floor(pos.z + PLAYER_HW))
	for by in miny ..= maxy {
		for bx in minx ..= maxx {
			for bz in minz ..= maxz {
				if block_is_solid(world_block(w, bx, by, bz)) do return true
			}
		}
	}
	return false
}

// Substep length: keep any single collision test under one block so a fast
// fall (up to TERMINAL_VEL*dt_max = 3 blocks) can't tunnel a 1-block floor.
@(private = "file")
MAX_STEP :: f32(0.5)

// Move one axis by `disp` (substepped); on collision, snap flush to the
// blocking face and zero that axis' velocity. Returns whether it collided.
@(private = "file")
move_axis :: proc(w: ^World, p: ^Player, disp: f32, axis: int) -> bool {
	remaining := disp
	for {
		step := clamp(remaining, -MAX_STEP, MAX_STEP)
		p.pos[axis] += step
		if player_collides(w, p.pos) {
			if step > 0 {
				p.pos[axis] = math.floor(p.pos[axis] + HI[axis]) - HI[axis] - EPS
			} else if step < 0 {
				p.pos[axis] = math.floor(p.pos[axis] + LO[axis]) + 1 - LO[axis] + EPS
			}
			p.vel[axis] = 0
			return true
		}
		remaining -= step
		if math.abs(remaining) < 1e-5 do break
	}
	return false
}

physics_update :: proc(w: ^World, p: ^Player, dt: f32) {
	if p.fly {
		p.pos += p.vel * dt // noclip free-fly
		p.on_ground = false
		return
	}

	p.vel.y -= GRAVITY * dt
	if p.vel.y < -TERMINAL_VEL do p.vel.y = -TERMINAL_VEL

	move_axis(w, p, p.vel.x * dt, 0)
	move_axis(w, p, p.vel.z * dt, 2)
	move_axis(w, p, p.vel.y * dt, 1)

	// Ground contact from a small probe below the feet, independent of whether
	// we collided this exact frame (which fails at high frame rates where the
	// per-frame gravity drop is smaller than the resting EPS gap).
	p.on_ground = player_collides(w, p.pos - Vec3{0, 2 * EPS, 0})
	if p.on_ground && p.vel.y < 0 {
		p.vel.y = 0
	}
}
