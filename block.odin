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
	RedSand,
	Door,
	Fence,
	CoalOre,
	GoldOre,
	DiamondOre,
	Gold, // smelted from GoldOre
	Slab,
	FlowerRed,
	FlowerYellow,
	FlowerBlue,
	FlowerPink,
	FlowerWhite,
	TallGrass, // grassy tuft
	Fern, // forest/taiga/jungle understory
	DeadBush, // dry twigs: desert/badlands/savanna
	Stair, // stepped block; facing 0..3 in w.stairs
	// Inventory-only items (never placed in the world) — held/dragged like any
	// stack, but block_is_item gates them out of block placement.
	RawFood,
	CookedFood,
	Bread,
	Wheat, // harvested crop item (Wheat1..3 are the growing block stages)
	Seeds,
	// Building blocks (craftable, placeable) — appended at the end so existing
	// block ids stay stable across saves.
	Planks,
	StoneBrick,
	Bricks,
	Cobblestone,
	GlassPane, // thin translucent window panel (connects to neighbours)
	Ladder, // climbable sprite lattice
	Wall, // chunky cobblestone wall (connects to neighbours)
	FenceGate, // wooden gate bar (orients to fence/wall neighbours)
	// Dyed wool (full cubes) + matching carpets (thin floor cover). Carpets
	// share the wool atlas tile; only the geometry differs.
	WoolWhite,
	WoolRed,
	WoolYellow,
	WoolBlue,
	CarpetWhite,
	CarpetRed,
	CarpetYellow,
	CarpetBlue,
	// Surface-rule blocks: biome-specific ground cover / strata.
	Podzol, // taiga forest floor
	CoarseDirt, // rough dirt patches (savanna/taiga)
	Mud, // swamp wet ground
	Gravel, // shores + riverbeds
	Terracotta, // badlands base band
	TerracottaWhite, // badlands pale band
	TerracottaBrown, // badlands dark band
	// Biome-signature blocks/plants.
	Ice, // frozen water in the cold biomes
	LilyPad, // flat pad floating on swamp water
	Bamboo, // tall jungle stalk (sprite)
	// Mob-drop items (inventory-only, like the food items) — appended at the end
	// so existing block ids stay stable across saves.
	Feather, // dropped by chickens
	Leather, // dropped by cows, horses, deer, ...
	Bone, // dropped by skeletons
	RottenFlesh, // dropped by zombies
	Arrow, // dropped by skeletons
	Gunpowder, // dropped by ghasts
	// Extra flora.
	SugarCane, // tall reed sprite growing on sand/grass beside water
	Kelp, // underwater strand sprite growing up from the ocean floor
	RedMushroom, // shaded-forest/swamp floor sprite
	BrownMushroom, // shaded-forest/taiga floor sprite
	Pumpkin, // orange gourd cube, patches in grassy biomes
	MossyCobble, // mossy cobblestone; boulders in taiga/mountains
}

// Inventory-only items (food/seeds): they live in slots and stack like blocks
// but can never be placed into the world.
block_is_item :: proc(b: BlockId) -> bool {
	#partial switch b {
	case .RawFood,
	     .CookedFood,
	     .Bread,
	     .Wheat,
	     .Seeds,
	     .Feather,
	     .Leather,
	     .Bone,
	     .RottenFlesh,
	     .Arrow,
	     .Gunpowder:
		return true
	}
	return false
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
	case .Wheat1,
	     .Wheat2,
	     .Wheat3,
	     .Torch,
	     .FlowerRed,
	     .FlowerYellow,
	     .FlowerBlue,
	     .FlowerPink,
	     .FlowerWhite,
	     .TallGrass,
	     .Fern,
	     .DeadBush,
	     .Ladder,
	     .Bamboo,
	     .SugarCane,
	     .Kelp,
	     .RedMushroom,
	     .BrownMushroom:
		return true
	}
	return false
}

// Sprite plants (flowers/grass/ferns/bushes) that scatter on the surface and
// share the same non-solid, non-occluding, ray-stopping behaviour.
block_is_plant :: proc(b: BlockId) -> bool {
	#partial switch b {
	case .FlowerRed, .FlowerYellow, .FlowerBlue, .FlowerPink, .FlowerWhite, .TallGrass, .Fern, .DeadBush, .Bamboo, .SugarCane, .Kelp, .RedMushroom, .BrownMushroom:
		return true
	}
	return false
}

