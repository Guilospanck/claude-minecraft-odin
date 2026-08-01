package main

// Block lighting: flood-fill from emissive blocks within a chunk. Light level
// 0..15 decreases by 1 per step and stops at opaque blocks. Computed per
// remesh and baked into the mesh so it survives day-night dimming.
//
// Light is confined to a single chunk (it does not bleed across chunk seams);
// this keeps it cheap and order-independent. Torches light their own 16x16
// column, which is enough to see by at night.

@(private = "file")
NEIGHBOR6 := [6]Ivec3{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}

@(private = "file")
LightNode :: struct {
	x, y, z: int,
	level:   u8,
}

compute_light :: proc(c: ^Chunk) {
	for i in 0 ..< CHUNK_BLOCKS do c.light[i] = 0

	q := make([dynamic]LightNode, 0, 256)
	defer delete(q)

	// seed emissive blocks
	for y in 0 ..< CHUNK_H {
		for z in 0 ..< CHUNK_D {
			for x in 0 ..< CHUNK_W {
				e := block_emission(c.blocks[chunk_index(x, y, z)])
				if e > 0 {
					c.light[chunk_index(x, y, z)] = e
					append(&q, LightNode{x, y, z, e})
				}
			}
		}
	}

	// flood fill
	for len(q) > 0 {
		node := pop(&q)
		if node.level <= 1 do continue
		nl := node.level - 1
		for d in NEIGHBOR6 {
			nx := node.x + d.x
			ny := node.y + d.y
			nz := node.z + d.z
			if !chunk_in_bounds(nx, ny, nz) do continue
			idx := chunk_index(nx, ny, nz)
			if block_is_opaque(c.blocks[idx]) do continue // light can't enter solids
			if c.light[idx] >= nl do continue
			c.light[idx] = nl
			append(&q, LightNode{nx, ny, nz, nl})
		}
	}
}

// Block-light at a local cell (0 outside the chunk).
chunk_light_at :: proc(c: ^Chunk, x, y, z: int) -> u8 {
	if !chunk_in_bounds(x, y, z) do return 0
	return c.light[chunk_index(x, y, z)]
}
