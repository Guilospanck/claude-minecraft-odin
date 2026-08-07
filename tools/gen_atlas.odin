// Atlas generator: writes assets/atlas.png (256x256 RGBA, 16x16 tiles of 16px).
// Pure Odin — uses vendor:stb/image write_png. Run from the repo root:
//   odin run tools
package main

import "core:fmt"
import "core:os"
import ad "../assetdef"
import stbiw "vendor:stb/image"

Color :: [4]u8

pixels: []u8

set_px :: proc(x, y: int, c: Color) {
	i := (y * ad.ATLAS_PX + x) * 4
	pixels[i + 0] = c.r
	pixels[i + 1] = c.g
	pixels[i + 2] = c.b
	pixels[i + 3] = c.a
}

// Deterministic per-pixel hash -> small signed jitter, so tiles look grainy
// without needing a RNG (keeps the tool reproducible).
jitter :: proc(x, y, amp: int) -> int {
	h := u32(x) * 374761393 + u32(y) * 668265263
	h = (h ~ (h >> 13)) * 1274126177
	h ~= h >> 16
	return int(h % u32(2 * amp + 1)) - amp
}

clampb :: proc(v: int) -> u8 {
	if v < 0 do return 0
	if v > 255 do return 255
	return u8(v)
}

shade :: proc(base: Color, d: int) -> Color {
	return Color{clampb(int(base.r) + d), clampb(int(base.g) + d), clampb(int(base.b) + d), base.a}
}

