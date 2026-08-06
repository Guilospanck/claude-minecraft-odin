package main

import "core:math"

// Villages: small hamlets constrained to fit inside a single chunk (this
// codebase's terrain generator only ever decorates the chunk it's currently
// generating — see generate_trees — so staying single-chunk avoids building
// a whole new cross-chunk structure-planning subsystem). A village lays out
// a 2x2 grid of 7x7 plots (two house styles, a church, a fenced farm) and
// gives each resident a role tied to their own building instead of being an
// interchangeable wanderer — see Profession in villager.odin. Placement is
// a deterministic sparse hash roll per chunk, gated on a calm biome and low
// height variance across the whole layout so buildings don't straddle a
// cliff.

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
	case .Plains, .Forest, .Savanna, .Meadow, .Taiga, .Snow, .Desert:
		return true
	}
	return false
}

// Per-biome building palette, so a village looks like it belongs where it sits:
// snowy villages get white roofs, deserts get sand walls, taiga log cabins, and
// so on, instead of the same grey-stone cottage everywhere.
BuildMats :: struct {
	wall: BlockId,
	roof: BlockId,
}

// Not file-private: tests exercise it directly.
biome_build_mats :: proc(b: Biome) -> BuildMats {
	#partial switch b {
	case .Snow, .Taiga:
		return {.Wood, .Snow} // log cabins under snow-laden roofs
	case .Desert, .Badlands:
		return {.Sand, .Wood} // sand-brick walls, timber roofs
	case .Savanna:
		return {.Wood, .Wood} // all-timber
	}
	return {.Wood, .Stone} // temperate default
}

// A tapering square roof/spire: radii[i] is the half-width at layer
// base_y+i, so e.g. {3,2,1,0} makes a 7x7 -> 5x5 -> 3x3 -> 1x1 pyramid.
// Shared by house roofs and the church spire (a longer, thinner radii list)
// instead of two copies of the same nested-loop shape. The base course
// (the widest layer, where the roof actually meets the walls) is laid in
// Slab instead of full blocks — a real half-height eave line instead of a
// blocky step, now that Slab exists as a real partial-height shape.
@(private = "file")
place_tapering_roof :: proc(c: ^Chunk, cx, base_y, cz: int, radii: []int, material: BlockId) {
	for i in 0 ..< len(radii) {
		r := radii[i]
		y := base_y + i
		layer_material := i == 0 ? BlockId.Slab : material
		for dz in -r ..= r {
			for dx in -r ..= r {
				if r > 1 && abs(dx) == r && abs(dz) == r do continue // clip corners
				chunk_set(c, cx + dx, y, cz + dz, layer_material)
			}
		}
	}
}

// Fill a solid pedestal under a building footprint so it never floats over
// sloping ground. Each plot builds from a single plot-centre height, but the
// columns around that centre sit at their own (often lower) terrain heights,
// and even a flat plot leaves a one-block gap because the foundation course is
// laid one block above the surface. For every column the structure plus its
// fenced yard covers, this stacks Stone from that column's own surface up to
// just below base_y (the foundation-course level). Columns whose own ground is
// already at/above base_y are left untouched — the building beds into the
// hillside there instead of floating. Run BEFORE the building so the building's
// own blocks (well water, farmland, door) always win on the cells they share.
// Not file-private: tests exercise it directly.
place_foundation :: proc(c: ^Chunk, heights: []int, lx0, lz0, lx1, lz1, base_y: int) {
	for lz in lz0 ..= lz1 {
		for lx in lx0 ..= lx1 {
			if lx < 0 || lz < 0 || lx >= CHUNK_W || lz >= CHUNK_D do continue
			ground := heights[lx + lz * CHUNK_W] // first air cell above the terrain
			for y in ground ..< base_y {
				chunk_set(c, lx, y, lz, .Stone)
			}
		}
	}
}

// A fenced square perimeter with a single-cell gap (the entrance), used for
// house yards, the churchyard, and the farm plot boundary.
@(private = "file")
place_fence_ring :: proc(c: ^Chunk, lx0, lz0, size, y, gap_lx, gap_lz: int) {
	for i in 0 ..< size {
		at :: proc(c: ^Chunk, x, y, z, gap_x, gap_z: int) {
			if x == gap_x && z == gap_z do return
			chunk_set(c, x, y, z, .Fence)
		}
		at(c, lx0 + i, y, lz0, gap_lx, gap_lz)
		at(c, lx0 + i, y, lz0 + size - 1, gap_lx, gap_lz)
		at(c, lx0, y, lz0 + i, gap_lx, gap_lz)
		at(c, lx0 + size - 1, y, lz0 + i, gap_lx, gap_lz)
	}
}

