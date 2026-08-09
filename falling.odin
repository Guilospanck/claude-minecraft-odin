package main

import "core:math"

// Gravity-affected blocks: gravel and the sands fall when the block beneath them
// is removed, and settle back into the world when they land — the Minecraft
// mechanic behind sand traps and gravel cave-ins.

FallingBlock :: struct {
	pos:   Vec3, // min corner of the 1x1x1 block
	vel:   Vec3,
	block: BlockId,
}

block_has_gravity :: proc(b: BlockId) -> bool {
	return b == .Gravel || b == .Sand || b == .RedSand
}

// After a block is removed at (x,y,z), any stack of gravity blocks resting on top
// of it comes loose and starts falling.
falling_check_above :: proc(w: ^World, x, y, z: int) {
	ay := y + 1
	for ay < 250 && block_has_gravity(world_block(w, x, ay, z)) {
		b := world_block(w, x, ay, z)
		world_set_block(w, x, ay, z, .Air)
		net_send_edit(x, ay, z, .Air, w.dimension)
		append(&w.falling, FallingBlock{pos = Vec3{f32(x), f32(ay), f32(z)}, block = b})
		ay += 1
	}
}

// Integrate the falling blocks: accelerate, and when the cell below turns solid,
// settle the block back into the world on top of it.
falling_update :: proc(w: ^World, dt: f32) {
	i := 0
	for i < len(w.falling) {
		f := &w.falling[i]
		f.vel.y = max(f.vel.y - GRAVITY * dt, -TERMINAL_VEL)
		cx := int(math.floor(f.pos.x))
		cz := int(math.floor(f.pos.z))
		ny := f.pos.y + f.vel.y * dt
		land_cell := int(math.floor(ny))
		if land_cell < 1 || block_is_solid(world_block(w, cx, land_cell, cz)) {
			rest := land_cell + 1
			for rest < 250 && block_is_solid(world_block(w, cx, rest, cz)) do rest += 1
			world_set_block(w, cx, rest, cz, f.block)
			net_send_edit(cx, rest, cz, f.block, w.dimension)
			w.falling[i] = w.falling[len(w.falling) - 1]
			pop(&w.falling)
			continue
		}
		f.pos.y = ny
		i += 1
	}
}

// A cave-in: hunt for an unsupported gravel/sand block near the player (the kind
// left dangling after you tunnel under one) and let it crumble.
cave_in :: proc(w: ^World, p: ^Player) {
	for _ in 0 ..< 10 {
		x := int(p.pos.x) + rng_int(24) - 12
		z := int(p.pos.z) + rng_int(24) - 12
		y := int(p.pos.y) + rng_int(12) - 6
		if block_has_gravity(world_block(w, x, y, z)) && world_block(w, x, y - 1, z) == .Air {
			falling_check_above(w, x, y - 1, z) // (x,y-1) already air -> the block at y comes loose
			audio_play(.Break, 0.4)
			return
		}
	}
}
