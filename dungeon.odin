package main

import "core:math/linalg"

// Underground dungeons: a small mossy-cobblestone room holding a mob spawner and
// a loot chest or two, exactly like the ones tucked into Minecraft's caves. The
// spawner pumps out hostiles while the player is nearby, guarding the loot.

DUNGEON_CHANCE :: 70 // ~1 in this many chunks rolls a dungeon
DUNGEON_Y_MIN :: 12
DUNGEON_Y_MAX :: 40

SPAWNER_ACTIVATE :: f32(16) // the player must be within this for a spawner to run
SPAWNER_INTERVAL :: f32(4.5) // seconds between spawn attempts
SPAWNER_CAP :: 5 // stop once this many hostiles are already near
SPAWNER_NEAR :: f32(9) // radius used for the cap and for placing spawns

// Carve a dungeon room into the rock and stock it. Called per chunk from
// worldgen_fill with its own sparse roll, after every other generator so nothing
// overwrites the room.
generate_dungeon :: proc(w: ^World, c: ^Chunk, seed: u64, base_x, base_z: int, heights: []int) {
	hsh := hash_u64(
		seed ~
		(u64(i64(c.coord.x)) * 0x9E3779B1) ~
		(u64(i64(c.coord.y)) * 0xC2B2AE35) ~
		0xD1CE_D00D,
	)
	if hsh % DUNGEON_CHANCE != 0 do return

	cx := 4 + int((hsh >> 8) % 8) // [4,11] — keeps the ±3 room inside the chunk
	cz := 4 + int((hsh >> 12) % 8)
	surf := heights[cx + cz * CHUNK_W]
	if surf < SEA_LEVEL + 4 do return // skip oceans/low ground; keep it well underground

	y := clamp(surf - 10 - int((hsh >> 16) % 18), DUNGEON_Y_MIN, DUNGEON_Y_MAX)
	if y + 5 >= surf do return // needs solid rock overhead

	mossy :: proc(hsh: u64, k: uint) -> BlockId {
		return ((hsh >> (k %% 40)) & 7) < 2 ? .MossyCobble : .Cobblestone
	}
	// shell of cobble (some mossy) with a hollow interior
	for dx in -3 ..= 3 do for dz in -3 ..= 3 do for dy in 0 ..= 4 {
		edge := abs(dx) == 3 || abs(dz) == 3 || dy == 0 || dy == 4
		if edge {
			chunk_set(c, cx + dx, y + dy, cz + dz, mossy(hsh, uint((dx + 3) * 7 + (dz + 3))))
		} else {
			chunk_set(c, cx + dx, y + dy, cz + dz, .Air)
		}
	}
	// the spawner on the floor at the centre
	chunk_set(c, cx, y + 1, cz, .Spawner)
	w.spawners[Ivec3{base_x + cx, y + 1, base_z + cz}] = 1.5

	dungeon_chest(w, c, base_x, base_z, cx - 2, y + 1, cz - 2, hsh)
	if (hsh >> 24) & 1 == 0 do dungeon_chest(w, c, base_x, base_z, cx + 2, y + 1, cz + 2, hsh >> 5)
}

// A loot chest of the odds-and-ends a dungeon rewards: food, ores, bones, the
// occasional gold or diamond.
@(private = "file")
dungeon_chest :: proc(w: ^World, c: ^Chunk, base_x, base_z, x, y, z: int, hsh: u64) {
	chunk_set(c, x, y, z, .Chest)
	ch: Chest
	loot := [?]ItemStack {
		{.Bread, 2 + int(hsh % 3)},
		{.Iron, 1 + int((hsh >> 3) % 3)},
		{.CoalOre, 2 + int((hsh >> 6) % 4)},
		{.Bone, int((hsh >> 9) % 3)},
		{.Gunpowder, int((hsh >> 12) % 3)},
		{.Gold, int((hsh >> 15) % 2)},
	}
	si := 0
	for it in loot {
		if it.count > 0 {ch.slots[si] = it;si += 1}
	}
	if (hsh >> 20) % 6 == 0 {ch.slots[si] = {.DiamondOre, 1};si += 1} // rare diamond
	w.chests[Ivec3{base_x + x, y, base_z + z}] = ch
}

// Register any spawner blocks in a freshly loaded/generated chunk so they run
// whether the chunk was just built or restored from disk. Scans only the shallow
// dungeon band, not the whole column.
spawners_register_chunk :: proc(w: ^World, c: ^Chunk) {
	bx := c.coord.x * CHUNK_W
	bz := c.coord.y * CHUNK_D
	for lx in 0 ..< CHUNK_W do for lz in 0 ..< CHUNK_D do for y in DUNGEON_Y_MIN ..= DUNGEON_Y_MAX + 1 {
		if chunk_get(c, lx, y, lz) == .Spawner {
			pos := Ivec3{bx + lx, y, bz + lz}
			if _, ok := w.spawners[pos]; !ok do w.spawners[pos] = 1.5
		}
	}
}

// Tick every spawner near the player, spitting out hostiles up to a local cap.
spawners_update :: proc(w: ^World, p: ^Player, dt: f32) {
	if net_is_client() do return
	if len(w.spawners) == 0 do return

	// Snapshot the keys so we can freely reassign / delete inside the loop.
	keys := make([dynamic]Ivec3, 0, len(w.spawners), context.temp_allocator)
	for pos, _ in w.spawners do append(&keys, pos)

	for pos in keys {
		cd := w.spawners[pos]
		pc := Vec3{f32(pos.x) + 0.5, f32(pos.y) + 0.5, f32(pos.z) + 0.5}
		if linalg.length(p.pos - pc) > SPAWNER_ACTIVATE do continue

		if world_block(w, pos.x, pos.y, pos.z) != .Spawner {
			delete_key(&w.spawners, pos) // mined out
			continue
		}
		if cd - dt > 0 {
			w.spawners[pos] = cd - dt
			continue
		}

		near := 0
		for &m in w.mobs {
			if mob_is_hostile(m.kind) && linalg.length(m.pos - pc) < SPAWNER_NEAR do near += 1
		}
		if near < SPAWNER_CAP do spawner_try_spawn(w, pos)
		w.spawners[pos] = SPAWNER_INTERVAL
	}
}

// Try a few random cells around the spawner for a standable air gap and drop a
// zombie or skeleton there.
@(private = "file")
spawner_try_spawn :: proc(w: ^World, pos: Ivec3) {
	kind := rng_int(2) == 0 ? MobKind.Zombie : MobKind.Skeleton
	for _ in 0 ..< 8 {
		ox := pos.x + rng_int(5) - 2
		oy := pos.y + rng_int(3) - 1
		oz := pos.z + rng_int(5) - 2
		if world_block(w, ox, oy, oz) == .Air &&
		   world_block(w, ox, oy + 1, oz) == .Air &&
		   block_is_solid(world_block(w, ox, oy - 1, oz)) {
			append(
				&w.mobs,
				Mob{kind = kind, pos = Vec3{f32(ox) + 0.5, f32(oy), f32(oz) + 0.5}, health = 12},
			)
			return
		}
	}
}
