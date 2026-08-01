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