// Two cottage styles sharing wall/interior/door code, both built from the
// biome's own materials (see biome_build_mats) so a snow village is log cabins
// under white roofs, a desert one is sand-walled, and so on: variant 0 has a
// pointed pyramid roof and a chimney stub; variant 1 has a flat roof with a
// raised parapet lip and a second window. Both get a small fenced yard.
// Not file-private: tests exercise it directly.
generate_house :: proc(w: ^World, c: ^Chunk, base_x, base_z, lx, lz, surf_y, variant: int, mats: BuildMats) {
	SIZE :: 5
	HEIGHT :: 3
	base_y := surf_y + 1
	cx := lx + SIZE / 2
	cz := lz + SIZE / 2

	for dx in 0 ..< SIZE {
		for dz in 0 ..< SIZE {
			edge := dx == 0 || dx == SIZE - 1 || dz == 0 || dz == SIZE - 1
			if !edge do continue
			chunk_set(c, lx + dx, base_y, lz + dz, .Stone) // foundation course
			for dy in 1 ..< HEIGHT {
				chunk_set(c, lx + dx, base_y + dy, lz + dz, mats.wall)
			}
		}
	}
	for dx in 1 ..< SIZE - 1 {
		for dz in 1 ..< SIZE - 1 {
			for dy in 0 ..< HEIGHT {
				chunk_set(c, lx + dx, base_y + dy, lz + dz, .Air) // hollow interior
			}
		}
	}

	if variant == 0 {
		place_tapering_roof(c, cx, base_y + HEIGHT, cz, []int{3, 2, 1, 0}, mats.roof)
		chunk_set(c, lx, base_y + HEIGHT, lz, .Stone) // chimney base
		chunk_set(c, lx, base_y + HEIGHT + 1, lz, .Stone)
	} else {
		for dx in 0 ..< SIZE {
			for dz in 0 ..< SIZE {
				chunk_set(c, lx + dx, base_y + HEIGHT, lz + dz, mats.roof) // flat cap
			}
		}
		for dx in 0 ..< SIZE { 	// raised parapet lip around the edge
			edge := dx == 0 || dx == SIZE - 1
			chunk_set(c, lx + dx, base_y + HEIGHT + 1, lz, mats.wall)
			chunk_set(c, lx + dx, base_y + HEIGHT + 1, lz + SIZE - 1, mats.wall)
			if edge {
				for dz in 1 ..< SIZE - 1 {
					chunk_set(c, lx + dx, base_y + HEIGHT + 1, lz + dz, mats.wall)
				}
			}
		}
	}

	door_lx := cx
	door_lz := lz
	chunk_set(c, door_lx, base_y, door_lz, .Door)
	chunk_set(c, door_lx, base_y + 1, door_lz, .Air)
	w.doors[Ivec3{base_x + door_lx, base_y, base_z + door_lz}] = Door{facing = 0, open = false}

	chunk_set(c, cx, base_y + 1, lz + SIZE - 1, .Glass) // window opposite the door
	if variant == 1 {
		chunk_set(c, lx, base_y + 1, cz, .Glass) // second window, side wall
	}

	place_fence_ring(c, lx - 1, lz - 1, SIZE + 2, base_y, door_lx, lz - 1)
}

// A taller, stone-built church with a tapering spire capped by a lit
// Glowstone beacon — structurally distinct (material + height + spire) from
// the wood cottages, not just a bigger box.
// Not file-private: tests exercise it directly.
generate_church :: proc(w: ^World, c: ^Chunk, base_x, base_z, lx, lz, surf_y: int) {
	SIZE :: 5
	HEIGHT :: 5
	base_y := surf_y + 1
	cx := lx + SIZE / 2
	cz := lz + SIZE / 2

	for dx in 0 ..< SIZE {
		for dz in 0 ..< SIZE {
			edge := dx == 0 || dx == SIZE - 1 || dz == 0 || dz == SIZE - 1
			if !edge do continue
			for dy in 0 ..< HEIGHT {
				chunk_set(c, lx + dx, base_y + dy, lz + dz, .Stone)
			}
		}
	}
	for dx in 1 ..< SIZE - 1 {
		for dz in 1 ..< SIZE - 1 {
			for dy in 0 ..< HEIGHT {
				chunk_set(c, lx + dx, base_y + dy, lz + dz, .Air)
			}
		}
	}

	spire_radii := []int{3, 2, 1, 0, 0, 0}
	place_tapering_roof(c, cx, base_y + HEIGHT, cz, spire_radii, .Stone)
	chunk_set(c, cx, base_y + HEIGHT + len(spire_radii) - 1, cz, .Glowstone) // lit beacon

	door_lx := cx
	door_lz := lz
	chunk_set(c, door_lx, base_y, door_lz, .Door)
	chunk_set(c, door_lx, base_y + 1, door_lz, .Air)
	w.doors[Ivec3{base_x + door_lx, base_y, base_z + door_lz}] = Door{facing = 0, open = false}

	chunk_set(c, lx + 1, base_y + 1, lz, .Glass) // twin front windows flanking the door
	chunk_set(c, lx + SIZE - 2, base_y + 1, lz, .Glass)

	place_fence_ring(c, lx - 1, lz - 1, SIZE + 2, base_y, door_lx, lz - 1)
}

