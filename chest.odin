package main

import "core:fmt"
import "core:os"

// Chests: placeable storage keyed by world position, per dimension. Contents are
// block counts (a mini inventory). Opened with R; deposit a hotbar item with its
// number key, withdraw everything with R again. Persisted to a per-dimension
// file so a chest keeps its contents across restarts.

Chest :: struct {
	items: [BlockId]int,
}

g_show_chest: bool
g_chest_pos: Ivec3

// Open (or lazily create) the chest at pos in world w. Chests are host-only in
// multiplayer: their contents are neither networked nor saved on a client, so a
// client deposit would zero the inventory into a black hole.
chest_open :: proc(w: ^World, pos: Ivec3) {
	if net_is_client() {
		toast_show("CHESTS ARE HOST-ONLY IN MULTIPLAYER")
		return
	}
	if _, ok := w.chests[pos]; !ok {
		w.chests[pos] = Chest{}
	}
	g_chest_pos = pos
	g_show_chest = true
	g_show_inventory = false
	g_show_settings = false
	audio_play(.Place, 0.35)
}

// Move every unit of block b from the player into the open chest.
chest_deposit :: proc(w: ^World, p: ^Player, b: BlockId) {
	if net_is_client() do return
	if b == .Air do return
	n := inv_count(p, b)
	if n <= 0 do return
	ch, ok := w.chests[g_chest_pos]
	if !ok do return
	ch.items[b] += n
	w.chests[g_chest_pos] = ch
	inv_remove_all(p, b)
	toast_show(fmt.tprintf("STORED %d %s", n, block_name(b)))
	audio_play(.Place, 0.4)
}

// Move all contents of the open chest into the player's inventory.
chest_withdraw_all :: proc(w: ^World, p: ^Player) {
	if net_is_client() do return
	ch, ok := w.chests[g_chest_pos]
	if !ok do return
	moved := 0
	for b in BlockId {
		moved += ch.items[b]
		inv_add(p, b, ch.items[b])
		ch.items[b] = 0
	}
	w.chests[g_chest_pos] = ch
	if moved > 0 {
		toast_show(fmt.tprintf("TOOK %d ITEMS FROM THE CHEST", moved))
		audio_play(.Place, 0.4)
	}
}

// Empty a broken chest straight into the player's inventory, then forget it.
chest_break :: proc(w: ^World, p: ^Player, pos: Ivec3) {
	if ch, ok := w.chests[pos]; ok {
		for b in BlockId do inv_add(p, b, ch.items[b])
		delete_key(&w.chests, pos)
	}
	if g_show_chest && g_chest_pos == pos do g_show_chest = false
}

// ---- persistence (one file per dimension) ----
@(private = "file")
chests_path :: proc(dim: Dimension) -> string {
	return fmt.tprintf("%s/chests.dat", dim == .Nether ? NETHER_DIR : WORLD_DIR)
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

// Format: [count i32] then per chest [x y z i32][nEntries i32] then nEntries*[block u8][count i32]
save_chests :: proc(w: ^World) {
	if net_is_client() do return
	if len(w.chests) == 0 {
		os.remove(chests_path(w.dimension)) // no chests: drop any stale file
		return
	}
	save_ensure_dir(w.dimension)
	buf := make([dynamic]u8, 0, 256)
	defer delete(buf)
	put_i32(&buf, i32(len(w.chests)))
	for pos, ch in w.chests {
		put_i32(&buf, i32(pos.x))
		put_i32(&buf, i32(pos.y))
		put_i32(&buf, i32(pos.z))
		n := 0
		for b in BlockId do if ch.items[b] > 0 do n += 1
		put_i32(&buf, i32(n))
		for b in BlockId {
			if ch.items[b] > 0 {
				append(&buf, u8(b))
				put_i32(&buf, i32(ch.items[b]))
			}
		}
	}
	if err := os.write_entire_file(chests_path(w.dimension), buf[:]); err != nil {
		fmt.eprintln("save_chests failed:", err)
	}
}

load_chests :: proc(w: ^World) {
	if net_is_client() do return
	path := chests_path(w.dimension)
	if !os.exists(path) do return
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return
	defer delete(data)

	off := 0
	if len(data) < 4 do return
	count := int(get_i32(data, off));off += 4
	for _ in 0 ..< count {
		if off + 16 > len(data) do return
		x := int(get_i32(data, off));off += 4
		y := int(get_i32(data, off));off += 4
		z := int(get_i32(data, off));off += 4
		n := int(get_i32(data, off));off += 4
		ch: Chest
		for _ in 0 ..< n {
			if off + 5 > len(data) do return
			raw := data[off];off += 1
			cnt := int(get_i32(data, off));off += 4
			// guard against a corrupt/tampered file: skip out-of-range block ids
			if raw != u8(BlockId.Air) && raw <= u8(max(BlockId)) {
				ch.items[BlockId(raw)] = cnt
			}
		}
		w.chests[Ivec3{x, y, z}] = ch
	}
}
