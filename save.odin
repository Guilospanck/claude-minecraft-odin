package main

import "core:fmt"
import "core:os"

WORLD_DIR :: "saves/world"

save_ensure_dir :: proc() {
	if !os.exists("saves") do os.make_directory("saves")
	if !os.exists(WORLD_DIR) do os.make_directory(WORLD_DIR)
}

@(private = "file")
chunk_path :: proc(coord: Ivec2) -> string {
	return fmt.tprintf("%s/%d_%d.chunk", WORLD_DIR, coord.x, coord.y)
}

// Run-length encode the block array: [id u8][run u16 little-endian] records.
save_chunk :: proc(c: ^Chunk) {
	save_ensure_dir()
	buf := make([dynamic]u8, 0, 4096)
	defer delete(buf)

	i := 0
	for i < CHUNK_BLOCKS {
		b := c.blocks[i]
		run := 1
		for i + run < CHUNK_BLOCKS && c.blocks[i + run] == b && run < 65535 {
			run += 1
		}
		append(&buf, u8(b), u8(run & 0xff), u8((run >> 8) & 0xff))
		i += run
	}
	_ = os.write_entire_file(chunk_path(c.coord), buf[:])
}

load_chunk :: proc(coord: Ivec2) -> (^Chunk, bool) {
	path := chunk_path(coord)
	if !os.exists(path) do return nil, false
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return nil, false
	defer delete(data)

	c := chunk_make(coord)
	i := 0
	idx := 0
	for i + 3 <= len(data) && idx < CHUNK_BLOCKS {
		b := BlockId(data[i])
		run := int(data[i + 1]) | (int(data[i + 2]) << 8)
		for _ in 0 ..< run {
			if idx >= CHUNK_BLOCKS do break
			c.blocks[idx] = b
			idx += 1
		}
		i += 3
	}
	if idx != CHUNK_BLOCKS {
		delete(c.blocks)
		free(c)
		return nil, false
	}
	return c, true
}

save_meta :: proc(seed: u64) {
	save_ensure_dir()
	buf: [8]u8
	for i in 0 ..< 8 {
		buf[i] = u8((seed >> uint(i * 8)) & 0xff)
	}
	_ = os.write_entire_file(fmt.tprintf("%s/meta", WORLD_DIR), buf[:])
}

load_meta :: proc() -> (u64, bool) {
	path := fmt.tprintf("%s/meta", WORLD_DIR)
	if !os.exists(path) do return 0, false
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return 0, false
	defer delete(data)
	if len(data) < 8 do return 0, false
	seed: u64 = 0
	for i in 0 ..< 8 {
		seed |= u64(data[i]) << uint(i * 8)
	}
	return seed, true
}
