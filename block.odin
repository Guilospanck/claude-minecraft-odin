package main

import ad "assetdef"

BlockId :: enum u8 {
	Air = 0,
	Grass,
	Dirt,
	Stone,
	Sand,
	Water,
	Wood,
	Leaves,
	Snow,
	Bedrock,
	Ore,
	Glowstone,
}

// Block light emitted (0..15). Opaque emitters still light the air around them.
block_emission :: proc(b: BlockId) -> u8 {
	#partial switch b {
	case .Glowstone:
		return 15
	}
	return 0
}

Face :: enum {
	PosX,
	NegX,
	PosY,
	NegY,
	PosZ,
	NegZ,
}

// Participates in player collision.
block_is_solid :: proc(b: BlockId) -> bool {
	#partial switch b {
	case .Air, .Water:
		return false
	}
	return true
}

// Fully occludes a neighbouring face (used for face culling + AO sampling).
block_is_opaque :: proc(b: BlockId) -> bool {
	#partial switch b {
	case .Air, .Water:
		return false
	}
	return true
}

// Should a face of `cur` against neighbour `nb` be emitted?
face_visible :: proc(cur, nb: BlockId) -> bool {
	if cur == .Water {
		// water only shows its surface / edges against air
		return nb == .Air
	}
	return !block_is_opaque(nb)
}

// Atlas tile for a given block face (top/side/bottom differ for grass & wood).
block_tile :: proc(b: BlockId, f: Face) -> ad.Tile {
	switch b {
	case .Grass:
		if f == .PosY do return ad.GRASS_TOP
		if f == .NegY do return ad.DIRT
		return ad.GRASS_SIDE
	case .Dirt:
		return ad.DIRT
	case .Stone:
		return ad.STONE
	case .Sand:
		return ad.SAND
	case .Water:
		return ad.WATER
	case .Wood:
		if f == .PosY || f == .NegY do return ad.WOOD_TOP
		return ad.WOOD_SIDE
	case .Leaves:
		return ad.LEAVES
	case .Snow:
		return ad.SNOW
	case .Bedrock:
		return ad.BEDROCK
	case .Ore:
		return ad.ORE
	case .Glowstone:
		return ad.GLOWSTONE
	case .Air:
		return ad.STONE // never rendered
	}
	return ad.STONE
}

// Representative colour for a block, used to draw dropped-item cubes.
block_color :: proc(b: BlockId) -> Vec3 {
	switch b {
	case .Grass:
		return {0.40, 0.72, 0.35}
	case .Dirt:
		return {0.48, 0.35, 0.22}
	case .Stone:
		return {0.50, 0.50, 0.52}
	case .Sand:
		return {0.85, 0.80, 0.58}
	case .Water:
		return {0.20, 0.40, 0.80}
	case .Wood:
		return {0.45, 0.33, 0.20}
	case .Leaves:
		return {0.22, 0.50, 0.20}
	case .Snow:
		return {0.92, 0.94, 0.97}
	case .Bedrock:
		return {0.20, 0.20, 0.22}
	case .Ore:
		return {0.55, 0.50, 0.35}
	case .Glowstone:
		return {0.95, 0.85, 0.45}
	case .Air:
		return {0, 0, 0}
	}
	return {1, 0, 1}
}

block_name :: proc(b: BlockId) -> string {
	switch b {
	case .Air:
		return "Air"
	case .Grass:
		return "Grass"
	case .Dirt:
		return "Dirt"
	case .Stone:
		return "Stone"
	case .Sand:
		return "Sand"
	case .Water:
		return "Water"
	case .Wood:
		return "Wood"
	case .Leaves:
		return "Leaves"
	case .Snow:
		return "Snow"
	case .Bedrock:
		return "Bedrock"
	case .Ore:
		return "Ore"
	case .Glowstone:
		return "Glowstone"
	}
	return "?"
}
