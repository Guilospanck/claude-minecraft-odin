package main

import "core:math"

// Villages: sprawling multi-chunk towns. A village is anchored at a sparse,
// hash-chosen chunk and lays out a GRID x GRID grid of plots (streets between
// them), each holding one of many building types — cottages, a big two-storey
// house, a church, a blacksmith, a market stall, a farm, a park, an animal pen,
// a watchtower, and a central well plaza. Because the terrain generator only
// ever fills the chunk it is currently generating, the whole village is drawn
// *statelessly per chunk*: every chunk the village overlaps re-derives the same
// deterministic layout and draws only the cells that fall inside itself (see
// VBrush below). Villagers/animals are spawned once, by the anchor chunk.

Village :: struct {
	center: Ivec3,
	houses: int,
}

// Roughly 1 in this many chunks is a village anchor (before the biome/flatness
// gates below narrow it further). Villages are big now, so anchors are sparse.
VILLAGE_CHANCE :: 260

// Plot grid: GRID x GRID plots spaced PLOT_PITCH apart, centred on the anchor
// chunk. The town spans roughly GRID*PLOT_PITCH blocks, so it reaches
// VILLAGE_SPAN chunks out from the anchor in every direction.
GRID :: 5
PLOT_PITCH :: 12
VILLAGE_SPAN :: 2 // (GRID/2)*PLOT_PITCH rounded up to chunks

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

// ---------------------------------------------------------------------------
// VBrush: a world-coordinate drawing context bound to ONE chunk. Every write is
// in absolute world coords; only cells that land inside this chunk are actually
// written, so the same village-drawing code can run for every overlapping chunk
// and each chunk paints just its own slice. Stair/door records go into the
// world-global maps, but only the owning chunk (the one the cell is in) records
// them, so there are no duplicates.
// ---------------------------------------------------------------------------
VBrush :: struct {
	w:              ^World,
	c:              ^Chunk,
	base_x, base_z: int, // world coords of this chunk's (0,0) column
}

@(private = "file")
in_chunk :: proc(b: ^VBrush, wx, wz: int) -> (lx, lz: int, ok: bool) {
	lx = wx - b.base_x
	lz = wz - b.base_z
	ok = lx >= 0 && lx < CHUNK_W && lz >= 0 && lz < CHUNK_D
	return
}

vset :: proc(b: ^VBrush, wx, wy, wz: int, block: BlockId) {
	if wy < 0 || wy >= CHUNK_H do return
	if lx, lz, ok := in_chunk(b, wx, wz); ok {
		chunk_set(b.c, lx, wy, lz, block)
	}
}

@(private = "file")
vstair :: proc(b: ^VBrush, wx, wy, wz: int, facing: u8) {
	if wy < 0 || wy >= CHUNK_H do return
	if lx, lz, ok := in_chunk(b, wx, wz); ok {
		chunk_set(b.c, lx, wy, lz, .Stair)
		b.w.stairs[Ivec3{wx, wy, wz}] = facing
	}
}

@(private = "file")
vdoor :: proc(b: ^VBrush, wx, wy, wz: int, facing: int) {
	if lx, lz, ok := in_chunk(b, wx, wz); ok {
		chunk_set(b.c, lx, wy, lz, .Door)
		// clear TWO cells above the sill so a full-height body fits through the
		// doorway (a 1-cell opening leaves the head clipping the lintel).
		if wy + 1 < CHUNK_H do chunk_set(b.c, lx, wy + 1, lz, .Air)
		if wy + 2 < CHUNK_H do chunk_set(b.c, lx, wy + 2, lz, .Air)
		b.w.doors[Ivec3{wx, wy, wz}] = Door{facing = facing, open = false}
	}
}

@(private = "file")
vfence_at :: proc(b: ^VBrush, wx, wy, wz, gap_x, gap_z: int) {
	if wx == gap_x && wz == gap_z do return
	vset(b, wx, wy, wz, .Fence)
}

@(private = "file")
vfence_ring :: proc(b: ^VBrush, wx0, wz0, size, y, gap_x, gap_z: int) {
	for i in 0 ..< size {
		vfence_at(b, wx0 + i, y, wz0, gap_x, gap_z)
		vfence_at(b, wx0 + i, y, wz0 + size - 1, gap_x, gap_z)
		vfence_at(b, wx0, y, wz0 + i, gap_x, gap_z)
		vfence_at(b, wx0 + size - 1, y, wz0 + i, gap_x, gap_z)
	}
}

