package main

import "core:fmt"
import "core:os"

WORLD_DIR :: "saves/world" // overworld chunks + meta
NETHER_DIR :: "saves/nether" // nether chunks

// Each dimension gets its own directory so chunks at the same (x,z) never
// collide on disk.
@(private = "file")
dim_dir :: proc(dim: Dimension) -> string {
	return dim == .Nether ? NETHER_DIR : WORLD_DIR
}

save_ensure_dir :: proc(dim: Dimension = .Overworld) {
	if !os.exists("saves") do os.make_directory("saves")
	d := dim_dir(dim)
	if !os.exists(d) do os.make_directory(d)
}

@(private = "file")
chunk_path :: proc(coord: Ivec2, dim: Dimension) -> string {
	return fmt.tprintf("%s/%d_%d.chunk", dim_dir(dim), coord.x, coord.y)
}

// Run-length encode the block array: [id u8][run u16 little-endian] records.
// Returns false (and logs) if the write failed, so callers can avoid dropping
// the chunk's edits.
// A stamp written at the head of every chunk file. Bump it whenever a worldgen
// change should force already-saved chunks to REGENERATE (they no longer match
// the current generator) — old files lack the current stamp and are rejected on
// load, so the world rebuilds them. Bumped to 2 to flush pre-fix chunks that
// held half-drowned villages / stale terrain.
CHUNK_SAVE_MAGIC :: u8(0xC0)
CHUNK_SAVE_VERSION :: u8(4)

save_chunk :: proc(c: ^Chunk, dim: Dimension) -> bool {
	save_ensure_dir(dim)
	buf := make([dynamic]u8, 0, 4096)
	defer delete(buf)
	append(&buf, CHUNK_SAVE_MAGIC, CHUNK_SAVE_VERSION) // format stamp (see above)

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
	if err := os.write_entire_file(chunk_path(c.coord, dim), buf[:]); err != nil {
		fmt.eprintln("save_chunk failed:", chunk_path(c.coord, dim), err)
		return false
	}
	return true
}

