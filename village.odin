package main

import "core:math"

// Villages: small hamlets constrained to fit inside a single chunk (this
// codebase's terrain generator only ever decorates the chunk it's currently
// generating — see generate_trees — so staying single-chunk avoids building
// a whole new cross-chunk structure-planning subsystem for what's meant to
// be a handful of houses). Placement is a deterministic sparse hash roll
// per chunk, gated on a calm biome and low height variance so houses don't
// end up straddling a cliff.

Village :: struct {
	center: Ivec3,
	houses: int,
}

// Roughly 1 in this many chunks qualifies as a village site (before the
// biome/flatness gates below narrow it further).
VILLAGE_CHANCE :: 350

// Not file-private: tests exercise it directly.
village_biome_ok :: proc(b: Biome) -> bool {
	#partial switch b {
	case .Plains, .Forest, .Savanna:
		return true
	}
	return false
}

// Walls + roof + a door opening + a window, the same "direct chunk_set
// calls against the chunk being generated" approach place_tree already uses
// for trees — no new placement infrastructure needed.
// Not file-private: tests exercise it directly.
generate_house :: proc(w: ^World, c: ^Chunk, base_x, base_z, lx, lz, surf_y: int) {
	SIZE :: 5
	HEIGHT :: 3
	base_y := surf_y + 1

	for dx in 0 ..< SIZE {
		for dz in 0 ..< SIZE {
			edge := dx == 0 || dx == SIZE - 1 || dz == 0 || dz == SIZE - 1
			if !edge do continue
			for dy in 0 ..< HEIGHT {
				chunk_set(c, lx + dx, base_y + dy, lz + dz, .Wood)
			}
		}
	}
	for dx in 0 ..< SIZE {
		for dz in 0 ..< SIZE {
			chunk_set(c, lx + dx, base_y + HEIGHT, lz + dz, .Wood) // flat roof
		}
	}
	for dx in 1 ..< SIZE - 1 {
		for dz in 1 ..< SIZE - 1 {
			for dy in 0 ..< HEIGHT {
				chunk_set(c, lx + dx, base_y + dy, lz + dz, .Air) // hollow interior
			}
		}
	}

	door_lx := lx + SIZE / 2
	door_lz := lz // centred on the south wall
	chunk_set(c, door_lx, base_y, door_lz, .Door)
	chunk_set(c, door_lx, base_y + 1, door_lz, .Air) // headroom
	w.doors[Ivec3{base_x + door_lx, base_y, base_z + door_lz}] = Door{facing = 0, open = false}

	win_lx := lx + SIZE / 2
	win_lz := lz + SIZE - 1 // opposite wall
	chunk_set(c, win_lx, base_y + 1, win_lz, .Glass)
}

// Called once per generated chunk (from worldgen_fill, after everything
// else so a house always wins over a tree that happened to land on the
// same columns). Places up to 2 houses, a couple of villagers who live
// there, and a couple of farm animals — the animals bypass the biome/
// resource spawn gate in entity.odin's mob_try_spawn, since the village
// itself is their food and water source.
generate_village :: proc(w: ^World, c: ^Chunk, seed: u64, base_x, base_z: int, heights: []int, biomes: []Biome) {
	hsh :=
		hash_u64(
			seed ~
			(u64(i64(c.coord.x)) * 0x9E3779B1) ~
			(u64(i64(c.coord.y)) * 0x85EBCA77) ~
			0xF00D_FACE,
		)
	if hsh % VILLAGE_CHANCE != 0 do return

	if !village_biome_ok(biomes[8 + 8 * CHUNK_W]) do return

	lo, hi := heights[0], heights[0]
	for lz in 2 ..< 14 {
		for lx in 2 ..< 14 {
			hh := heights[lx + lz * CHUNK_W]
			lo = min(lo, hh)
			hi = max(hi, hh)
		}
	}
	if hi - lo > 5 do return // too hilly for a tidy village

	house_pos := [2][2]int{{2, 2}, {9, 9}}
	for hp in house_pos {
		lx, lz := hp[0], hp[1]
		surf_y := heights[(lx + 2) + (lz + 2) * CHUNK_W] // sample near the house's centre
		generate_house(w, c, base_x, base_z, lx, lz, surf_y)
	}

	center_y := heights[8 + 8 * CHUNK_W]
	center := Ivec3{base_x + 8, center_y + 1, base_z + 8}
	append(&w.villages, Village{center = center, houses = len(house_pos)})

	n_villagers := 2 + rng_int(3) // 2..4
	for i in 0 ..< n_villagers {
		sy := heights[5 + 5 * CHUNK_W]
		append(
			&w.villagers,
			Villager {
				pos = Vec3{f32(base_x + 5) + f32(i) * 0.6, f32(sy + 1), f32(base_z + 5)},
				yaw = rng_range(0, 2 * math.PI),
				health = 10,
				name = villager_pick_name(hsh + u64(i) + 1),
				home = center,
			},
		)
	}

	animal_kinds := [3]MobKind{.Cow, .Sheep, .Chicken}
	n_animals := 2 + rng_int(2) // 2..3
	for i in 0 ..< n_animals {
		sy := heights[12 + 3 * CHUNK_W]
		append(
			&w.mobs,
			Mob {
				kind = animal_kinds[rng_int(3)],
				pos = Vec3{f32(base_x + 12) + f32(i) * 0.7, f32(sy + 1), f32(base_z + 3)},
				yaw = rng_range(0, 2 * math.PI),
				ai_timer = rng_range(0, 2),
				health = 6,
			},
		)
	}
}