// A tapering square roof/spire: radii[i] is the half-width at layer base_y+i.
// The base course (widest layer) is laid in Slab for a half-height eave.
@(private = "file")
vtapering_roof :: proc(b: ^VBrush, cx, base_y, cz: int, radii: []int, material: BlockId) {
	for i in 0 ..< len(radii) {
		r := radii[i]
		y := base_y + i
		mat := i == 0 ? BlockId.Slab : material
		for dz in -r ..= r {
			for dx in -r ..= r {
				if r > 1 && abs(dx) == r && abs(dz) == r do continue
				vset(b, cx + dx, y, cz + dz, mat)
			}
		}
	}
}

// Ground a footprint (+ a blended apron) so nothing floats: for every column,
// stack up from that column's own terrain surface to just below base_y. Filled
// with Dirt (topped Grass where it's exposed at the surface) so a slope-side
// pedestal reads as raised earth the building sits on, not an artificial plinth.
@(private = "file")
vfoundation :: proc(b: ^VBrush, seed: u64, wx0, wz0, wx1, wz1, base_y: int) {
	for wz in wz0 ..= wz1 {
		for wx in wx0 ..= wx1 {
			if _, _, ok := in_chunk(b, wx, wz); !ok do continue // skip cols outside this chunk
			ground, _, _ := world_height_and_biome(seed, wx, wz)
			for y in ground ..< base_y {
				// the exposed top course grasses over; everything below is dirt
				vset(b, wx, y, wz, y == base_y - 1 ? .Grass : .Dirt)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Buildings (world-coord form). (ox,oz) is the min corner; base_y is the
// foundation-course level (terrain surface + 1).
// ---------------------------------------------------------------------------

// Two cottage styles sharing wall/interior/door code, built from the biome's
// materials. Variant 0: pointed pyramid roof + chimney. Variant 1: flat roof
// with a parapet lip + a second window. Both get a plank floor, a carpet rug,
// glass-pane windows, a fenced yard, and a glowstone lamp post by the door.
@(private = "file")
build_house :: proc(b: ^VBrush, ox, oz, base_y, variant: int, mats: BuildMats) {
	SIZE :: 5
	HEIGHT :: 3
	cx := ox + SIZE / 2
	cz := oz + SIZE / 2

	for dx in 0 ..< SIZE {
		for dz in 0 ..< SIZE {
			edge := dx == 0 || dx == SIZE - 1 || dz == 0 || dz == SIZE - 1
			if !edge do continue
			vset(b, ox + dx, base_y, oz + dz, .Stone)
			for dy in 1 ..< HEIGHT {
				vset(b, ox + dx, base_y + dy, oz + dz, mats.wall)
			}
		}
	}
	rugs := [4]BlockId{.CarpetRed, .CarpetBlue, .CarpetYellow, .CarpetWhite}
	rug := rugs[(ox + oz) & 3]
	for dx in 1 ..< SIZE - 1 {
		for dz in 1 ..< SIZE - 1 {
			for dy in 0 ..< HEIGHT {
				vset(b, ox + dx, base_y + dy, oz + dz, .Air)
			}
			// floor sits one below base_y so the interior is FLUSH with the
			// ground outside (a floor at base_y makes the doorway a step up).
			vset(b, ox + dx, base_y - 1, oz + dz, .Planks)
			vset(b, ox + dx, base_y, oz + dz, rug) // rug at walk level
		}
	}

	if variant == 0 {
		vtapering_roof(b, cx, base_y + HEIGHT, cz, []int{3, 2, 1, 0}, mats.roof)
		vset(b, ox, base_y + HEIGHT, oz, .Stone) // chimney base
		vset(b, ox, base_y + HEIGHT + 1, oz, .Stone)
	} else {
		for dx in 0 ..< SIZE {
			for dz in 0 ..< SIZE {
				vset(b, ox + dx, base_y + HEIGHT, oz + dz, mats.roof) // flat cap
			}
		}
		for dx in 0 ..< SIZE {
			vset(b, ox + dx, base_y + HEIGHT + 1, oz, mats.wall)
			vset(b, ox + dx, base_y + HEIGHT + 1, oz + SIZE - 1, mats.wall)
		}
		for dz in 1 ..< SIZE - 1 {
			vset(b, ox, base_y + HEIGHT + 1, oz + dz, mats.wall)
			vset(b, ox + SIZE - 1, base_y + HEIGHT + 1, oz + dz, mats.wall)
		}
	}

	vdoor(b, cx, base_y, oz, 0)
	vstair(b, cx, base_y, oz - 1, 0) // doorstep
	// glowstone lamp post by the entrance
	vset(b, cx + 1, base_y, oz - 1, .Fence)
	vset(b, cx + 1, base_y + 1, oz - 1, .Fence)
	vset(b, cx + 1, base_y + 2, oz - 1, .Glowstone)
	// glass-pane windows on the three closed walls
	vset(b, cx, base_y + 1, oz + SIZE - 1, .GlassPane)
	vset(b, cx - 1, base_y + 1, oz + SIZE - 1, .GlassPane)
	vset(b, ox, base_y + 1, cz, .GlassPane)
	vset(b, ox + SIZE - 1, base_y + 1, cz, .GlassPane)

	vfence_ring(b, ox - 1, oz - 1, SIZE + 2, base_y, cx, oz - 1)
}

// A bigger two-storey house: taller walls, a mid-floor, windows on both levels,
// a flat parapet roof. Reads as the town's larger family home / manor.
@(private = "file")
build_bighouse :: proc(b: ^VBrush, ox, oz, base_y, variant: int, mats: BuildMats) {
	SIZE :: 5
	HEIGHT :: 6
	cx := ox + SIZE / 2
	cz := oz + SIZE / 2
	for dx in 0 ..< SIZE {
		for dz in 0 ..< SIZE {
			edge := dx == 0 || dx == SIZE - 1 || dz == 0 || dz == SIZE - 1
			if !edge do continue
			vset(b, ox + dx, base_y, oz + dz, .Stone)
			for dy in 1 ..< HEIGHT {
				vset(b, ox + dx, base_y + dy, oz + dz, mats.wall)
			}
		}
	}
	for dx in 1 ..< SIZE - 1 {
		for dz in 1 ..< SIZE - 1 {
			for dy in 0 ..< HEIGHT do vset(b, ox + dx, base_y + dy, oz + dz, .Air)
			vset(b, ox + dx, base_y - 1, oz + dz, .Planks) // ground floor (flush outside)
			vset(b, ox + dx, base_y + 3, oz + dz, .Planks) // upper floor
		}
	}
	// stairwell: a hole in the upper floor with a ladder climbing up to it
	vset(b, ox + 1, base_y + 3, oz + 1, .Air)
	for h in 1 ..= 3 do vset(b, ox + 1, base_y + h, oz + 2, .Ladder)
	// flat roof + parapet
	for dx in 0 ..< SIZE {
		for dz in 0 ..< SIZE do vset(b, ox + dx, base_y + HEIGHT, oz + dz, mats.roof)
	}
	for dx in 0 ..< SIZE {
		vset(b, ox + dx, base_y + HEIGHT + 1, oz, mats.wall)
		vset(b, ox + dx, base_y + HEIGHT + 1, oz + SIZE - 1, mats.wall)
	}
	for dz in 1 ..< SIZE - 1 {
		vset(b, ox, base_y + HEIGHT + 1, oz + dz, mats.wall)
		vset(b, ox + SIZE - 1, base_y + HEIGHT + 1, oz + dz, mats.wall)
	}
	vdoor(b, cx, base_y, oz, 0)
	vstair(b, cx, base_y, oz - 1, 0)
	// two rows of glass-pane windows (ground + upper)
	for lvl in ([2]int{1, 4}) {
		vset(b, cx, base_y + lvl, oz + SIZE - 1, .GlassPane)
		vset(b, ox, base_y + lvl, cz, .GlassPane)
		vset(b, ox + SIZE - 1, base_y + lvl, cz, .GlassPane)
	}
	// corner lamp
	vset(b, ox - 1, base_y, oz - 1, .Fence)
	vset(b, ox - 1, base_y + 1, oz - 1, .Glowstone)
	vfence_ring(b, ox - 1, oz - 1, SIZE + 2, base_y, cx, oz - 1)
}

// A taller, stone-built church with a tapering spire capped by a lit Glowstone
// beacon, a flared stair eave, corner pinnacles, and twin front windows.
@(private = "file")
build_church :: proc(b: ^VBrush, ox, oz, base_y: int) {
	SIZE :: 5
	HEIGHT :: 5
	cx := ox + SIZE / 2
	cz := oz + SIZE / 2
	for dx in 0 ..< SIZE {
		for dz in 0 ..< SIZE {
			edge := dx == 0 || dx == SIZE - 1 || dz == 0 || dz == SIZE - 1
			if !edge do continue
			for dy in 0 ..< HEIGHT do vset(b, ox + dx, base_y + dy, oz + dz, .Stone)
		}
	}
	for dx in 1 ..< SIZE - 1 {
		for dz in 1 ..< SIZE - 1 {
			for dy in 0 ..< HEIGHT do vset(b, ox + dx, base_y + dy, oz + dz, .Air)
			vset(b, ox + dx, base_y - 1, oz + dz, .StoneBrick) // tiled nave floor (flush)
		}
	}
	eave_y := base_y + HEIGHT
	for d in 0 ..< SIZE {
		vstair(b, ox + d, eave_y, oz, 0)
		vstair(b, ox + d, eave_y, oz + SIZE - 1, 1)
		vstair(b, ox, eave_y, oz + d, 2)
		vstair(b, ox + SIZE - 1, eave_y, oz + d, 3)
	}
	spire := []int{3, 2, 1, 0, 0, 0}
	vtapering_roof(b, cx, base_y + HEIGHT + 1, cz, spire, .Stone)
	vset(b, cx, base_y + HEIGHT + 1 + len(spire) - 1, cz, .Glowstone)
	corners := [4][2]int{{0, 0}, {SIZE - 1, 0}, {0, SIZE - 1}, {SIZE - 1, SIZE - 1}}
	for cr in corners {
		vset(b, ox + cr[0], eave_y + 1, oz + cr[1], .Stone)
		vset(b, ox + cr[0], eave_y + 2, oz + cr[1], .Torch)
	}
	vdoor(b, cx, base_y, oz, 0)
	vstair(b, cx, base_y, oz - 1, 0)
	vset(b, cx - 1, base_y + 2, oz - 1, .Torch)
	vset(b, cx + 1, base_y + 2, oz - 1, .Torch)
	vset(b, ox + 1, base_y + 1, oz, .GlassPane)
	vset(b, ox + SIZE - 2, base_y + 1, oz, .GlassPane)
	vfence_ring(b, ox - 1, oz - 1, SIZE + 2, base_y, cx, oz - 1)
}

// A walled smithy you can walk into: cobblestone walls with a door, a
// glowstone-topped obsidian forge (lit but safe — no walk-in lava), a furnace,
// a chest, and a chimney. The village Blacksmith works here.
@(private = "file")
build_blacksmith :: proc(b: ^VBrush, ox, oz, base_y: int) {
	SIZE :: 5
	HEIGHT :: 3
	cx := ox + SIZE / 2
	for dx in 0 ..< SIZE {
		for dz in 0 ..< SIZE {
			edge := dx == 0 || dx == SIZE - 1 || dz == 0 || dz == SIZE - 1
			if !edge do continue
			vset(b, ox + dx, base_y, oz + dz, .Cobblestone)
			for dy in 1 ..< HEIGHT do vset(b, ox + dx, base_y + dy, oz + dz, .Cobblestone)
		}
	}
	for dx in 1 ..< SIZE - 1 {
		for dz in 1 ..< SIZE - 1 {
			for dy in 0 ..< HEIGHT do vset(b, ox + dx, base_y + dy, oz + dz, .Air)
			vset(b, ox + dx, base_y - 1, oz + dz, .StoneBrick) // shop floor (flush)
		}
	}
	// flat cobble roof
	for dx in 0 ..< SIZE {
		for dz in 0 ..< SIZE do vset(b, ox + dx, base_y + HEIGHT, oz + dz, .Cobblestone)
	}
	// safe lit forge (obsidian block topped with glowstone), a furnace, a chest
	vset(b, ox + 1, base_y, oz + SIZE - 2, .Obsidian)
	vset(b, ox + 1, base_y + 1, oz + SIZE - 2, .Glowstone)
	vset(b, ox + 2, base_y, oz + SIZE - 2, .Furnace)
	vset(b, ox + 3, base_y, oz + 1, .Chest)
	vset(b, ox + 1, base_y + HEIGHT + 1, oz + SIZE - 2, .Cobblestone) // chimney
	// a door + a window, and a fenced yard with a gap at the door
	vdoor(b, cx, base_y, oz, 0)
	vstair(b, cx, base_y, oz - 1, 0)
	vset(b, ox + SIZE - 1, base_y + 1, oz + 2, .GlassPane)
	vfence_ring(b, ox - 1, oz - 1, SIZE + 2, base_y, cx, oz - 1)
}

// An open market stall: four plank posts, a striped wool awning, a display
// counter with a chest and a couple of goods. The Merchant trades here.
@(private = "file")
build_market :: proc(b: ^VBrush, ox, oz, base_y: int) {
	SIZE :: 5
	for corner in ([4][2]int{{0, 0}, {SIZE - 1, 0}, {0, SIZE - 1}, {SIZE - 1, SIZE - 1}}) {
		vset(b, ox + corner[0], base_y, oz + corner[1], .Planks)
		vset(b, ox + corner[0], base_y + 1, oz + corner[1], .Planks)
	}
	// striped wool awning at base_y+2
	awn := [2]BlockId{.WoolRed, .WoolWhite}
	for dx in 0 ..< SIZE {
		for dz in 0 ..< SIZE {
			vset(b, ox + dx, base_y + 2, oz + dz, awn[(dx + dz) & 1])
		}
	}
	// counter + goods + chest
	for dx in 1 ..< SIZE - 1 {
		vset(b, ox + dx, base_y, oz + SIZE - 1, .Planks) // back counter
	}
	vset(b, ox + 1, base_y + 1, oz + SIZE - 1, .Chest)
	vset(b, ox + 2, base_y + 1, oz + SIZE - 1, .Bricks) // goods on display
	vset(b, ox + 3, base_y + 1, oz + SIZE - 1, .GoldOre)
}

// A fenced, tilled field with mixed-stage wheat. The Farmer works here.
@(private = "file")
build_farm :: proc(b: ^VBrush, ox, oz, base_y: int) {
	SIZE :: 5
	stages := [4]BlockId{.Wheat1, .Wheat2, .Wheat3, .Wheat3}
	for dx in 0 ..< SIZE {
		for dz in 0 ..< SIZE {
			vset(b, ox + dx, base_y - 1, oz + dz, .Farmland)
			vset(b, ox + dx, base_y, oz + dz, stages[(dx + dz) % len(stages)])
		}
	}
	vfence_ring(b, ox - 1, oz - 1, SIZE + 2, base_y, ox + SIZE / 2, oz - 1)
}

// A little public garden: fenced grass with flowers, a small tree, and benches
// (stairs) around a central lamp — the town green.
@(private = "file")
build_park :: proc(b: ^VBrush, ox, oz, base_y: int) {
	SIZE :: 5
	flowers := [4]BlockId{.FlowerRed, .FlowerYellow, .FlowerBlue, .FlowerPink}
	for dx in 0 ..< SIZE {
		for dz in 0 ..< SIZE {
			vset(b, ox + dx, base_y - 1, oz + dz, .Grass)
			// scatter flowers, leave the centre + a path clear
			if (dx * 3 + dz * 5) & 3 == 0 && !(dx == SIZE / 2 && dz == SIZE / 2) {
				vset(b, ox + dx, base_y, oz + dz, flowers[(dx + dz) & 3])
			}
		}
	}
	// central lamp
	cx := ox + SIZE / 2
	cz := oz + SIZE / 2
	vset(b, cx, base_y, cz, .Fence)
	vset(b, cx, base_y + 1, cz, .Fence)
	vset(b, cx, base_y + 2, cz, .Glowstone)
	// a small tree in a corner
	tx := ox + 1
	tz := oz + SIZE - 2
	for h in 0 ..< 3 do vset(b, tx, base_y + h, tz, .Wood)
	for dx in -1 ..= 1 {
		for dz in -1 ..= 1 do vset(b, tx + dx, base_y + 3, tz + dz, .Leaves)
	}
	vset(b, tx, base_y + 4, tz, .Leaves)
	// benches facing the middle
	vstair(b, ox + 1, base_y, oz + 1, 0)
	vstair(b, ox + SIZE - 2, base_y, oz + 1, 0)
	vfence_ring(b, ox - 1, oz - 1, SIZE + 2, base_y, cx, oz - 1)
}

// A fenced animal pen with a feed trough and a water trough; the anchor chunk
// drops a couple of livestock inside.
@(private = "file")
build_pen :: proc(b: ^VBrush, ox, oz, base_y: int) {
	SIZE :: 5
	cx := ox + SIZE / 2
	for dx in 0 ..< SIZE {
		for dz in 0 ..< SIZE do vset(b, ox + dx, base_y - 1, oz + dz, .Grass)
	}
	// feed trough (planks) and a water trough
	vset(b, ox + 1, base_y, oz + 1, .Planks)
	vset(b, ox + 2, base_y, oz + 1, .Planks)
	vset(b, ox + SIZE - 2, base_y - 1, oz + SIZE - 2, .Water)
	// fence with a real 1-cell gap you can walk through (a solid gate would
	// seal the pen shut).
	vfence_ring(b, ox, oz, SIZE, base_y, cx, oz)
}

// A stout stone watchtower topped with a railed lookout, climbed by an external
// ladder up one face (a 1-wide interior shaft can't fit a ladder AND standing
// room, so the ladder goes up the outside to the roof). Returns the lookout
// position (world coords) where the Guard stands.
@(private = "file")
build_watchtower :: proc(b: ^VBrush, cx, cz, base_y: int) -> Ivec3 {
	H :: 7
	// solid stone pillar
	for dy in 0 ..< H {
		for dx in -1 ..= 1 {
			for dz in -1 ..= 1 do vset(b, cx + dx, base_y + dy, cz + dz, .Cobblestone)
		}
	}
	// external ladder up the -z face (against the wall at cz-1) to the roof
	for dy in 0 ..< H do vset(b, cx, base_y + dy, cz - 2, .Ladder)
	// railed lookout on the roof (surface at base_y+H), with a gap where the
	// ladder arrives so you can step off the ladder onto the platform
	vfence_ring(b, cx - 1, cz - 1, 3, base_y + H, cx, cz - 1)
	vset(b, cx - 1, base_y + H + 1, cz - 1, .Torch)
	vset(b, cx + 1, base_y + H + 1, cz + 1, .Torch)
	return Ivec3{cx, base_y + H, cz}
}

// The central well plaza: a stone-ringed water pool with a lamp post at each
// corner, marking the town crossroads.
@(private = "file")
build_well :: proc(b: ^VBrush, cx, cz, base_y: int) {
	for dx in -1 ..= 1 {
		for dz in -1 ..= 1 {
			if dx == 0 && dz == 0 {
				vset(b, cx, base_y - 1, cz, .Water)
			} else {
				vset(b, cx + dx, base_y, cz + dz, .StoneBrick)
			}
		}
	}
	for corner in ([4][2]int{{-2, -2}, {2, -2}, {-2, 2}, {2, 2}}) {
		lx := cx + corner[0]
		lz := cz + corner[1]
		vset(b, lx, base_y, lz, .Fence)
		vset(b, lx, base_y + 1, lz, .Fence)
		vset(b, lx, base_y + 2, lz, .Glowstone)
	}
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

PlotType :: enum {
	Empty,
	House0,
	House1,
	BigHouse,
	Farm,
	Park,
	Pen,
	Church,
	Watchtower,
	Blacksmith,
	Market,
	Well,
}

// The building on plot (gi,gj) of a village, deterministic from the anchor.
// Fixed landmarks anchor the corners + centre; the rest are hash-weighted so
// every town has a different mix of homes, farms, parks and pens.
@(private = "file")
plot_type :: proc(seed: u64, anchor: Ivec2, gi, gj: int) -> PlotType {
	if gi == GRID / 2 && gj == GRID / 2 do return .Well
	if gi == 0 && gj == 0 do return .Church
	if gi == GRID - 1 && gj == GRID - 1 do return .Watchtower
	if gi == 0 && gj == GRID - 1 do return .Blacksmith
	if gi == GRID - 1 && gj == 0 do return .Market
	h := hash_u64(
		seed ~
		(u64(i64(anchor.x)) * 0x9E3779B1) ~
		(u64(i64(anchor.y)) * 0x85EBCA77) ~
		(u64(gi * 73 + gj * 131) * 0xC2B2AE35) ~
		0x5117_0651,
	)
	r := h % 100
	switch {
	case r < 32:
		return .House0
	case r < 56:
		return .House1
	case r < 68:
		return .BigHouse
	case r < 80:
		return .Farm
	case r < 89:
		return .Park
	case r < 96:
		return .Pen
	}
	return .Empty
}

@(private = "file")
plot_profession :: proc(pt: PlotType, salt: u64) -> (Profession, bool) {
	#partial switch pt {
	case .Church:
		return .Priest, true
	case .Blacksmith:
		return .Blacksmith, true
	case .Market:
		return .Merchant, true
	case .Farm:
		return .Farmer, true
	case .House0, .House1:
		roles := [3]Profession{.None, .Farmer, .Merchant}
		return roles[salt % 3], true
	case .BigHouse:
		return .None, true
	}
	return .None, false
}

// Is `anchor` a valid village site? Cheap hash roll first, then a biome gate and
// a flatness check across the plot centres so a town never straddles a cliff or
// spills into the sea. Returns the town-centre surface height + biome.
@(private = "file")
village_valid :: proc(w: ^World, seed: u64, anchor: Ivec2) -> (surf: int, biome: Biome, ok: bool) {
	forced := g_force_village && anchor == g_force_village_chunk
	if !forced {
		hsh := hash_u64(
			seed ~
			(u64(i64(anchor.x)) * 0x9E3779B1) ~
			(u64(i64(anchor.y)) * 0x85EBCA77) ~
			0xF00D_FACE,
		)
		if hsh % VILLAGE_CHANCE != 0 do return
	}
	ccx := anchor.x * CHUNK_W + CHUNK_W / 2
	ccz := anchor.y * CHUNK_D + CHUNK_D / 2
	ch, cb, _ := world_height_and_biome(seed, ccx, ccz)
	if !village_biome_ok(cb) do return
	// flatness: sample every plot centre; reject if the spread is too big
	lo, hi := ch, ch
	for gj in 0 ..< GRID {
		for gi in 0 ..< GRID {
			px := ccx + (gi - GRID / 2) * PLOT_PITCH
			pz := ccz + (gj - GRID / 2) * PLOT_PITCH
			ph, _, _ := world_height_and_biome(seed, px, pz)
			lo = min(lo, ph)
			hi = max(hi, ph)
		}
	}
	// Require fairly flat ground so the town beds cleanly instead of perching
	// its buildings on tall terraced pedestals (which read as "floating").
	if hi - lo > 6 do return
	// Keep the whole town on DRY LAND: the lowest plot must sit clear above the
	// waterline, so a village never generates half-drowned in a coastal dip.
	if lo <= SEA_LEVEL + 2 do return
	return ch, cb, true
}

// Draw the part of the village anchored at `anchor` that falls inside chunk c.
// When c IS the anchor chunk, also spawn the villagers/animals/register it (so
// they are created exactly once no matter how many chunks the town spans).
@(private = "file")
draw_village :: proc(b: ^VBrush, seed: u64, anchor: Ivec2, biome: Biome) {
	mats := biome_build_mats(biome)
	ccx := anchor.x * CHUNK_W + CHUNK_W / 2
	ccz := anchor.y * CHUNK_D + CHUNK_D / 2
	is_anchor := b.c.coord == anchor
	house_count := 0

	// Main crossroads: a 3-wide cobblestone path along both axes, laid at each
	// column's own surface so it hugs the terracing.
	reach := (GRID / 2) * PLOT_PITCH
	for d in -reach ..= reach {
		for off in -1 ..= 1 {
			pairs := [2][2]int{{ccx + d, ccz + off}, {ccx + off, ccz + d}}
			for pr in pairs {
				if _, _, ok := in_chunk(b, pr[0], pr[1]); !ok do continue
				sh, _, _ := world_height_and_biome(seed, pr[0], pr[1])
				vset(b, pr[0], sh - 1, pr[1], .Cobblestone)
			}
		}
	}

	for gj in 0 ..< GRID {
		for gi in 0 ..< GRID {
			pt := plot_type(seed, anchor, gi, gj)
			if pt == .Empty do continue
			pcx := ccx + (gi - GRID / 2) * PLOT_PITCH
			pcz := ccz + (gj - GRID / 2) * PLOT_PITCH
			surf, _, _ := world_height_and_biome(seed, pcx, pcz)
			base_y := surf + 1
			ox := pcx - 2 // 5-wide footprint min corner
			oz := pcz - 2
			salt := hash_u64(seed ~ u64(gi * 928371 + gj * 1237) ~ u64(i64(anchor.x)) ~ 0xABCD)

			// ground the footprint + yard + a one-block blended apron
			vfoundation(b, seed, ox - 2, oz - 2, ox + 6, oz + 6, base_y)

			switch pt {
			case .Well:
				build_well(b, pcx, pcz, base_y)
			case .Church:
				build_church(b, ox, oz, base_y)
			case .Watchtower:
				plat := build_watchtower(b, pcx, pcz, base_y)
				if is_anchor do spawn_villager(b.w, plat, plat.y, salt, .Guard, biome, 14)
			case .Blacksmith:
				build_blacksmith(b, ox, oz, base_y)
			case .Market:
				build_market(b, ox, oz, base_y)
			case .Farm:
				build_farm(b, ox, oz, base_y)
			case .Park:
				build_park(b, ox, oz, base_y)
			case .Pen:
				build_pen(b, ox, oz, base_y)
				if is_anchor {
					kinds := [3]MobKind{.Cow, .Sheep, .Chicken}
					for k in 0 ..< 2 {
						append(
							&b.w.mobs,
							Mob {
								kind = kinds[(int(salt % 3) + k) % 3],
								pos = Vec3{f32(ox + 1 + k) + 0.5, f32(base_y), f32(oz + 2) + 0.5},
								yaw = rng_range(0, 2 * math.PI),
								ai_timer = rng_range(0, 2),
								health = 6,
							},
						)
					}
				}
			case .House0:
				build_house(b, ox, oz, base_y, 0, mats)
				house_count += 1
			case .House1:
				build_house(b, ox, oz, base_y, 1, mats)
				house_count += 1
			case .BigHouse:
				build_bighouse(b, ox, oz, base_y, 0, mats)
				house_count += 1
			case .Empty:
			// nothing
			}

			// resident villager for buildings that have one
			if is_anchor {
				if pro, has := plot_profession(pt, salt); has {
					home := Ivec3{pcx, base_y, pcz}
					spawn_villager(b.w, home, base_y, salt, pro, biome, 10)
				}
			}
		}
	}

	if is_anchor {
		append(&b.w.villages, Village{center = Ivec3{ccx, surf_at(seed, ccx, ccz) + 1, ccz}, houses = house_count})
	}
}

@(private = "file")
surf_at :: proc(seed: u64, wx, wz: int) -> int {
	h, _, _ := world_height_and_biome(seed, wx, wz)
	return h
}

@(private = "file")
spawn_villager :: proc(w: ^World, home: Ivec3, y: int, salt: u64, profession: Profession, biome: Biome, health: int) {
	append(
		&w.villagers,
		Villager {
			pos = Vec3{f32(home.x) + 0.5, f32(y), f32(home.z) + 0.5},
			yaw = rng_range(0, 2 * math.PI),
			health = health,
			name = villager_pick_name(salt),
			home = home,
			profession = profession,
			home_biome = biome,
		},
	)
}

// Debug-only: force the one named chunk to be a village anchor (biome/flatness
// still apply). Used by the MC_SNOWVILLAGE hook; off in normal play.
g_force_village: bool
g_force_village_chunk: Ivec2

// Called once per generated chunk (from worldgen_fill, last, so buildings win
// over trees). Draws the slice of every nearby village anchor that overlaps
// this chunk. Villages span multiple chunks, so we scan the VILLAGE_SPAN-chunk
// neighbourhood for anchors.
generate_village :: proc(w: ^World, c: ^Chunk, seed: u64, base_x, base_z: int, heights: []int, biomes: []Biome) {
	b := VBrush{w, c, base_x, base_z}
	for aj in c.coord.y - VILLAGE_SPAN ..= c.coord.y + VILLAGE_SPAN {
		for ai in c.coord.x - VILLAGE_SPAN ..= c.coord.x + VILLAGE_SPAN {
			anchor := Ivec2{ai, aj}
			if _, biome, ok := village_valid(w, seed, anchor); ok {
				draw_village(&b, seed, anchor, biome)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Test/compat wrappers: the tests draw a single building into a chunk at local
// coords. With base_x=base_z=0 the VBrush's world coords equal local coords.
// ---------------------------------------------------------------------------

generate_house :: proc(w: ^World, c: ^Chunk, base_x, base_z, lx, lz, surf_y, variant: int, mats: BuildMats) {
	b := VBrush{w, c, base_x, base_z}
	build_house(&b, base_x + lx, base_z + lz, surf_y + 1, variant, mats)
}

generate_church :: proc(w: ^World, c: ^Chunk, base_x, base_z, lx, lz, surf_y: int) {
	b := VBrush{w, c, base_x, base_z}
	build_church(&b, base_x + lx, base_z + lz, surf_y + 1)
}

generate_farm :: proc(w: ^World, c: ^Chunk, base_x, base_z, lx, lz, surf_y: int) {
	b := VBrush{w, c, base_x, base_z}
	build_farm(&b, base_x + lx, base_z + lz, surf_y + 1)
}

// Fill a solid pedestal under a footprint (chunk-local form, used by tests and
// still handy for single-chunk grounding).
// Not file-private: tests exercise it directly.
place_foundation :: proc(c: ^Chunk, heights: []int, lx0, lz0, lx1, lz1, base_y: int) {
	for lz in lz0 ..= lz1 {
		for lx in lx0 ..= lx1 {
			if lx < 0 || lz < 0 || lx >= CHUNK_W || lz >= CHUNK_D do continue
			ground := heights[lx + lz * CHUNK_W]
			for y in ground ..< base_y {
				chunk_set(c, lx, y, lz, .Stone)
			}
		}
	}
}