// Fill one 16x16 tile. `kind` selects a small pattern on top of `base`.
paint :: proc(tile: ad.Tile, base: Color, kind: string) {
	ox := tile.x * ad.TILE_PX
	oy := tile.y * ad.TILE_PX
	for py in 0 ..< ad.TILE_PX {
		for px in 0 ..< ad.TILE_PX {
			gx := ox + px
			gy := oy + py
			c := shade(base, jitter(gx, gy, 12))

			switch kind {
			case "grass_side":
				// green cap over dirt body
				if py < 4 {
					c = shade(Color{74, 150, 60, 255}, jitter(gx, gy, 14))
				} else {
					c = shade(Color{124, 90, 58, 255}, jitter(gx, gy, 12))
				}
			case "wood_top":
				// concentric rings around tile center
				dx := px - 8
				dy := py - 8
				r := dx * dx + dy * dy
				ring := (r / 8) % 2
				c = shade(base, jitter(gx, gy, 8) + (ring == 0 ? -22 : 10))
			case "wood_side":
				// vertical bark streaks
				streak := (px % 5 == 0) || (px % 7 == 3)
				c = shade(base, jitter(gx, gy, 10) + (streak ? -26 : 6))
			case "bedrock":
				spec := ((jitter(gx, gy, 100) + 100) % 5) == 0
				c = spec ? Color{18, 18, 22, 255} : shade(base, jitter(gx, gy, 16))
			case "ore":
				spec := ((jitter(gx * 3, gy * 3, 100) + 100) % 7) < 2
				c = spec ? Color{210, 170, 60, 255} : shade(base, jitter(gx, gy, 10))
			case "glow":
				// bright warm cells with a darker mortar grid
				grid := (px % 8 == 0) || (py % 8 == 0)
				c = grid ? Color{200, 150, 40, 255} : shade(Color{250, 224, 120, 255}, jitter(gx, gy, 14))
			case "furnace":
				// dark stone with a black opening in the lower-front
				if px >= 4 && px <= 11 && py >= 8 && py <= 13 {
					c = Color{18, 16, 16, 255}
				} else {
					c = shade(Color{86, 86, 90, 255}, jitter(gx, gy, 12))
				}
			case "iron":
				band := (py % 6 < 3)
				c = shade(Color{198, 198, 205, 255}, jitter(gx, gy, 10) + (band ? 6 : -8))
			case "glass":
				edge := px == 0 || py == 0 || px == 15 || py == 15
				c = edge ? Color{210, 232, 244, 255} : shade(Color{176, 214, 232, 255}, jitter(gx, gy, 6))
			case "cactus":
				ridge := (px % 5 == 0)
				c = shade(Color{54, 112, 54, 255}, jitter(gx, gy, 10) + (ridge ? -20 : 8))
			case "coal_ore":
				spec := ((jitter(gx * 3, gy * 3, 100) + 100) % 6) < 2
				c = spec ? Color{20, 20, 22, 255} : shade(base, jitter(gx, gy, 10))
			case "gold_ore":
				spec := ((jitter(gx * 3, gy * 3, 100) + 100) % 8) < 2
				c = spec ? Color{240, 200, 60, 255} : shade(base, jitter(gx, gy, 10))
			case "diamond_ore":
				spec := ((jitter(gx * 3, gy * 3, 100) + 100) % 9) < 2
				c = spec ? Color{140, 235, 230, 255} : shade(base, jitter(gx, gy, 10))
			case "gold":
				band := (py % 6 < 3)
				c = shade(Color{224, 188, 60, 255}, jitter(gx, gy, 10) + (band ? 10 : -10))
			case "flower_red", "flower_yellow", "flower_blue", "flower_pink", "flower_white":
				c = Color{0, 0, 0, 0} // transparent background (cutout sprite)
				stem := (px == 7 || px == 8) && py >= 9
				petal := px >= 4 && px <= 11 && py >= 3 && py <= 9
				center := px >= 6 && px <= 9 && py >= 5 && py <= 7
				if stem {
					c = shade(Color{60, 120, 50, 255}, jitter(gx, gy, 8))
					c.a = 255
				} else if petal {
					pc: Color
					switch kind {
					case "flower_red":
						pc = Color{204, 40, 48, 255}
					case "flower_yellow":
						pc = Color{224, 196, 40, 255}
					case "flower_blue":
						pc = Color{72, 108, 210, 255}
					case "flower_pink":
						pc = Color{228, 140, 178, 255}
					case:
						pc = Color{238, 238, 240, 255} // white
					}
					if center do pc = Color{230, 190, 60, 255}
					c = shade(pc, jitter(gx, gy, 10))
					c.a = 255
				}
			case "tall_grass":
				c = Color{0, 0, 0, 0}
				// several upright blades of varying height
				blade := px == 2 || px == 5 || px == 8 || px == 11 || px == 13
				top := 4 + (int(px) % 3) * 2
				if blade && py >= top {
					c = shade(Color{70, 148, 60, 255}, jitter(gx, gy, 14))
					c.a = 255
				}
			case "fern":
				c = Color{0, 0, 0, 0}
				// a central stem with fronds angling out to either side
				stem := px == 7 || px == 8
				frond := (abs(int(px) - 7) == (15 - int(py)) / 2) && py >= 4
				if (stem && py >= 3) || frond {
					c = shade(Color{58, 120, 52, 255}, jitter(gx, gy, 12))
					c.a = 255
				}
			case "dead_bush":
				c = Color{0, 0, 0, 0}
				// sparse dry twigs splaying up from the base
				twig := (px == 7 || px == 8) && py >= 5
				branch := (abs(int(px) - 7) == (13 - int(py))) && py >= 5 && py <= 11
				if twig || branch {
					c = shade(Color{140, 104, 52, 255}, jitter(gx, gy, 16))
					c.a = 255
				}
			case "raw_food":
				c = Color{0, 0, 0, 0}
				// a rounded raw meat cut: pink flesh with a bone nub
				meat := (px - 8) * (px - 8) + (py - 9) * (py - 9) < 28
				bone := (px - 5) * (px - 5) + (py - 4) * (py - 4) < 5
				if bone {c = Color{232, 224, 208, 255}} else if meat {c = shade(Color{198, 96, 96, 255}, jitter(gx, gy, 14));c.a = 255}
			case "cooked_food":
				c = Color{0, 0, 0, 0}
				meat := (px - 8) * (px - 8) + (py - 9) * (py - 9) < 28
				bone := (px - 5) * (px - 5) + (py - 4) * (py - 4) < 5
				if bone {c = Color{232, 224, 208, 255}} else if meat {c = shade(Color{150, 92, 48, 255}, jitter(gx, gy, 14));c.a = 255}
			case "bread":
				c = Color{0, 0, 0, 0}
				// a rounded golden loaf with a few score marks
				loaf := px >= 3 && px <= 12 && py >= 5 && py <= 12 && !((px <= 4 || px >= 11) && (py <= 6 || py >= 11))
				if loaf {
					score := (px % 3 == 0) && py <= 7
					c = shade(score ? Color{150, 100, 44, 255} : Color{198, 148, 74, 255}, jitter(gx, gy, 12))
					c.a = 255
				}
			case "wheat_item":
				c = Color{0, 0, 0, 0}
				// a bound sheaf: vertical golden stalks with grain heads
				stalk := px == 5 || px == 8 || px == 11
				if stalk && py >= 2 {
					c = shade(py < 7 ? Color{224, 196, 92, 255} : Color{198, 160, 68, 255}, jitter(gx, gy, 12))
					c.a = 255
				}
			case "seeds":
				c = Color{0, 0, 0, 0}
				// a small scatter of pale green seeds
				seed := ((px * 5 + py * 3) % 7 == 0) && px >= 3 && px <= 12 && py >= 5 && py <= 11
				if seed {
					c = shade(Color{150, 168, 92, 255}, jitter(gx, gy, 12))
					c.a = 255
				}
			case "obsidian":
				spec := ((jitter(gx * 2, gy * 2, 100) + 100) % 9) < 2
				c = spec ? Color{80, 50, 110, 255} : shade(Color{28, 20, 40, 255}, jitter(gx, gy, 8))
			case "portal":
				sw := ((jitter(gx, gy * 2, 100) + 100) % 4) < 1
				c = sw ? Color{170, 90, 220, 255} : shade(Color{110, 45, 170, 255}, jitter(gx, gy, 16))
			case "netherrack":
				c = shade(Color{110, 34, 34, 255}, jitter(gx, gy, 16))
			case "lava":
				hot := ((jitter(gx, gy, 100) + 100) % 3) < 1
				c = hot ? Color{255, 180, 40, 255} : shade(Color{224, 96, 24, 255}, jitter(gx, gy, 18))
			case "water":
				c = shade(base, jitter(gx, gy, 8))
			case "red_sand":
				// horizontal mesa strata: alternating dark/light bands
				band := (py / 3) % 2
				c = shade(base, jitter(gx, gy, 10) + (band == 0 ? -14 : 10))
			case "fence":
				// vertical post grain with a horizontal rail band, like a
				// picket fence post - the mesher renders this as a thin box
				// (see emit_box in mesher.odin), so the texture just needs
				// to read as wood, not carry the cutout shape itself
				rail := (py >= 5 && py <= 6) || (py >= 10 && py <= 11)
				c = shade(base, jitter(gx, gy, 10) + (rail ? -18 : 0))
			case "door":
				// two raised wooden panels with a knob
				panel := (py >= 2 && py <= 6) || (py >= 9 && py <= 13)
				knob := px == 12 && py >= 7 && py <= 8
				if knob {
					c = Color{224, 200, 90, 255}
				} else if panel {
					c = shade(Color{112, 78, 42, 255}, jitter(gx, gy, 10))
				} else {
					c = shade(base, jitter(gx, gy, 8))
				}
			case "farmland":
				furrow := (py % 5) == 2
				c =
					py < 3 \
					? shade(Color{80, 54, 32, 255}, jitter(gx, gy, 8)) \
					: shade(Color{104, 70, 40, 255}, jitter(gx, gy, 10) + (furrow ? -26 : 4))
			case "bed":
				if py < 5 {
					c = shade(Color{226, 228, 232, 255}, jitter(gx, gy, 6)) // pillow
				} else {
					edge := px == 0 || px == 15 || py == 15
					c =
						edge \
						? Color{120, 70, 40, 255} \
						: shade(Color{176, 44, 52, 255}, jitter(gx, gy, 12))
				}
			case "wheat1", "wheat2", "wheat3":
				c = Color{0, 0, 0, 0} // transparent background (cutout sprite)
				stage := kind == "wheat3" ? 3 : (kind == "wheat2" ? 2 : 1)
				height := stage == 1 ? 6 : (stage == 2 ? 11 : 15)
				top := ad.TILE_PX - height
				stalk := px == 3 || px == 4 || px == 6 || px == 9 || px == 10 || px == 12
				if stalk && py >= top {
					col := stage == 1 \
						? Color{92, 150, 62, 255} \
						: (stage == 2 ? Color{150, 168, 72, 255} : Color{206, 178, 74, 255})
					if stage == 3 && py < top + 5 do col = Color{230, 205, 96, 255} // ripe head
					c = shade(col, jitter(gx, gy, 10))
					c.a = 255
				}
			case "chest":
				// wooden box with a darker lid seam, iron latch, plank border
				border := px == 0 || px == 15 || py == 0 || py == 15
				latch := px >= 7 && px <= 8 && py >= 6 && py <= 9
				seam := py == 5
				if latch {
					c = Color{60, 55, 50, 255}
				} else if seam || border {
					c = shade(Color{96, 66, 32, 255}, jitter(gx, gy, 6))
				} else {
					c = shade(Color{150, 106, 54, 255}, jitter(gx, gy, 10))
				}
			case "torch":
				c = Color{0, 0, 0, 0}
				if (px == 7 || px == 8) && py >= 5 { 	// stick
					c = shade(Color{122, 82, 42, 255}, jitter(gx, gy, 8))
					c.a = 255
				}
				if px >= 6 && px <= 9 && py >= 2 && py <= 5 { 	// flame
					c = shade(Color{255, 208, 92, 255}, jitter(gx, gy, 12))
					c.a = 255
				}
			case "planks":
				// horizontal plank boards separated by dark seams
				seam := (py % 5 == 0) || (px == 0)
				nail := (py % 5 == 2) && (px == 2 || px == 13)
				if nail {
					c = Color{60, 42, 24, 255}
				} else {
					c = shade(base, jitter(gx, gy, 8) + (seam ? -30 : 6))
				}
			case "stone_brick":
				// grey brick courses, offset every other row, pale mortar
				row := py / 4
				offset := (row % 2) * 4
				mortar := (py % 4 == 0) || ((px + offset) % 8 == 0)
				c = shade(base, jitter(gx, gy, 8) + (mortar ? 26 : -6))
			case "bricks":
				// red bricks with light mortar lines, running-bond offset
				row := py / 4
				offset := (row % 2) * 4
				mortar := (py % 4 == 0) || ((px + offset) % 8 == 0)
				c =
					mortar \
					? shade(Color{180, 168, 156, 255}, jitter(gx, gy, 6)) \
					: shade(base, jitter(gx, gy, 10))
			case "cobble":
				// rounded cobbles: dark mortar where a cell hash dips low
				h := (jitter(gx / 2 * 2, gy / 2 * 2, 100) + 100) % 10
				c =
					h < 3 \
					? shade(Color{70, 70, 74, 255}, jitter(gx, gy, 8)) \
					: shade(base, jitter(gx, gy, 14))
			case:
				// plain grain (already applied)
			}
			set_px(gx, gy, c)
		}
	}
}

