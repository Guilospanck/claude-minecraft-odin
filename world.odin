package main

import "core:math"
import "core:slice"

World :: struct {
	chunks:      map[Ivec2]^Chunk,
	seed:        u64,
	mobs:        [dynamic]Mob,
	items:       [dynamic]Item,
	arrows:      [dynamic]Arrow,
	particles:   [dynamic]Particle,
	time_of_day: f32, // [0,1): 0=midnight, 0.25=sunrise, 0.5=noon, 0.75=sunset
}

// Set before sorting chunk work lists; the comparators read it (single-threaded).
g_center: Ivec2

world_init :: proc(w: ^World, seed: u64) {
	w.chunks = make(map[Ivec2]^Chunk)
	w.seed = seed
	w.mobs = make([dynamic]Mob, 0, MOB_CAP)
	w.items = make([dynamic]Item, 0, 64)
	w.arrows = make([dynamic]Arrow, 0, 32)
	w.particles = make([dynamic]Particle, 0, 128)
	w.time_of_day = 0.30 // start mid-morning
}

world_chunk_at :: proc(w: ^World, wx, wz: int) -> Ivec2 {
	return Ivec2{floor_div(wx, CHUNK_W), floor_div(wz, CHUNK_D)}
}

world_block :: proc(w: ^World, wx, wy, wz: int) -> BlockId {
	if wy < 0 || wy >= CHUNK_H do return .Air
	cx := floor_div(wx, CHUNK_W)
	cz := floor_div(wz, CHUNK_D)
	c, ok := w.chunks[Ivec2{cx, cz}]
	if !ok do return .Air
	lx := wx - cx * CHUNK_W
	lz := wz - cz * CHUNK_D
	return c.blocks[chunk_index(lx, wy, lz)]
}

// Dirty the full 8-neighbourhood: face neighbours share border faces, and
// diagonal neighbours are sampled by corner ambient-occlusion.
@(private = "file")
mark_neighbors_dirty :: proc(w: ^World, coord: Ivec2) {
	offs := [8]Ivec2 {
		{1, 0},
		{-1, 0},
		{0, 1},
		{0, -1},
		{1, 1},
		{1, -1},
		{-1, 1},
		{-1, -1},
	}
	for off in offs {
		if nc, ok := w.chunks[Ivec2{coord.x + off.x, coord.y + off.y}]; ok {
			nc.dirty = true
		}
	}
}

// Place a block at world coords and dirty the affected chunk(s).
world_set_block :: proc(w: ^World, wx, wy, wz: int, b: BlockId) {
	if wy < 0 || wy >= CHUNK_H do return
	cx := floor_div(wx, CHUNK_W)
	cz := floor_div(wz, CHUNK_D)
	c, ok := w.chunks[Ivec2{cx, cz}]
	if !ok do return
	lx := wx - cx * CHUNK_W
	lz := wz - cz * CHUNK_D
	c.blocks[chunk_index(lx, wy, lz)] = b
	c.dirty = true
	// border edits also dirty the adjacent chunk (shared faces)
	if lx == 0 do mark_dirty(w, Ivec2{cx - 1, cz})
	if lx == CHUNK_W - 1 do mark_dirty(w, Ivec2{cx + 1, cz})
	if lz == 0 do mark_dirty(w, Ivec2{cx, cz - 1})
	if lz == CHUNK_D - 1 do mark_dirty(w, Ivec2{cx, cz + 1})
	// corner edits also dirty the diagonal chunk (corner AO)
	if lx == 0 && lz == 0 do mark_dirty(w, Ivec2{cx - 1, cz - 1})
	if lx == 0 && lz == CHUNK_D - 1 do mark_dirty(w, Ivec2{cx - 1, cz + 1})
	if lx == CHUNK_W - 1 && lz == 0 do mark_dirty(w, Ivec2{cx + 1, cz - 1})
	if lx == CHUNK_W - 1 && lz == CHUNK_D - 1 do mark_dirty(w, Ivec2{cx + 1, cz + 1})
}

@(private = "file")
mark_dirty :: proc(w: ^World, coord: Ivec2) {
	if c, ok := w.chunks[coord]; ok {
		c.dirty = true
	}
}

// Load from disk or generate; returns the (now loaded) chunk.
world_ensure_chunk :: proc(w: ^World, coord: Ivec2) -> ^Chunk {
	if c, ok := w.chunks[coord]; ok do return c
	c: ^Chunk
	ok: bool
	// Clients always generate from the server seed and never touch the local
	// single-player save (which may belong to a different seed).
	if !net_is_client() {
		c, ok = load_chunk(coord)
	}
	if !ok {
		c = chunk_make(coord)
		worldgen_fill(c, w.seed)
	}
	c.generated = true
	c.dirty = true
	w.chunks[coord] = c
	mark_neighbors_dirty(w, coord)
	return c
}

@(private = "file")
dist2_to_center :: proc(coord: Ivec2) -> int {
	dx := coord.x - g_center.x
	dz := coord.y - g_center.y
	return dx * dx + dz * dz
}

// Generate nearby missing chunks (bounded) and save+free distant ones.
world_stream :: proc(w: ^World, cam: Vec3) {
	pc := world_chunk_at(w, int(math.floor(cam.x)), int(math.floor(cam.z)))
	g_center = pc

	load_r := g_settings.render_radius
	unload_r := load_r + 2

	// --- generate ---
	needed := make([dynamic]Ivec2, 0, 64)
	defer delete(needed)
	for dz in -load_r ..= load_r {
		for dx in -load_r ..= load_r {
			coord := Ivec2{pc.x + dx, pc.y + dz}
			if _, ok := w.chunks[coord]; !ok {
				append(&needed, coord)
			}
		}
	}
	slice.sort_by(needed[:], proc(a, b: Ivec2) -> bool {
		return dist2_to_center(a) < dist2_to_center(b)
	})
	made := 0
	for coord in needed {
		if made >= MAX_GEN_PER_FRAME do break
		world_ensure_chunk(w, coord)
		made += 1
	}

	// --- unload ---
	remove := make([dynamic]Ivec2, 0, 16)
	defer delete(remove)
	for coord, c in w.chunks {
		if abs(coord.x - pc.x) > unload_r || abs(coord.y - pc.y) > unload_r {
			_ = c
			append(&remove, coord)
		}
	}
	for coord in remove {
		c := w.chunks[coord]
		if !net_is_client() && !save_chunk(c) do continue // keep loaded, retry
		chunk_gl_free(c)
		chunk_free(c)
		delete_key(&w.chunks, coord)
	}
}

// Save every loaded chunk (used on quit). Clients don't own the local save.
world_save_all :: proc(w: ^World) {
	if net_is_client() do return
	for _, c in w.chunks {
		save_chunk(c)
	}
}