// Low-box blocks: rendered as a squat box (see emit_lowbox in mesher.odin)
// instead of a full 1x1x1 cube, so furniture doesn't look like "just a
// block". Still solid for collision (block_is_solid below) — the visual
// shrink is cosmetic only, same trade-off sprites already accept.
block_is_lowbox :: proc(b: BlockId) -> bool {
	return b == .Bed || b == .Slab
}

// Fraction of a full cell's height a low-box block's top face sits at.
LOWBOX_HEIGHT :: f32(0.5625)

// Carpets: a paper-thin floor cover (own low-box height, walked over freely).
CARPET_HEIGHT :: f32(0.0625)
block_is_carpet :: proc(b: BlockId) -> bool {
	return(
		b == .CarpetWhite ||
		b == .CarpetRed ||
		b == .CarpetYellow ||
		b == .CarpetBlue ||
		b == .LilyPad \
	)
}

block_is_crop :: proc(b: BlockId) -> bool {
	return b == .Wheat1 || b == .Wheat2 || b == .Wheat3
}

// The raycast stops here when targeting for break/place/interact. Solid blocks
// stop it (as does collision), and so do the non-solid sprites so you can aim
// at crops and torches.
block_stops_ray :: proc(b: BlockId) -> bool {
	return block_is_solid(b) || block_is_sprite(b) || block_is_carpet(b)
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
	case .Air, .Water, .Lava, .Portal, .Wheat1, .Wheat2, .Wheat3, .Torch, .Ladder:
		return false
	}
	if block_is_plant(b) || block_is_item(b) || block_is_carpet(b) do return false
	return true
}

// Fully occludes a neighbouring face (used for face culling + AO sampling).
block_is_opaque :: proc(b: BlockId) -> bool {
	#partial switch b {
	case .Air,
	     .Water,
	     .Glass,
	     .Portal,
	     .Wheat1,
	     .Wheat2,
	     .Wheat3,
	     .Torch,
	     .Door,
	     .Fence,
	     .Stair,
	     .GlassPane,
	     .Ladder,
	     .Wall,
	     .FenceGate,
	     .Ice:
		return false
	}
	if block_is_plant(b) || block_is_carpet(b) do return false
	return true // Lava renders opaque (solid-looking) though it isn't collidable
}

// Drawn in the translucent pass (blended, no depth write).
block_is_translucent :: proc(b: BlockId) -> bool {
	return b == .Water || b == .Glass || b == .Portal || b == .GlassPane || b == .Ice
}

