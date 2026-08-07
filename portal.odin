package main

import "core:math"

PORTAL_COST :: 14 // obsidian to build one
PORTAL_TRIGGER :: f32(0.25) // seconds in a portal before travel (snappy)
PORTAL_COOLDOWN :: f32(1.2) // grace after arriving so you don't bounce straight back

// Build a 4x4 portal (obsidian posts + top, 2x3 portal interior) in the X-Y
// plane with its lower-left frame block at (ox, oy, oz). The portal interior
// reaches the ground (there is NO obsidian sill) so you walk straight through
// it at feet level — the old sill was a full block, which the half-block
// auto-step (MAX_STEP) couldn't climb, so you had to jump to enter. A hidden
// obsidian floor under the interior keeps you from falling through.
build_portal :: proc(w: ^World, ox, oy, oz: int) {
	for dy in 0 ..< 4 {
		for dx in 0 ..< 4 {
			edge := dx == 0 || dx == 3 || dy == 3
			world_set_block(w, ox + dx, oy + dy, oz, edge ? .Obsidian : .Portal)
		}
	}
	world_set_block(w, ox + 1, oy - 1, oz, .Obsidian) // floor under the interior
	world_set_block(w, ox + 2, oy - 1, oz, .Obsidian)
}

// Break the obsidian frame -> the portal interior it powered winks out. Called
// after an Obsidian block at (bx,by,bz) is removed: flood-fill the connected
// .Portal cells reachable from its neighbours and clear them, so mining out the
// frame collapses the whole portal instead of leaving a floating purple sheet.
portal_collapse :: proc(w: ^World, bx, by, bz: int) {
	stack: [dynamic]Ivec3
	defer delete(stack)
	seed := [?]Ivec3{{bx + 1, by, bz}, {bx - 1, by, bz}, {bx, by + 1, bz}, {bx, by - 1, bz}}
	for s in seed {
		if world_block(w, s.x, s.y, s.z) == .Portal do append(&stack, s)
	}
	for len(stack) > 0 {
		c := pop(&stack)
		if world_block(w, c.x, c.y, c.z) != .Portal do continue
		world_set_block(w, c.x, c.y, c.z, .Air)
		net_send_edit(c.x, c.y, c.z, .Air, w.dimension)
		for n in ([?]Ivec3{{c.x + 1, c.y, c.z}, {c.x - 1, c.y, c.z}, {c.x, c.y + 1, c.z}, {c.x, c.y - 1, c.z}}) {
			if world_block(w, n.x, n.y, n.z) == .Portal do append(&stack, n)
		}
	}
}

// True when any part of the player's body (feet to head) is inside a portal
// block, so simply walking into the purple triggers travel — no need to line up
// on one exact cell.
player_in_portal :: proc(w: ^World, pos: Vec3) -> bool {
	x := int(math.floor(pos.x))
	z := int(math.floor(pos.z))
	for dy in ([?]f32{0.2, 0.9, 1.6}) {
		if world_block(w, x, int(math.floor(pos.y + dy)), z) == .Portal do return true
	}
	return false
}

player_in_lava :: proc(w: ^World, pos: Vec3) -> bool {
	x := int(math.floor(pos.x))
	z := int(math.floor(pos.z))
	return(
		world_block(w, x, int(math.floor(pos.y + 0.2)), z) == .Lava ||
		world_block(w, x, int(math.floor(pos.y + 1.2)), z) == .Lava \
	)
}

// The nearest existing portal to (x,z) in `w` within `radius`, as the bottom
// interior block (the walk-in spot). Used so travelling back doesn't stamp a
// fresh portal every trip when one is already right there.
PORTAL_REUSE_RADIUS :: 10
@(private = "file")
find_portal_near :: proc(w: ^World, x, z, radius: int) -> (px, py, pz: int, ok: bool) {
	for cz in floor_div(z - radius, CHUNK_D) ..= floor_div(z + radius, CHUNK_D) {
		for cx in floor_div(x - radius, CHUNK_W) ..= floor_div(x + radius, CHUNK_W) {
			world_ensure_chunk(w, Ivec2{cx, cz})
		}
	}
	best := radius * radius + 1
	for dz in -radius ..= radius {
		for dx in -radius ..= radius {
			d := dx * dx + dz * dz
			if d >= best do continue
			cx, cz := x + dx, z + dz
			for y := CHUNK_H - 2; y >= 2; y -= 1 {
				if world_block(w, cx, y, cz) == .Portal {
					// walk down to the bottom interior block (the entry level)
					by := y
					for world_block(w, cx, by - 1, cz) == .Portal do by -= 1
					px, py, pz, ok, best = cx, by, cz, true, d
					break
				}
			}
		}
	}
	return
}

// A safe standing spot beside an already-built portal in `w`: two blocks out on
// whichever face (±z) is clear, so you land facing it without re-entering.
@(private = "file")
portal_landing :: proc(w: ^World, px, py, pz: int) -> Vec3 {
	for dz in ([?]int{2, -2}) {
		lz := pz + dz
		if !block_is_solid(world_block(w, px, py, lz)) &&
		   !block_is_solid(world_block(w, px, py + 1, lz)) {
			if !block_is_solid(world_block(w, px, py - 1, lz)) {
				world_set_block(w, px, py - 1, lz, .Obsidian) // guarantee a floor
			}
			return Vec3{f32(px) + 0.5, f32(py), f32(lz) + 0.5}
		}
	}
	return Vec3{f32(px) + 0.5, f32(py), f32(pz + 2) + 0.5}
}

// Ensure a return portal exists in `w` near (x,z) and return a safe spot beside
// it. Reuses an existing nearby portal instead of building a new one, so
// round-tripping doesn't litter the world with duplicates.
portal_destination :: proc(w: ^World, x, z: int) -> Vec3 {
	if px, py, pz, ok := find_portal_near(w, x, z, PORTAL_REUSE_RADIUS); ok {
		return portal_landing(w, px, py, pz)
	}
	// Ensure every chunk the frame + landing can touch (x..x+3, z..z+3), so no
	// write lands in an unloaded chunk and gets silently dropped.
	for cz in floor_div(z, CHUNK_D) ..= floor_div(z + 3, CHUNK_D) {
		for cx in floor_div(x, CHUNK_W) ..= floor_div(x + 3, CHUNK_W) {
			world_ensure_chunk(w, Ivec2{cx, cz})
		}
	}

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