main :: proc() {
	pixels = make([]u8, ad.ATLAS_PX * ad.ATLAS_PX * 4)
	defer delete(pixels)

	// Default background = magenta so any unused/mislabelled tile is obvious.
	for i := 0; i < len(pixels); i += 4 {
		pixels[i + 0] = 255
		pixels[i + 1] = 0
		pixels[i + 2] = 255
		pixels[i + 3] = 255
	}

	paint(ad.GRASS_TOP, Color{78, 156, 62, 255}, "")
	paint(ad.GRASS_SIDE, Color{124, 90, 58, 255}, "grass_side")
	paint(ad.DIRT, Color{124, 90, 58, 255}, "")
	paint(ad.STONE, Color{128, 128, 132, 255}, "")
	paint(ad.SAND, Color{216, 204, 150, 255}, "")
	paint(ad.WATER, Color{44, 92, 200, 255}, "water")
	paint(ad.WOOD_TOP, Color{162, 122, 72, 255}, "wood_top")
	paint(ad.WOOD_SIDE, Color{110, 82, 46, 255}, "wood_side")
	paint(ad.LEAVES, Color{46, 104, 42, 255}, "")
	paint(ad.SNOW, Color{234, 240, 246, 255}, "")
	paint(ad.BEDROCK, Color{42, 42, 48, 255}, "bedrock")
	paint(ad.ORE, Color{128, 128, 132, 255}, "ore")
	paint(ad.GLOWSTONE, Color{240, 210, 110, 255}, "glow")
	paint(ad.FURNACE, Color{86, 86, 90, 255}, "furnace")
	paint(ad.IRON, Color{198, 198, 205, 255}, "iron")
	paint(ad.GLASS, Color{176, 214, 232, 255}, "glass")
	paint(ad.CACTUS, Color{54, 112, 54, 255}, "cactus")
	paint(ad.OBSIDIAN, Color{28, 20, 40, 255}, "obsidian")
	paint(ad.PORTAL, Color{110, 45, 170, 255}, "portal")
	paint(ad.NETHERRACK, Color{110, 34, 34, 255}, "netherrack")
	paint(ad.LAVA, Color{224, 96, 24, 255}, "lava")
	paint(ad.FARMLAND, Color{104, 70, 40, 255}, "farmland")
	paint(ad.WHEAT1, Color{0, 0, 0, 0}, "wheat1")
	paint(ad.WHEAT2, Color{0, 0, 0, 0}, "wheat2")
	paint(ad.WHEAT3, Color{0, 0, 0, 0}, "wheat3")
	paint(ad.TORCH, Color{0, 0, 0, 0}, "torch")
	paint(ad.BED, Color{176, 44, 52, 255}, "bed")
	paint(ad.CHEST, Color{150, 106, 54, 255}, "chest")
	paint(ad.RED_SAND, Color{181, 99, 56, 255}, "red_sand")
	paint(ad.DOOR, Color{96, 66, 34, 255}, "door")
	paint(ad.FENCE, Color{110, 78, 42, 255}, "fence")
	paint(ad.COAL_ORE, Color{128, 128, 132, 255}, "coal_ore")
	paint(ad.GOLD_ORE, Color{128, 128, 132, 255}, "gold_ore")
	paint(ad.DIAMOND_ORE, Color{128, 128, 132, 255}, "diamond_ore")
	paint(ad.GOLD, Color{224, 188, 60, 255}, "gold")
	paint(ad.FLOWER_RED, Color{0, 0, 0, 0}, "flower_red")
	paint(ad.FLOWER_YELLOW, Color{0, 0, 0, 0}, "flower_yellow")
	paint(ad.FLOWER_BLUE, Color{0, 0, 0, 0}, "flower_blue")
	paint(ad.FLOWER_PINK, Color{0, 0, 0, 0}, "flower_pink")
	paint(ad.FLOWER_WHITE, Color{0, 0, 0, 0}, "flower_white")
	paint(ad.TALL_GRASS, Color{0, 0, 0, 0}, "tall_grass")
	paint(ad.FERN, Color{0, 0, 0, 0}, "fern")
	paint(ad.DEAD_BUSH, Color{0, 0, 0, 0}, "dead_bush")
	paint(ad.RAW_FOOD, Color{0, 0, 0, 0}, "raw_food")
	paint(ad.COOKED_FOOD, Color{0, 0, 0, 0}, "cooked_food")
	paint(ad.BREAD, Color{0, 0, 0, 0}, "bread")
	paint(ad.WHEAT_ITEM, Color{0, 0, 0, 0}, "wheat_item")
	paint(ad.SEEDS, Color{0, 0, 0, 0}, "seeds")
	paint(ad.PLANKS, Color{158, 118, 68, 255}, "planks")
	paint(ad.STONE_BRICK, Color{118, 118, 124, 255}, "stone_brick")
	paint(ad.BRICKS, Color{158, 78, 62, 255}, "bricks")
	paint(ad.COBBLESTONE, Color{112, 112, 118, 255}, "cobble")

	if !os.exists("assets") {
		os.make_directory("assets")
	}
	ok := stbiw.write_png(
		"assets/atlas.png",
		i32(ad.ATLAS_PX),
		i32(ad.ATLAS_PX),
		4,
		raw_data(pixels),
		i32(ad.ATLAS_PX * 4),
	)
	if ok == 0 {
		fmt.eprintln("failed to write assets/atlas.png")
		os.exit(1)
	}
	fmt.println("wrote assets/atlas.png", ad.ATLAS_PX, "x", ad.ATLAS_PX)
}
