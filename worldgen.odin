package main

Biome :: enum {
	Plains,
	Forest,
	Desert,
	Snow,
	Mountains,
	Savanna,
	Swamp,
	Taiga,
}

@(private = "file")
classify_biome :: proc(temp, moist, mountain: f32, h: int) -> Biome {
	if mountain > 0.45 || h > SEA_LEVEL + 30 do return .Mountains
	if temp < -0.35 do return moist > 0.0 ? .Taiga : .Snow
	if temp > 0.35 do return moist < -0.15 ? .Desert : .Savanna
	if moist > 0.30 && h < SEA_LEVEL + 6 do return .Swamp
	if moist > 0.15 do return .Forest
	return .Plains
}

@(private = "file")
surface_block :: proc(biome: Biome, h: int) -> BlockId {
	if h <= SEA_LEVEL + 1 do return .Sand // beach / seabed
	switch biome {
	case .Desert:
		return .Sand
	case .Snow, .Taiga:
		return .Snow
	case .Mountains:
		return h > SEA_LEVEL + 34 ? .Snow : .Stone
	case .Plains, .Forest, .Savanna, .Swamp:
		return .Grass
	}
	return .Grass
}

@(private = "file")
subsurface_block :: proc(biome: Biome) -> BlockId {
	#partial switch biome {
	case .Desert:
		return .Sand
	case .Mountains:
		return .Stone
	}
	return .Dirt
}

worldgen_fill :: proc(c: ^Chunk, seed: u64) {
	base_x := c.coord.x * CHUNK_W
	base_z := c.coord.y * CHUNK_D

	heights: [CHUNK_W * CHUNK_D]int
	biomes: [CHUNK_W * CHUNK_D]Biome

	for lz in 0 ..< CHUNK_D {
		for lx in 0 ..< CHUNK_W {
			wx := base_x + lx
			wz := base_z + lz
			fx := f32(wx)
			fz := f32(wz)

			hn := fbm2(seed, fx * 0.012, fz * 0.012, 5) // rolling hills [-1,1]
			mountain := fbm2(seed + 31, fx * 0.006, fz * 0.006, 3)
			h := SEA_LEVEL + int(hn * 18.0)
			if mountain > 0.3 {
				h += int((mountain - 0.3) * 70.0)
			}
			if h < 4 do h = 4
			if h > CHUNK_H - 8 do h = CHUNK_H - 8

			temp := fbm2(seed + 101, fx * 0.004, fz * 0.004, 3)
			moist := fbm2(seed + 202, fx * 0.004, fz * 0.004, 3)
			biome := classify_biome(temp, moist, mountain, h)

			heights[lx + lz * CHUNK_W] = h
			biomes[lx + lz * CHUNK_W] = biome

			surf := surface_block(biome, h)
			sub := subsurface_block(biome)

			for y in 0 ..< CHUNK_H {
				b: BlockId = .Air
				if y == 0 {
					b = .Bedrock
				} else if y < h {
					if y == h - 1 {
						b = surf
					} else if y >= h - 4 {
						b = sub
					} else {
						b = .Stone
					}
				} else if y <= SEA_LEVEL {
					b = .Water
				}

				// carve caves through interior solids (not surface, bedrock or water)
				if b != .Air && b != .Bedrock && b != .Water && y > 1 && y < h - 1 {
					cave := fbm3(seed + 555, fx * 0.055, f32(y) * 0.055, fz * 0.055, 3)
					if cave > 0.62 {
						b = .Air
					}
				}

				// sparse ore in stone
				if b == .Stone {
					ov := value_noise3(seed + 777, fx * 0.19, f32(y) * 0.19, fz * 0.19)
					if ov > 0.82 {
						b = .Ore
					}
				}

				c.blocks[chunk_index(lx, y, lz)] = b
			}
		}
	}

	generate_trees(c, seed, base_x, base_z, heights[:], biomes[:])
}

// Build a tree (round oak or conical spruce). chunk_set clips any leaves that
// spill past the chunk edge.
@(private = "file")
place_tree :: proc(c: ^Chunk, lx, surf_y, lz, trunk_h: int, spruce: bool) {
	base := surf_y + 1
	for i in 0 ..< trunk_h {
		chunk_set(c, lx, base + i, lz, .Wood)
	}
	crown := base + trunk_h - 1
	if spruce {
		for dy := -3; dy <= 1; dy += 1 {
			r := dy <= -2 ? 2 : (dy <= 0 ? 1 : 0)
			for dz in -r ..= r {
				for dx in -r ..= r {
					if abs(dx) == r && abs(dz) == r do continue // clip corners
					if chunk_get(c, lx + dx, crown + dy, lz + dz) == .Air {
						chunk_set(c, lx + dx, crown + dy, lz + dz, .Leaves)
					}
				}
			}
		}
	} else {
		for dy in -1 ..= 1 {
			r := dy == 1 ? 1 : 2
			for dz in -r ..= r {
				for dx in -r ..= r {
					if dx == 0 && dz == 0 && dy < 1 do continue
					if chunk_get(c, lx + dx, crown + dy, lz + dz) == .Air {
						chunk_set(c, lx + dx, crown + dy, lz + dz, .Leaves)
					}
				}
			}
		}
	}
	chunk_set(c, lx, crown + 2, lz, .Leaves)
}

// Per-biome surface decoration: trees (density/type varies) and desert cacti.
@(private = "file")
generate_trees :: proc(c: ^Chunk, seed: u64, base_x, base_z: int, heights: []int, biomes: []Biome) {
	for lz in 2 ..< CHUNK_D - 2 {
		for lx in 2 ..< CHUNK_W - 2 {
			biome := biomes[lx + lz * CHUNK_W]
			surf_y := heights[lx + lz * CHUNK_W] - 1
			if surf_y < SEA_LEVEL do continue
			surf := chunk_get(c, lx, surf_y, lz)

			wx := base_x + lx
			wz := base_z + lz
			hsh := hash_u64(seed ~ (u64(i64(wx)) * 0x9E3779B1) ~ (u64(i64(wz)) * 0x85EBCA77))
			r := hsh % 1000
			th := int((hsh >> 10) % 3)

			switch biome {
			case .Desert:
				if surf == .Sand && r < 8 {
					for i in 0 ..< 1 + th do chunk_set(c, lx, surf_y + 1 + i, lz, .Cactus)
				}
			case .Forest:
				if surf == .Grass && r < 45 do place_tree(c, lx, surf_y, lz, 4 + th, false)
			case .Swamp:
				if surf == .Grass && r < 18 do place_tree(c, lx, surf_y, lz, 4 + th % 2, false)
			case .Plains:
				if surf == .Grass && r < 8 do place_tree(c, lx, surf_y, lz, 4 + th, false)
			case .Savanna:
				if surf == .Grass && r < 4 do place_tree(c, lx, surf_y, lz, 4 + th % 2, false)
			case .Taiga:
				if surf == .Snow && r < 30 do place_tree(c, lx, surf_y, lz, 6 + th, true)
			case .Snow, .Mountains:
			// bare
			}
		}
	}
}