// Should a face of `cur` against neighbour `nb` be emitted?
face_visible :: proc(cur, nb: BlockId) -> bool {
	if cur == .Water || cur == .Lava {
		return nb == .Air // fluids show their surface / edges
	}
	if cur == .Glass || cur == .Portal || cur == .Ice {
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
	case .RedSand:
		return ad.RED_SAND
	case .Door:
		return ad.DOOR
	case .Fence:
		return ad.FENCE
	case .CoalOre:
		return ad.COAL_ORE
	case .GoldOre:
		return ad.GOLD_ORE
	case .DiamondOre:
		return ad.DIAMOND_ORE
	case .Gold:
		return ad.GOLD
	case .Slab:
		return ad.STONE
	case .FlowerRed:
		return ad.FLOWER_RED
	case .FlowerYellow:
		return ad.FLOWER_YELLOW
	case .FlowerBlue:
		return ad.FLOWER_BLUE
	case .FlowerPink:
		return ad.FLOWER_PINK
	case .FlowerWhite:
		return ad.FLOWER_WHITE
	case .TallGrass:
		return ad.TALL_GRASS
	case .Fern:
		return ad.FERN
	case .DeadBush:
		return ad.DEAD_BUSH
	case .Stair:
		return ad.STONE
	case .RawFood:
		return ad.RAW_FOOD
	case .CookedFood:
		return ad.COOKED_FOOD
	case .Bread:
		return ad.BREAD
	case .Wheat:
		return ad.WHEAT_ITEM
	case .Seeds:
		return ad.SEEDS
	case .Feather:
		return ad.FEATHER
	case .Leather:
		return ad.LEATHER
	case .Bone:
		return ad.BONE
	case .RottenFlesh:
		return ad.ROTTEN_FLESH
	case .Arrow:
		return ad.ARROW
	case .Gunpowder:
		return ad.GUNPOWDER
	case .Planks:
		return ad.PLANKS
	case .StoneBrick:
		return ad.STONE_BRICK
	case .Bricks:
		return ad.BRICKS
	case .Cobblestone:
		return ad.COBBLESTONE
	case .GlassPane:
		return ad.GLASS
	case .Ladder:
		return ad.LADDER
	case .Wall:
		return ad.COBBLESTONE
	case .FenceGate:
		return ad.PLANKS
	case .Podzol:
		if f == .PosY do return ad.PODZOL_TOP
		if f == .NegY do return ad.DIRT
		return ad.PODZOL_SIDE
	case .CoarseDirt:
		return ad.COARSE_DIRT
	case .Mud:
		return ad.MUD
	case .Gravel:
		return ad.GRAVEL
	case .Terracotta:
		return ad.TERRACOTTA
	case .TerracottaWhite:
		return ad.TERRACOTTA_WHITE
	case .TerracottaBrown:
		return ad.TERRACOTTA_BROWN
	case .Ice:
		return ad.ICE
	case .LilyPad:
		return ad.LILY_PAD
	case .Bamboo:
		return ad.BAMBOO
	case .SugarCane:
		return ad.SUGAR_CANE
	case .Kelp:
		return ad.KELP
	case .RedMushroom:
		return ad.RED_MUSHROOM
	case .BrownMushroom:
		return ad.BROWN_MUSHROOM
	case .Pumpkin:
		if f == .PosY do return ad.PUMPKIN_TOP
		return ad.PUMPKIN
	case .MossyCobble:
		return ad.MOSSY_COBBLE
	case .WoolWhite, .CarpetWhite:
		return ad.WOOL_WHITE
	case .WoolRed, .CarpetRed:
		return ad.WOOL_RED
	case .WoolYellow, .CarpetYellow:
		return ad.WOOL_YELLOW
	case .WoolBlue, .CarpetBlue:
		return ad.WOOL_BLUE
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
	case .RedSand:
		return {0.71, 0.39, 0.22}
	case .Door:
		return {0.55, 0.40, 0.24}
	case .Fence:
		return {0.42, 0.30, 0.18}
	case .CoalOre:
		return {0.22, 0.22, 0.24}
	case .GoldOre:
		return {0.72, 0.60, 0.20}
	case .DiamondOre:
		return {0.45, 0.85, 0.85}
	case .Gold:
		return {0.90, 0.76, 0.22}
	case .Slab:
		return {0.50, 0.50, 0.52}
	case .FlowerRed:
		return {0.80, 0.16, 0.20}
	case .FlowerYellow:
		return {0.90, 0.80, 0.15}
	case .FlowerBlue:
		return {0.30, 0.42, 0.82}
	case .FlowerPink:
		return {0.90, 0.55, 0.70}
	case .FlowerWhite:
		return {0.95, 0.95, 0.95}
	case .TallGrass:
		return {0.40, 0.68, 0.32}
	case .Fern:
		return {0.32, 0.56, 0.28}
	case .DeadBush:
		return {0.55, 0.42, 0.22}
	case .Stair:
		return {0.50, 0.50, 0.52}
	case .RawFood:
		return {0.72, 0.28, 0.22}
	case .CookedFood:
		return {0.55, 0.35, 0.20}
	case .Bread:
		return {0.78, 0.58, 0.30}
	case .Wheat:
		return {0.82, 0.70, 0.28}
	case .Seeds:
		return {0.55, 0.62, 0.30}
	case .Feather:
		return {0.92, 0.94, 0.96}
	case .Leather:
		return {0.62, 0.42, 0.24}
	case .Bone:
		return {0.90, 0.89, 0.80}
	case .RottenFlesh:
		return {0.46, 0.34, 0.28}
	case .Arrow:
		return {0.70, 0.66, 0.58}
	case .Gunpowder:
		return {0.30, 0.30, 0.32}
	case .Planks:
		return {0.62, 0.46, 0.26}
	case .StoneBrick:
		return {0.46, 0.46, 0.48}
	case .Bricks:
		return {0.62, 0.30, 0.24}
	case .Cobblestone:
		return {0.44, 0.44, 0.46}
	case .GlassPane:
		return {0.70, 0.85, 0.95}
	case .Ladder:
		return {0.55, 0.40, 0.22}
	case .Wall:
		return {0.44, 0.44, 0.46}
	case .FenceGate:
		return {0.55, 0.40, 0.24}
	case .Podzol:
		return {0.36, 0.26, 0.13}
	case .CoarseDirt:
		return {0.42, 0.31, 0.20}
	case .Mud:
		return {0.28, 0.24, 0.20}
	case .Gravel:
		return {0.50, 0.48, 0.47}
	case .Terracotta:
		return {0.63, 0.36, 0.22}
	case .TerracottaWhite:
		return {0.80, 0.68, 0.56}
	case .TerracottaBrown:
		return {0.40, 0.26, 0.16}
	case .Ice:
		return {0.68, 0.80, 0.95}
	case .LilyPad:
		return {0.28, 0.55, 0.28}
	case .Bamboo:
		return {0.48, 0.68, 0.28}
	case .SugarCane:
		return {0.55, 0.76, 0.44}
	case .Kelp:
		return {0.28, 0.52, 0.32}
	case .RedMushroom:
		return {0.78, 0.16, 0.14}
	case .BrownMushroom:
		return {0.60, 0.44, 0.30}
	case .Pumpkin:
		return {0.85, 0.52, 0.14}
	case .MossyCobble:
		return {0.42, 0.50, 0.36}
	case .WoolWhite, .CarpetWhite:
		return {0.93, 0.93, 0.95}
	case .WoolRed, .CarpetRed:
		return {0.75, 0.20, 0.22}
	case .WoolYellow, .CarpetYellow:
		return {0.88, 0.78, 0.22}
	case .WoolBlue, .CarpetBlue:
		return {0.25, 0.35, 0.72}
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
	case .RedSand:
		return "Red Sand"
	case .Door:
		return "Door"
	case .Fence:
		return "Fence"
	case .CoalOre:
		return "Coal Ore"
	case .GoldOre:
		return "Gold Ore"
	case .DiamondOre:
		return "Diamond Ore"
	case .Gold:
		return "Gold"
	case .Slab:
		return "Slab"
	case .FlowerRed:
		return "Red Flower"
	case .FlowerYellow:
		return "Yellow Flower"
	case .FlowerBlue:
		return "Blue Flower"
	case .FlowerPink:
		return "Pink Flower"
	case .FlowerWhite:
		return "White Flower"
	case .TallGrass:
		return "Tall Grass"
	case .Fern:
		return "Fern"
	case .DeadBush:
		return "Dead Bush"
	case .Stair:
		return "Stairs"
	case .RawFood:
		return "Raw Food"
	case .CookedFood:
		return "Cooked Food"
	case .Bread:
		return "Bread"
	case .Wheat:
		return "Wheat"
	case .Seeds:
		return "Seeds"
	case .Feather:
		return "Feather"
	case .Leather:
		return "Leather"
	case .Bone:
		return "Bone"
	case .RottenFlesh:
		return "Rotten Flesh"
	case .Arrow:
		return "Arrow"
	case .Gunpowder:
		return "Gunpowder"
	case .Planks:
		return "Planks"
	case .StoneBrick:
		return "Stone Bricks"
	case .Bricks:
		return "Bricks"
	case .Cobblestone:
		return "Cobblestone"
	case .GlassPane:
		return "Glass Pane"
	case .Ladder:
		return "Ladder"
	case .Wall:
		return "Cobblestone Wall"
	case .FenceGate:
		return "Fence Gate"
	case .WoolWhite:
		return "White Wool"
	case .WoolRed:
		return "Red Wool"
	case .WoolYellow:
		return "Yellow Wool"
	case .WoolBlue:
		return "Blue Wool"
	case .CarpetWhite:
		return "White Carpet"
	case .CarpetRed:
		return "Red Carpet"
	case .CarpetYellow:
		return "Yellow Carpet"
	case .CarpetBlue:
		return "Blue Carpet"
	case .Podzol:
		return "Podzol"
	case .CoarseDirt:
		return "Coarse Dirt"
	case .Mud:
		return "Mud"
	case .Gravel:
		return "Gravel"
	case .Terracotta:
		return "Terracotta"
	case .TerracottaWhite:
		return "White Terracotta"
	case .TerracottaBrown:
		return "Brown Terracotta"
	case .Ice:
		return "Ice"
	case .LilyPad:
		return "Lily Pad"
	case .Bamboo:
		return "Bamboo"
	case .SugarCane:
		return "Sugar Cane"
	case .Kelp:
		return "Kelp"
	case .RedMushroom:
		return "Red Mushroom"
	case .BrownMushroom:
		return "Brown Mushroom"
	case .Pumpkin:
		return "Pumpkin"
	case .MossyCobble:
		return "Mossy Cobblestone"
	}
	return "?"
}