// A fenced, tilled field — no roof, just Farmland + Wheat at mixed growth
// stages inside a fence ring with a gap for entry. Mirrors the field-
// building loop main.odin's MC_FARM debug hook already uses.
// Not file-private: tests exercise it directly.
generate_farm :: proc(w: ^World, c: ^Chunk, base_x, base_z, lx, lz, surf_y: int) {
	SIZE :: 5
	base_y := surf_y + 1
	stages := [4]BlockId{.Wheat1, .Wheat2, .Wheat3, .Wheat3}
	for dx in 0 ..< SIZE {
		for dz in 0 ..< SIZE {
			chunk_set(c, lx + dx, base_y - 1, lz + dz, .Farmland)
			chunk_set(c, lx + dx, base_y, lz + dz, stages[(dx + dz) % len(stages)])
		}
	}
	place_fence_ring(c, lx - 1, lz - 1, SIZE + 2, base_y, lx + SIZE / 2, lz - 1)
}

// A small stone-ringed water pool at the village crossroads. Pure chunk_set
// calls, no new mechanism — sits right where the four plots meet, so it
// deliberately touches a corner fence-post cell of each neighbouring yard
// (reads as "built into the shared plaza", not a conflict).
@(private = "file")
generate_well :: proc(c: ^Chunk, cx, cz, surf_y: int) {
	base_y := surf_y + 1
	for dx in -1 ..= 1 {
		for dz in -1 ..= 1 {
			edge := dx == 0 && dz == 0 ? false : true
			if edge {
				chunk_set(c, cx + dx, base_y, cz + dz, .Stone)
			} else {
				chunk_set(c, cx + dx, base_y - 1, cz + dz, .Water)
			}
		}
	}
}

// A slender stone watchtower with a fence-railed platform on top, for the
// Guard (see villager.odin) to have somewhere to actually stand watch from
// instead of just being a recoloured wanderer. Deliberately narrow (3x3) to
// fit the free 1-wide crossroad column between plots without needing a
// bigger village layout.
@(private = "file")
generate_watchtower :: proc(c: ^Chunk, cx, cz, surf_y: int) -> Ivec3 {
	base_y := surf_y + 1
	HEIGHT :: 8
	for dy in 0 ..< HEIGHT {
		for dx in -1 ..= 1 {
			for dz in -1 ..= 1 {
				edge := dx != 0 || dz != 0
				if edge do chunk_set(c, cx + dx, base_y + dy, cz + dz, .Stone)
			}
		}
	}
	// hollow the interior so it isn't a solid pillar
	for dy in 0 ..< HEIGHT do chunk_set(c, cx, base_y + dy, cz, .Air)
	place_fence_ring(c, cx - 1, cz - 1, 3, base_y + HEIGHT, cx + 99, cz + 99) // no gap: a full rail
	return Ivec3{cx, base_y + HEIGHT, cz} // the platform, where the Guard stands
}

