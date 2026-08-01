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
			case "water":
				c = shade(base, jitter(gx, gy, 8))
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
