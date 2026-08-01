package main

Biome :: enum {
	Plains,
	Forest,
	Desert,
	Snow,
	Mountains,
}

@(private = "file")
classify_biome :: proc(temp, moist, mountain: f32, h: int) -> Biome {
	if mountain > 0.45 || h > SEA_LEVEL + 30 do return .Mountains
	if temp > 0.35 && moist < 0.0 do return .Desert
	if temp < -0.35 do return .Snow
	if moist > 0.15 do return .Forest
	return .Plains
}

@(private = "file")
surface_block :: proc(biome: Biome, h: int) -> BlockId {
	if h <= SEA_LEVEL + 1 do return .Sand // beach / seabed
	switch biome {
	case .Desert:
		return .Sand
	case .Snow:
		return .Snow
	case .Mountains:
		return h > SEA_LEVEL + 34 ? .Snow : .Stone
	case .Plains, .Forest:
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

// Trees are confined to columns whose canopy fits inside the chunk, so no
// cross-chunk writes are needed. Deterministic per (world x, world z).
@(private = "file")
generate_trees :: proc(
	c: ^Chunk,
	seed: u64,
	base_x, base_z: int,
	heights: []int,
	biomes: []Biome,
) {
	// Every column is eligible: the trunk is always in-bounds and chunk_set
	// silently clips any canopy leaves that spill past the chunk edge, so this
	// gives a uniform tree distribution instead of bald strips along seams.
	for lz in 0 ..< CHUNK_D {
		for lx in 0 ..< CHUNK_W {
			biome := biomes[lx + lz * CHUNK_W]
			if biome != .Plains && biome != .Forest do continue

			surf_y := heights[lx + lz * CHUNK_W] - 1
			if surf_y < SEA_LEVEL do continue // no trees on beaches / underwater
			if chunk_get(c, lx, surf_y, lz) != .Grass do continue // cave opening etc.

			wx := base_x + lx
			wz := base_z + lz
			hsh := hash_u64(
				seed ~ (u64(i64(wx)) * 0x9E3779B1) ~ (u64(i64(wz)) * 0x85EBCA77),
			)
			chance := biome == .Forest ? u64(40) : u64(8) // per 1000
			if hsh % 1000 >= chance do continue

			trunk_h := 4 + int((hsh >> 10) % 3) // 4..6
			trunk_base := surf_y + 1
			for i in 0 ..< trunk_h {
				chunk_set(c, lx, trunk_base + i, lz, .Wood)
			}

			crown := trunk_base + trunk_h - 1
			for dy in -1 ..= 1 {
				r := dy == 1 ? 1 : 2
				for dz in -r ..= r {
					for dx in -r ..= r {
						if dx == 0 && dz == 0 && dy < 1 do continue // don't overwrite trunk
						yy := crown + dy
						if chunk_get(c, lx + dx, yy, lz + dz) == .Air {
							chunk_set(c, lx + dx, yy, lz + dz, .Leaves)
						}
					}
				}
			}
			chunk_set(c, lx, crown + 2, lz, .Leaves) // little top
		}
	}
}