// Called once per generated chunk (from worldgen_fill, after everything
// else so a building always wins over a tree that happened to land on the
// same columns). Lays out a 2x2 grid of 7x7 plots inside the chunk — two
// house plots, a church plot, a farm plot — and gives each named villager a
// profession tied to the building they actually live/work at.
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
	for lz in 1 ..< CHUNK_D - 1 {
		for lx in 1 ..< CHUNK_W - 1 {
			hh := heights[lx + lz * CHUNK_W]
			lo = min(lo, hh)
			hi = max(hi, hh)
		}
	}
	if hi - lo > 6 do return // too hilly for a tidy village

	h_at :: proc(heights: []int, lx, lz: int) -> int {
		return heights[lx + lz * CHUNK_W]
	}

	vbiome := biomes[8 + 8 * CHUNK_W]
	mats := biome_build_mats(vbiome)

	// 2x2 grid of 7x7 plots: house/house on the west side, church/farm on
	// the east side, a 1-block gap between columns and rows.
	house_a_surf := h_at(heights, 1 + 3, 1 + 3)
	house_b_surf := h_at(heights, 1 + 3, 9 + 3)
	church_surf := h_at(heights, 9 + 3, 1 + 3)
	farm_surf := h_at(heights, 9 + 3, 9 + 3)

	// Ground each structure (footprint + fenced yard, lx-1..lx+SIZE) before
	// raising it, so nothing hangs in the air over sloping terrain.
	place_foundation(c, heights, 1, 1, 7, 7, house_a_surf + 1)
	generate_house(w, c, base_x, base_z, 2, 2, house_a_surf, 0, mats)
	place_foundation(c, heights, 1, 9, 7, 15, house_b_surf + 1)
	generate_house(w, c, base_x, base_z, 2, 10, house_b_surf, 1, mats)
	place_foundation(c, heights, 9, 1, 15, 7, church_surf + 1)
	generate_church(w, c, base_x, base_z, 10, 2, church_surf)
	place_foundation(c, heights, 9, 9, 15, 15, farm_surf + 1)
	generate_farm(w, c, base_x, base_z, 10, 10, farm_surf)

	well_surf := h_at(heights, 8, 8)
	place_foundation(c, heights, 7, 7, 9, 9, well_surf + 1)
	generate_well(c, 8, 8, well_surf)
	tower_surf := h_at(heights, 8, 4)
	place_foundation(c, heights, 7, 3, 9, 5, tower_surf + 1)
	tower_top := generate_watchtower(c, 8, 4, tower_surf)

	center := Ivec3{base_x + 8, well_surf + 1, base_z + 8}
	append(&w.villages, Village{center = center, houses = 2})

	spawn_villager :: proc(
		w: ^World,
		base_x, base_z, lx, lz, surf_y: int,
		salt: u64,
		profession: Profession,
		biome: Biome,
	) {
		home := Ivec3{base_x + lx, surf_y + 1, base_z + lz}
		append(
			&w.villagers,
			Villager {
				pos = Vec3{f32(home.x) + 0.5, f32(home.y), f32(home.z) + 0.5},
				yaw = rng_range(0, 2 * math.PI),
				health = 10,
				name = villager_pick_name(salt),
				home = home,
				profession = profession,
				home_biome = biome,
			},
		)
	}

	spawn_villager(w, base_x, base_z, 4, 4, house_a_surf, hsh + 1, .Blacksmith, vbiome)
	spawn_villager(w, base_x, base_z, 4, 12, house_b_surf, hsh + 2, .Merchant, vbiome)
	spawn_villager(w, base_x, base_z, 12, 4, church_surf, hsh + 3, .Priest, vbiome)
	spawn_villager(w, base_x, base_z, 11, 11, farm_surf, hsh + 4, .Farmer, vbiome)
	if hsh % (VILLAGE_CHANCE * 2) == 0 { 	// half of villages get a second farmer
		spawn_villager(w, base_x, base_z, 13, 13, farm_surf, hsh + 5, .Farmer, vbiome)
	}

	// The Guard's home is the watchtower platform itself, not a house/
	// church/farm — already an absolute Y (the platform level), unlike
	// spawn_villager's other callers which pass a surface height and let
	// it add +1.
	guard_home := Ivec3{base_x + tower_top.x, tower_top.y, base_z + tower_top.z}
	append(
		&w.villagers,
		Villager {
			pos = Vec3{f32(guard_home.x) + 0.5, f32(guard_home.y), f32(guard_home.z) + 0.5},
			yaw = rng_range(0, 2 * math.PI),
			health = 14,
			name = villager_pick_name(hsh + 6),
			home = guard_home,
			profession = .Guard,
			home_biome = vbiome,
		},
	)

	// Farm animals now live inside the fenced farm plot, not at an
	// arbitrary nearby point.
	animal_kinds := [3]MobKind{.Cow, .Sheep, .Chicken}
	n_animals := 2 + rng_int(2) // 2..3
	for i in 0 ..< n_animals {
		append(
			&w.mobs,
			Mob {
				kind = animal_kinds[rng_int(3)],
				pos = Vec3{f32(base_x + 10 + i) + 0.5, f32(farm_surf + 1), f32(base_z + 9) + 0.5},
				yaw = rng_range(0, 2 * math.PI),
				ai_timer = rng_range(0, 2),
				health = 6,
			},
		)
	}
}