load_chunk :: proc(coord: Ivec2, dim: Dimension) -> (^Chunk, bool) {
	path := chunk_path(coord, dim)
	if !os.exists(path) do return nil, false
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return nil, false
	defer delete(data)

	// Reject any file that doesn't carry the current format stamp (including
	// pre-stamp saves, whose first bytes won't match) so it regenerates.
	if len(data) < 2 || data[0] != CHUNK_SAVE_MAGIC || data[1] != CHUNK_SAVE_VERSION {
		return nil, false
	}

	c := chunk_make(coord)
	i := 2
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
		chunk_free(c)
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
	if err := os.write_entire_file(fmt.tprintf("%s/meta", WORLD_DIR), buf[:]); err != nil {
		fmt.eprintln("save_meta failed:", err)
	}
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

@(private = "file")
PLAYER_PATH :: "saves/player.dat"
@(private = "file")
PLAYER_SAVE_VERSION :: u8(4)

// Persist the player's own state (position, look, vitals, respawn, the full
// inventory + food counters, the hotbar layout, and tool/armor tiers +
// durability) so a saved world comes back exactly as you left it. Version-
// tagged so a format change just falls back to a fresh player instead of
// loading garbage.
save_player :: proc(p: ^Player) {
	if net_is_client() do return
	save_ensure_dir()
	buf := make([dynamic]u8, 0, 256)
	defer delete(buf)

	append(&buf, PLAYER_SAVE_VERSION)
	put_f32(&buf, p.pos.x);put_f32(&buf, p.pos.y);put_f32(&buf, p.pos.z)
	put_f32(&buf, p.yaw);put_f32(&buf, p.pitch)
	put_i32(&buf, i32(p.health))
	put_f32(&buf, p.hunger);put_f32(&buf, p.oxygen)
	put_f32(&buf, p.respawn.x);put_f32(&buf, p.respawn.y);put_f32(&buf, p.respawn.z)
	put_i32(&buf, i32(p.selected_slot))
	for k in ToolKind {put_i32(&buf, i32(p.tool_tier[k]));put_i32(&buf, i32(p.tool_dur[k]))}
	for s in ArmorSlot {put_i32(&buf, i32(p.armor_tier[s]));put_i32(&buf, i32(p.armor_dur[s]))}

	// the fixed-slot inventory: one (id, count) pair per slot, positions kept
	put_i32(&buf, i32(INV_SLOTS))
	for s in p.slots {append(&buf, u8(s.id));put_i32(&buf, i32(s.count))}

	// experience: current level + points banked toward the next one
	put_i32(&buf, i32(p.xp_level));put_i32(&buf, i32(p.xp_points))

	if err := os.write_entire_file(PLAYER_PATH, buf[:]); err != nil {
		fmt.eprintln("save_player failed:", err)
	}
}

// Restore a saved player over an already-initialised one. Returns false (and
// leaves p untouched) if there's no save, it's truncated, or the version
// doesn't match.
load_player :: proc(p: ^Player) -> bool {
	if net_is_client() do return false
	if !os.exists(PLAYER_PATH) do return false
	data, err := os.read_entire_file(PLAYER_PATH, context.allocator)
	if err != nil do return false
	defer delete(data)
	if len(data) < 1 || data[0] != PLAYER_SAVE_VERSION do return false

	off := 1
	// bounds helper: every read below is guarded so a truncated file can't panic
	need :: proc(off, n, total: int) -> bool {return off + n <= total}

	if !need(off, 5 * 4, len(data)) do return false
	p.pos.x = get_f32(data, off);off += 4
	p.pos.y = get_f32(data, off);off += 4
	p.pos.z = get_f32(data, off);off += 4
	p.yaw = get_f32(data, off);off += 4
	p.pitch = get_f32(data, off);off += 4
	if !need(off, 4 + 2 * 4 + 3 * 4 + 1, len(data)) do return false
	p.health = int(get_i32(data, off));off += 4
	p.hunger = get_f32(data, off);off += 4
	p.oxygen = get_f32(data, off);off += 4
	p.respawn.x = get_f32(data, off);off += 4
	p.respawn.y = get_f32(data, off);off += 4
	p.respawn.z = get_f32(data, off);off += 4
	if !need(off, 4, len(data)) do return false
	p.selected_slot = int(get_i32(data, off));off += 4
	for k in ToolKind {
		if !need(off, 8, len(data)) do return false
		p.tool_tier[k] = int(get_i32(data, off));off += 4
		p.tool_dur[k] = int(get_i32(data, off));off += 4
	}
	for s in ArmorSlot {
		if !need(off, 8, len(data)) do return false
		p.armor_tier[s] = int(get_i32(data, off));off += 4
		p.armor_dur[s] = int(get_i32(data, off));off += 4
	}
	if !need(off, 4, len(data)) do return false
	count := int(get_i32(data, off));off += 4
	p.slots = {}
	for i in 0 ..< count {
		if !need(off, 5, len(data)) do return false
		id := BlockId(data[off]);off += 1
		cnt := int(get_i32(data, off));off += 4
		if i < INV_SLOTS do p.slots[i] = {id, cnt}
	}
	if !need(off, 8, len(data)) do return false
	p.xp_level = int(get_i32(data, off));off += 4
	p.xp_points = int(get_i32(data, off));off += 4
	p.selected_slot = clamp(p.selected_slot, 0, HOTBAR_SLOTS - 1)
	return true
}

@(private = "file")
stairs_path :: proc(dim: Dimension) -> string {
	return fmt.tprintf("%s/stairs.dat", dim_dir(dim))
}

// Persist placed stairs' facings (village-built and player-placed alike),
// keyed by world position, mirroring how doors are saved.
save_stairs :: proc(w: ^World) {
	if net_is_client() do return
	if len(w.stairs) == 0 {
		os.remove(stairs_path(w.dimension))
		return
	}
	save_ensure_dir(w.dimension)
	buf := make([dynamic]u8, 0, 128)
	defer delete(buf)
	put_i32(&buf, i32(len(w.stairs)))
	for pos, facing in w.stairs {
		put_i32(&buf, i32(pos.x));put_i32(&buf, i32(pos.y));put_i32(&buf, i32(pos.z))
		append(&buf, facing)
	}
	if err := os.write_entire_file(stairs_path(w.dimension), buf[:]); err != nil {
		fmt.eprintln("save_stairs failed:", err)
	}
}

load_stairs :: proc(w: ^World) {
	if net_is_client() do return
	path := stairs_path(w.dimension)
	if !os.exists(path) do return
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return
	defer delete(data)
	off := 0
	if len(data) < 4 do return
	count := int(get_i32(data, off));off += 4
	for _ in 0 ..< count {
		if off + 13 > len(data) do return
		x := int(get_i32(data, off));off += 4
		y := int(get_i32(data, off));off += 4
		z := int(get_i32(data, off));off += 4
		w.stairs[Ivec3{x, y, z}] = data[off];off += 1
	}
}
