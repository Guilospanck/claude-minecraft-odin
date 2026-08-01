package main

import "core:math"

PORTAL_COST :: 14 // obsidian to build one
PORTAL_TRIGGER :: f32(1.0) // seconds standing in a portal before travel

// Build a 4x5 portal (obsidian frame + 2x3 portal interior) in the X-Y plane
// with its lower-left frame block at (ox, oy, oz).
build_portal :: proc(w: ^World, ox, oy, oz: int) {
	for dy in 0 ..< 5 {
		for dx in 0 ..< 4 {
			edge := dx == 0 || dx == 3 || dy == 0 || dy == 4
			world_set_block(w, ox + dx, oy + dy, oz, edge ? .Obsidian : .Portal)
		}
	}
}

player_in_portal :: proc(w: ^World, pos: Vec3) -> bool {
	x := int(math.floor(pos.x))
	z := int(math.floor(pos.z))
	return(
		world_block(w, x, int(math.floor(pos.y + 0.9)), z) == .Portal ||
		world_block(w, x, int(math.floor(pos.y + 0.2)), z) == .Portal \
	)
}

player_in_lava :: proc(w: ^World, pos: Vec3) -> bool {
	x := int(math.floor(pos.x))
	z := int(math.floor(pos.z))
	return(
		world_block(w, x, int(math.floor(pos.y + 0.2)), z) == .Lava ||
		world_block(w, x, int(math.floor(pos.y + 1.2)), z) == .Lava \
	)
}

// Ensure a return portal exists in `w` near (x,z) and return a safe spot beside
// it (2 blocks in front so you don't immediately re-enter).
portal_destination :: proc(w: ^World, x, z: int) -> Vec3 {
	world_ensure_chunk(w, world_chunk_at(w, x, z))
	world_ensure_chunk(w, world_chunk_at(w, x + 3, z + 2))
	world_ensure_chunk(w, world_chunk_at(w, x - 1, z - 1))

	sy := -1
	for y := CHUNK_H - 6; y >= 1; y -= 1 {
		if block_is_solid(world_block(w, x, y, z)) {
			sy = y
			break
		}
	}
	if sy < 0 do sy = 40
	oy := sy + 1
	build_portal(w, x, oy, z)

	// clear a small landing in front (+z) with a solid floor
	for dz in 1 ..= 3 {
		for dx in 0 ..< 4 {
			world_set_block(w, x + dx, oy, z + dz, .Air)
			world_set_block(w, x + dx, oy + 1, z + dz, .Air)
			if !block_is_solid(world_block(w, x + dx, oy - 1, z + dz)) {
				world_set_block(w, x + dx, oy - 1, z + dz, .Obsidian)
			}
		}
	}
	return Vec3{f32(x + 1) + 0.5, f32(oy), f32(z + 2) + 0.5}
}
