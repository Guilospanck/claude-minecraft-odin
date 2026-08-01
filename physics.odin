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

// Move one axis by `disp`; on collision, snap flush to the blocking face and
// zero that axis' velocity. Returns whether a collision happened.
@(private = "file")
move_axis :: proc(w: ^World, p: ^Player, disp: f32, axis: int) -> bool {
	p.pos[axis] += disp
	if player_collides(w, p.pos) {
		if disp > 0 {
			p.pos[axis] = math.floor(p.pos[axis] + HI[axis]) - HI[axis] - EPS
		} else if disp < 0 {
			p.pos[axis] = math.floor(p.pos[axis] + LO[axis]) + 1 - LO[axis] + EPS
		}
		p.vel[axis] = 0
		return true
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

	dy := p.vel.y * dt
	p.on_ground = move_axis(w, p, dy, 1) && dy < 0
}
