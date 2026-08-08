package main

// Small standalone structures scattered across the world (separate from
// villages): a desert well, a snow igloo, a swamp hut. Each is hash-anchored
// per chunk and small enough to fit inside one chunk, so — unlike villages —
// they draw with plain chunk-local writes, no cross-chunk brush needed.

STRUCTURE_CHANCE :: 150 // ~1 in this many chunks is a structure anchor

// The flat build height for a 5x5 footprint centred on (cx,cz), or ok=false if
// the ground is too uneven or runs off the chunk.
@(private = "file")
struct_flat :: proc(heights: []int, cx, cz: int) -> (surf: int, ok: bool) {
	lo, hi := 9999, -9999
	for dz in -2 ..= 2 {
		for dx in -2 ..= 2 {
			lx, lz := cx + dx, cz + dz
			if lx < 0 || lx >= CHUNK_W || lz < 0 || lz >= CHUNK_D do return 0, false
			hh := heights[lx + lz * CHUNK_W]
			lo = min(lo, hh)
			hi = max(hi, hh)
		}
	}
	if hi - lo > 2 do return 0, false
	return heights[cx + cz * CHUNK_W], true
}

// Called once per generated chunk (from worldgen_fill, after villages). Rolls a
// sparse per-chunk anchor and, on a hit, drops the structure that suits the
// centre biome onto flat ground.
generate_structures :: proc(w: ^World, c: ^Chunk, seed: u64, base_x, base_z: int, heights: []int, biomes: []Biome) {
	hsh := hash_u64(
		seed ~
		(u64(i64(c.coord.x)) * 0x27D4EB2F) ~
		(u64(i64(c.coord.y)) * 0x165667B1) ~
		0x5712_57AC,
	)
	if hsh % STRUCTURE_CHANCE != 0 do return

	cx, cz := 8, 8
	biome := biomes[cx + cz * CHUNK_W]
	surf, ok := struct_flat(heights, cx, cz)
	if !ok do return
	base_y := surf + 1
	#partial switch biome {
	case .Desert, .Badlands:
		build_desert_well(c, cx, cz, base_y)
	case .Snow:
		build_igloo(w, c, base_x, base_z, cx, cz, base_y)
	case .Swamp:
		build_swamp_hut(c, cx, cz, base_y)
	}
}

// A desert well: a stone-brick rim around a one-deep water pool, four fence
// posts, and a slab canopy — a shady oasis marker.
@(private = "file")
build_desert_well :: proc(c: ^Chunk, cx, cz, base_y: int) {
	for dx in -1 ..= 1 {
		for dz in -1 ..= 1 {
			if dx == 0 && dz == 0 {
				chunk_set(c, cx, base_y - 1, cz, .Water)
			} else {
				chunk_set(c, cx + dx, base_y, cz + dz, .StoneBrick)
			}
		}
	}
	for cr in ([4][2]int{{-1, -1}, {1, -1}, {-1, 1}, {1, 1}}) {
		chunk_set(c, cx + cr[0], base_y + 1, cz + cr[1], .Fence)
		chunk_set(c, cx + cr[0], base_y + 2, cz + cr[1], .Fence)
	}
	for dx in -1 ..= 1 {
		for dz in -1 ..= 1 do chunk_set(c, cx + dx, base_y + 3, cz + dz, .Slab)
	}
}

// A snow igloo: a hollow snow shell with a door, a bed and a glowstone lamp.
@(private = "file")
build_igloo :: proc(w: ^World, c: ^Chunk, base_x, base_z, cx, cz, base_y: int) {
	for dy in 0 ..< 3 {
		for dx in -2 ..= 2 {
			for dz in -2 ..= 2 {
				if abs(dx) == 2 || abs(dz) == 2 do chunk_set(c, cx + dx, base_y + dy, cz + dz, .Snow)
			}
		}
	}
	// hollow the interior + a snow floor and a flat snow roof
	for dx in -1 ..= 1 {
		for dz in -1 ..= 1 {
			for dy in 0 ..< 3 do chunk_set(c, cx + dx, base_y + dy, cz + dz, .Air)
			chunk_set(c, cx + dx, base_y - 1, cz + dz, .Snow)
			chunk_set(c, cx + dx, base_y + 3, cz + dz, .Snow)
		}
	}
	// doorway through the -z wall
	chunk_set(c, cx, base_y, cz - 2, .Door)
	chunk_set(c, cx, base_y + 1, cz - 2, .Air)
	w.doors[Ivec3{base_x + cx, base_y, base_z + cz - 2}] = Door{facing = 0, open = false}
	chunk_set(c, cx, base_y, cz + 1, .Bed) // a bed to sleep in
	chunk_set(c, cx, base_y + 2, cz, .Glowstone) // ceiling light
}

// A swamp hut: a small wood cabin raised on four stilts, walls with an entry
// gap, a plank roof, and a chest of loot inside.
@(private = "file")
build_swamp_hut :: proc(c: ^Chunk, cx, cz, base_y: int) {
	for cr in ([4][2]int{{-1, -1}, {1, -1}, {-1, 1}, {1, 1}}) {
		for dy in -2 ..= 0 do chunk_set(c, cx + cr[0], base_y + dy, cz + cr[1], .Wood) // stilts
	}
	for dx in -1 ..= 1 {
		for dz in -1 ..= 1 do chunk_set(c, cx + dx, base_y, cz + dz, .Planks) // floor
	}
	for dx in -1 ..= 1 {
		for dz in -1 ..= 1 {
			edge := abs(dx) == 1 || abs(dz) == 1
			if edge && !(dx == 0 && dz == -1) { 	// leave the -z centre open as a doorway
				chunk_set(c, cx + dx, base_y + 1, cz + dz, .Wood)
				chunk_set(c, cx + dx, base_y + 2, cz + dz, .Wood)
			}
		}
	}
	for dx in -1 ..= 1 {
		for dz in -1 ..= 1 do chunk_set(c, cx + dx, base_y + 3, cz + dz, .Planks) // roof
	}
	chunk_set(c, cx + 1, base_y + 1, cz + 1, .Chest) // loot
}
