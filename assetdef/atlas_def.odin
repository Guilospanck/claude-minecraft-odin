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
