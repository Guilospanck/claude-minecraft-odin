package main

import "core:fmt"
import "core:os"

// Doors: an interactable BlockId.Door whose facing/open state lives outside
// the single BlockId enum, keyed by world position — the same pattern as
// Chest (see chest.odin). Toggling is an instant state swap (mark the chunk
// dirty, remesh with different box extents), not a smooth multi-frame
// swing: real-time animation would need doors to become dynamic per-frame
// props like mobs/items instead of static chunk-baked geometry, a bigger
// lift for a purely cosmetic difference. The open/closed silhouettes are
// still visually distinct, which is what "interactable" and "animated
// (open/closed)" are actually asking for.

Door :: struct {
	facing: int, // 0: base orientation spans the X axis; 1: spans Z
	open:   bool,
}

// Box extents (x0,x1,z0,z1) for a door's thin slab, in [0,1] local cell
// space: closed fills the doorway along its facing axis; open rotates 90°
// around the (0,0) corner (the hinge) to hug the perpendicular wall instead.
door_extents :: proc(d: Door) -> (x0, x1, z0, z1: f32) {
	spans_x := (d.facing == 0) != d.open
	if spans_x do return 0, 1, 0, 0.15
	return 0, 0.15, 0, 1
}

// Toggle the door at pos (create it, closed, facing X, if this is the first
// interaction with a door that predates world.doors tracking it). Re-setting
// the same BlockId piggybacks on world_set_block's existing neighbor-aware
// dirty-marking so the mesher picks up the new open/closed extents without
// duplicating that logic here.
door_toggle :: proc(w: ^World, pos: Ivec3) {
	if net_is_client() {
		toast_show("DOORS ARE HOST-ONLY IN MULTIPLAYER")
		return
	}
	d, ok := w.doors[pos]
	if !ok do d = Door{}
	d.open = !d.open
	w.doors[pos] = d
	world_set_block(w, pos.x, pos.y, pos.z, .Door)
	audio_play(d.open ? .Place : .Break, 0.3)
}

// ---- persistence (one file per dimension, mirrors chest.odin exactly) ----
@(private = "file")
doors_path :: proc(dim: Dimension) -> string {
	return fmt.tprintf("%s/doors.dat", dim == .Nether ? NETHER_DIR : WORLD_DIR)
}

@(private = "file")
put_i32 :: proc(buf: ^[dynamic]u8, v: i32) {
	u := u32(v)
	append(buf, u8(u), u8(u >> 8), u8(u >> 16), u8(u >> 24))
}

@(private = "file")
get_i32 :: proc(data: []u8, off: int) -> i32 {
	return i32(
		u32(data[off]) |
		u32(data[off + 1]) << 8 |
		u32(data[off + 2]) << 16 |
		u32(data[off + 3]) << 24,
	)
}

// Format: [count i32] then per door [x y z i32][facing u8][open u8]
save_doors :: proc(w: ^World) {
	if net_is_client() do return
	if len(w.doors) == 0 {
		os.remove(doors_path(w.dimension)) // no doors: drop any stale file
		return
	}
	save_ensure_dir(w.dimension)
	buf := make([dynamic]u8, 0, 128)
	defer delete(buf)
	put_i32(&buf, i32(len(w.doors)))
	for pos, d in w.doors {
		put_i32(&buf, i32(pos.x))
		put_i32(&buf, i32(pos.y))
		put_i32(&buf, i32(pos.z))
		append(&buf, u8(d.facing), u8(d.open ? 1 : 0))
	}
	if err := os.write_entire_file(doors_path(w.dimension), buf[:]); err != nil {
		fmt.eprintln("save_doors failed:", err)
	}
}

load_doors :: proc(w: ^World) {
	if net_is_client() do return
	path := doors_path(w.dimension)
	if !os.exists(path) do return
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return
	defer delete(data)

	off := 0
	if len(data) < 4 do return
	count := int(get_i32(data, off));off += 4
	for _ in 0 ..< count {
		if off + 14 > len(data) do return
		x := int(get_i32(data, off));off += 4
		y := int(get_i32(data, off));off += 4
		z := int(get_i32(data, off));off += 4
		facing := int(data[off]);off += 1
		open := data[off] != 0;off += 1
		w.doors[Ivec3{x, y, z}] = Door{facing = facing, open = open}
	}
}
