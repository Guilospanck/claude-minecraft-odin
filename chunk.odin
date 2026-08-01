package main

// A chunk is a full-height 16x16x128 column of blocks stored flat.
// GL handles live here but are only ever touched on the main thread by render.odin.
Chunk :: struct {
	coord:        Ivec2, // (cx, cz)
	blocks:       []BlockId, // len == CHUNK_BLOCKS
	light:        []u8, // block-light level 0..15, recomputed on remesh
	generated:    bool,
	dirty:        bool, // mesh is stale, needs rebuild

	// GL mesh state (0 == not created yet)
	gl_init:      bool,
	opaque_vao:   u32,
	opaque_vbo:   u32,
	opaque_count: i32,
	water_vao:    u32,
	water_vbo:    u32,
	water_count:  i32,
}

chunk_index :: #force_inline proc(x, y, z: int) -> int {
	return x + z * CHUNK_W + y * CHUNK_W * CHUNK_D
}

chunk_in_bounds :: #force_inline proc(x, y, z: int) -> bool {
	return x >= 0 && x < CHUNK_W && y >= 0 && y < CHUNK_H && z >= 0 && z < CHUNK_D
}

chunk_get :: proc(c: ^Chunk, x, y, z: int) -> BlockId {
	if !chunk_in_bounds(x, y, z) do return .Air
	return c.blocks[chunk_index(x, y, z)]
}

chunk_set :: proc(c: ^Chunk, x, y, z: int, b: BlockId) {
	if !chunk_in_bounds(x, y, z) do return
	c.blocks[chunk_index(x, y, z)] = b
}

chunk_make :: proc(coord: Ivec2) -> ^Chunk {
	c := new(Chunk)
	c.coord = coord
	c.blocks = make([]BlockId, CHUNK_BLOCKS)
	c.light = make([]u8, CHUNK_BLOCKS)
	c.dirty = true
	return c
}

// Free CPU allocations for a chunk (GL buffers must already be freed).
chunk_free :: proc(c: ^Chunk) {
	delete(c.blocks)
	delete(c.light)
	free(c)
}
