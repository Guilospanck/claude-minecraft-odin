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
	Furnace,
	Iron,
	Glass,
	Cactus,
	Obsidian,
	Portal,
	Netherrack,
	Lava,
	Farmland,
	Wheat1, // crop stage 1 (just planted)
	Wheat2, // crop stage 2 (growing)
	Wheat3, // crop stage 3 (ripe — harvestable)
	Torch,
	Bed,
	Chest,
}

// Block light emitted (0..15). Opaque emitters still light the air around them.
block_emission :: proc(b: BlockId) -> u8 {
	#partial switch b {
	case .Glowstone:
		return 15
	case .Torch:
		return 13
	case .Lava:
		return 12
	case .Portal:
		return 11
	}
	return 0
}

// Cross-sprite blocks (two crossed quads with a cutout texture) instead of cubes.
block_is_sprite :: proc(b: BlockId) -> bool {
	#partial switch b {
	case .Wheat1, .Wheat2, .Wheat3, .Torch:
		return true
	}
	return false
}

block_is_crop :: proc(b: BlockId) -> bool {
	return b == .Wheat1 || b == .Wheat2 || b == .Wheat3
}

// The raycast stops here when targeting for break/place/interact. Solid blocks
// stop it (as does collision), and so do the non-solid sprites so you can aim
// at crops and torches.
block_stops_ray :: proc(b: BlockId) -> bool {
	return block_is_solid(b) || block_is_sprite(b)
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
	case .Air, .Water, .Lava, .Portal, .Wheat1, .Wheat2, .Wheat3, .Torch:
		return false
	}
	return true
}

// Fully occludes a neighbouring face (used for face culling + AO sampling).
block_is_opaque :: proc(b: BlockId) -> bool {
	#partial switch b {
	case .Air, .Water, .Glass, .Portal, .Wheat1, .Wheat2, .Wheat3, .Torch:
		return false
	}
	return true // Lava renders opaque (solid-looking) though it isn't collidable
}

// Drawn in the translucent pass (blended, no depth write).
block_is_translucent :: proc(b: BlockId) -> bool {
	return b == .Water || b == .Glass || b == .Portal
}

// Should a face of `cur` against neighbour `nb` be emitted?
face_visible :: proc(cur, nb: BlockId) -> bool {
	if cur == .Water || cur == .Lava {
		return nb == .Air // fluids show their surface / edges
	}
	if cur == .Glass || cur == .Portal {
		return !block_is_opaque(nb) && nb != cur // hide same-type seams
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
	case .Furnace:
		return ad.FURNACE
	case .Iron:
		return ad.IRON
	case .Glass:
		return ad.GLASS
	case .Cactus:
		return ad.CACTUS
	case .Obsidian:
		return ad.OBSIDIAN
	case .Portal:
		return ad.PORTAL
	case .Netherrack:
		return ad.NETHERRACK
	case .Lava:
		return ad.LAVA
	case .Farmland:
		return ad.FARMLAND
	case .Wheat1:
		return ad.WHEAT1
	case .Wheat2:
		return ad.WHEAT2
	case .Wheat3:
		return ad.WHEAT3
	case .Torch:
		return ad.TORCH
	case .Bed:
		return ad.BED
	case .Chest:
		return ad.CHEST
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
	case .Furnace:
		return {0.34, 0.34, 0.36}
	case .Iron:
		return {0.78, 0.78, 0.82}
	case .Glass:
		return {0.70, 0.85, 0.95}
	case .Cactus:
		return {0.25, 0.48, 0.25}
	case .Obsidian:
		return {0.14, 0.10, 0.20}
	case .Portal:
		return {0.55, 0.25, 0.75}
	case .Netherrack:
		return {0.45, 0.14, 0.14}
	case .Lava:
		return {0.95, 0.45, 0.12}
	case .Farmland:
		return {0.36, 0.24, 0.14}
	case .Wheat1:
		return {0.45, 0.62, 0.30}
	case .Wheat2:
		return {0.62, 0.66, 0.28}
	case .Wheat3:
		return {0.82, 0.70, 0.28}
	case .Torch:
		return {0.95, 0.80, 0.35}
	case .Bed:
		return {0.80, 0.20, 0.24}
	case .Chest:
		return {0.62, 0.44, 0.22}
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
	case .Furnace:
		return "Furnace"
	case .Iron:
		return "Iron"
	case .Glass:
		return "Glass"
	case .Cactus:
		return "Cactus"
	case .Obsidian:
		return "Obsidian"
	case .Portal:
		return "Portal"
	case .Netherrack:
		return "Netherrack"
	case .Lava:
		return "Lava"
	case .Farmland:
		return "Farmland"
	case .Wheat1:
		return "Wheat (young)"
	case .Wheat2:
		return "Wheat (growing)"
	case .Wheat3:
		return "Wheat (ripe)"
	case .Torch:
		return "Torch"
	case .Bed:
		return "Bed"
	case .Chest:
		return "Chest"
	}
	return "?"
}
