// Shared atlas layout: tile coordinates + dimensions.
// Imported by both the game (root package) and the atlas generator tool so the
// UV lookup and the painted PNG never drift apart.
package assetdef

Tile :: [2]int // (tile_x, tile_y) in the 16x16 grid

TILE_PX     :: 16
ATLAS_TILES :: 16
ATLAS_PX    :: TILE_PX * ATLAS_TILES // 256

GRASS_TOP  :: Tile{0, 0}
GRASS_SIDE :: Tile{1, 0}
DIRT       :: Tile{2, 0}
STONE      :: Tile{3, 0}
SAND       :: Tile{4, 0}
WATER      :: Tile{5, 0}
WOOD_TOP   :: Tile{6, 0}
WOOD_SIDE  :: Tile{7, 0}
LEAVES     :: Tile{8, 0}
SNOW       :: Tile{9, 0}
BEDROCK    :: Tile{10, 0}
ORE        :: Tile{11, 0}
GLOWSTONE  :: Tile{12, 0}
FURNACE    :: Tile{13, 0}
IRON       :: Tile{14, 0}
GLASS      :: Tile{15, 0}
CACTUS     :: Tile{0, 1}
OBSIDIAN   :: Tile{1, 1}
PORTAL     :: Tile{2, 1}
NETHERRACK :: Tile{3, 1}
LAVA       :: Tile{4, 1}
FARMLAND   :: Tile{5, 1}
WHEAT1     :: Tile{6, 1} // sprite (transparent background)
WHEAT2     :: Tile{7, 1}
WHEAT3     :: Tile{8, 1}
TORCH      :: Tile{9, 1} // sprite
BED        :: Tile{10, 1}
CHEST      :: Tile{11, 1}
RED_SAND   :: Tile{0, 2}
DOOR       :: Tile{1, 2}
FENCE      :: Tile{2, 2}
COAL_ORE     :: Tile{3, 2}
GOLD_ORE     :: Tile{4, 2}
DIAMOND_ORE  :: Tile{5, 2}
GOLD         :: Tile{6, 2}
FLOWER_RED   :: Tile{7, 2} // sprite
FLOWER_YELLOW :: Tile{8, 2} // sprite
FLOWER_BLUE  :: Tile{9, 2} // sprite
FLOWER_PINK  :: Tile{10, 2} // sprite
FLOWER_WHITE :: Tile{11, 2} // sprite
TALL_GRASS   :: Tile{12, 2} // sprite
FERN         :: Tile{13, 2} // sprite
DEAD_BUSH    :: Tile{14, 2} // sprite
RAW_FOOD     :: Tile{15, 2} // item icon
COOKED_FOOD  :: Tile{0, 3} // item icon
BREAD        :: Tile{1, 3} // item icon
WHEAT_ITEM   :: Tile{2, 3} // item icon
SEEDS        :: Tile{3, 3} // item icon
PLANKS       :: Tile{4, 3}
STONE_BRICK  :: Tile{5, 3}
BRICKS       :: Tile{6, 3}
COBBLESTONE  :: Tile{7, 3}
LADDER       :: Tile{8, 3} // sprite (transparent background)
WOOL_WHITE   :: Tile{9, 3}
WOOL_RED     :: Tile{10, 3}
WOOL_YELLOW  :: Tile{11, 3}
WOOL_BLUE    :: Tile{12, 3}
PODZOL_TOP       :: Tile{13, 3}
PODZOL_SIDE      :: Tile{14, 3}
COARSE_DIRT      :: Tile{15, 3}
MUD              :: Tile{0, 4}
GRAVEL           :: Tile{1, 4}
TERRACOTTA       :: Tile{2, 4}
TERRACOTTA_WHITE :: Tile{3, 4}
TERRACOTTA_BROWN :: Tile{4, 4}
ICE              :: Tile{5, 4}
LILY_PAD         :: Tile{6, 4} // sprite/flat (transparent background)
BAMBOO           :: Tile{7, 4} // sprite (transparent background)
FEATHER          :: Tile{8, 4} // item icon
LEATHER          :: Tile{9, 4} // item icon
BONE             :: Tile{10, 4} // item icon
ROTTEN_FLESH     :: Tile{11, 4} // item icon
ARROW            :: Tile{12, 4} // item icon
GUNPOWDER        :: Tile{13, 4} // item icon
SUGAR_CANE       :: Tile{14, 4} // sprite (transparent background)
KELP             :: Tile{15, 4} // sprite (transparent background)
RED_MUSHROOM     :: Tile{0, 5} // sprite (transparent background)
BROWN_MUSHROOM   :: Tile{1, 5} // sprite (transparent background)
PUMPKIN          :: Tile{2, 5} // side (carved face)
PUMPKIN_TOP      :: Tile{3, 5} // top (ribbed stem)
MOSSY_COBBLE     :: Tile{4, 5}
SEAGRASS         :: Tile{5, 5} // sprite (transparent background)
CORAL_PINK       :: Tile{6, 5}
CORAL_BLUE       :: Tile{7, 5}
CORAL_PURPLE     :: Tile{8, 5}
SPAWNER          :: Tile{9, 5}
BOW              :: Tile{10, 5} // item icon
FISHING_ROD      :: Tile{11, 5} // item icon
