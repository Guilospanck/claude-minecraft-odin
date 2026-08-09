package main

import "core:math"
import "core:slice"

Dimension :: enum {
	Overworld,
	Nether,
}

World :: struct {
	chunks:      map[Ivec2]^Chunk,
	seed:        u64,
	dimension:   Dimension,
	mobs:        [dynamic]Mob,
	items:       [dynamic]Item,
	xp_orbs:     [dynamic]XpOrb, // floating experience orbs dropped by kills
	falling:     [dynamic]FallingBlock, // gravel/sand mid-fall
	meteors:     [dynamic]Meteor, // burning rocks streaking down from the sky
	spawners:    map[Ivec3]f32, // dungeon mob-spawner positions → spawn cooldown
	arrows:      [dynamic]Arrow,
	particles:   [dynamic]Particle,
	crops:       [dynamic]Crop, // growing wheat being ticked toward ripeness
	chests:      map[Ivec3]Chest, // placed storage keyed by world position
	doors:       map[Ivec3]Door, // door facing/open state keyed by world position
	stairs:      map[Ivec3]u8, // stair facing (0..3) keyed by world position
	villagers:   [dynamic]Villager,
	villages:    [dynamic]Village,
	time_of_day: f32, // [0,1): 0=midnight, 0.25=sunrise, 0.5=noon, 0.75=sunset
	raining:      bool, // overworld-only: a weather event is active (see weather_tick)
	storm_level:  int, // 1=light, 2=normal, 3=heavy — set when a spell begins
	active_precip: Precip, // what's actually falling on the player this frame (for render)
	flash:        f32, // lightning flash intensity (thunderstorms), decays to 0
	weather_timer: f32, // seconds until the current weather state re-rolls
	wind_x, wind_z: f32, // slowly drifting wind vector; blows precipitation sideways
	cloud_time:    f32, // monotonic accumulator that scrolls the cloud layer
	// Smoothed sky/cloud look: eased toward the local biome+weather target each
	// frame so crossing a biome edge fades over a couple seconds, not instantly.
	sky_tint:      Vec4, // horizon-haze tint (rgb + blend strength)
	cloud_col:     Vec3,
	cloud_cover:   f32,
	cloud_alpha:   f32,
	sky_inited:    bool, // false until the smoothing state is seeded (snap on first frame)
}

// Set before sorting chunk work lists; the comparators read it (single-threaded).
g_center: Ivec2

world_init :: proc(w: ^World, seed: u64, dim: Dimension = .Overworld) {
	w.chunks = make(map[Ivec2]^Chunk)
	w.seed = seed
	w.dimension = dim
	w.mobs = make([dynamic]Mob, 0, 32)
	w.items = make([dynamic]Item, 0, 64)
	w.xp_orbs = make([dynamic]XpOrb, 0, 32)
	w.falling = make([dynamic]FallingBlock, 0, 16)
	w.meteors = make([dynamic]Meteor, 0, 4)
	w.spawners = make(map[Ivec3]f32)
	w.arrows = make([dynamic]Arrow, 0, 32)
	w.particles = make([dynamic]Particle, 0, 128)
	w.crops = make([dynamic]Crop, 0, 32)
	w.chests = make(map[Ivec3]Chest)
	w.doors = make(map[Ivec3]Door)
	w.stairs = make(map[Ivec3]u8)
	w.villagers = make([dynamic]Villager, 0, 16)
	w.villages = make([dynamic]Village, 0, 4)
	w.time_of_day = 0.30 // start mid-morning
	w.weather_timer = rng_range(WEATHER_DRY_MIN, WEATHER_DRY_MAX)
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
		c, ok = load_chunk(coord, w.dimension)
	}
	if !ok {
		c = chunk_make(coord)
		if w.dimension == .Nether {
			worldgen_nether(c, w.seed)
		} else {
			worldgen_fill(w, c, w.seed)
		}
	}
	c.generated = true
	c.dirty = true
	w.chunks[coord] = c
	if !net_is_client() do spawners_register_chunk(w, c) // pick up dungeon spawners
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
		if !net_is_client() && !save_chunk(c, w.dimension) do continue // keep loaded, retry
		chunk_gl_free(c)
		chunk_free(c)
		delete_key(&w.chunks, coord)
	}
}

// Save every loaded chunk (used on quit). Clients don't own the local save.
world_save_all :: proc(w: ^World) {
	if net_is_client() do return
	for _, c in w.chunks {
		save_chunk(c, w.dimension)
	}
}
