package main

import "core:fmt"
import gl "vendor:OpenGL"

g_show_inventory: bool

// Title screen: cleared background + centred title, tagline, prompt, and help.
render_title :: proc(fbw, fbh: i32) {
	gl.Viewport(0, 0, fbw, fbh)
	gl.ClearColor(0.09, 0.12, 0.20, 1.0)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

	aspect := f32(fbw) / f32(max(fbh, 1))
	cw :: proc(ch_h, aspect: f32) -> f32 {return ch_h / aspect * (f32(GLYPH_W) / f32(GLYPH_H))}

	text_center("ODINCRAFT", 0.45, cw(0.16, aspect), 0.16, Vec4{0.55, 0.85, 0.55, 1})
	text_center("A VOXEL WORLD IN PURE ODIN", 0.18, cw(0.05, aspect), 0.05, Vec4{0.8, 0.8, 0.85, 1})
	text_center("PRESS ENTER TO PLAY", -0.15, cw(0.07, aspect), 0.07, Vec4{1, 1, 0.6, 1})
	text_center(
		"WASD MOVE   MOUSE LOOK   LMB MINE   RMB PLACE",
		-0.55,
		cw(0.04, aspect),
		0.04,
		Vec4{0.7, 0.75, 0.82, 1},
	)
	text_center(
		"E INVENTORY   C CRAFT   V SMELT   G EAT   F FLY",
		-0.64,
		cw(0.04, aspect),
		0.04,
		Vec4{0.7, 0.75, 0.82, 1},
	)
}

// Full-screen inventory panel: title, every owned block with a colour swatch
// and count, and a controls footer. Toggled with E.
ui_draw_inventory :: proc(p: ^Player, fbw, fbh: int) {
	aspect := f32(fbw) / f32(max(fbh, 1))

	hud_quad(-0.72, -0.86, 0.72, 0.86, Vec4{0.05, 0.05, 0.08, 0.88})

	ch_h: f32 = 0.05
	ch_w := ch_h / aspect * (f32(GLYPH_W) / f32(GLYPH_H))

	x: f32 = -0.64
	y: f32 = 0.76
	text_draw("INVENTORY", x, y, ch_w * 1.5, ch_h * 1.5, Vec4{1, 1, 1, 1})
	y -= ch_h * 2.4

	for b in BlockId {
		if b == .Air do continue
		if p.inventory[b] <= 0 do continue
		col := block_color(b)
		hud_quad(x, y - ch_h, x + ch_w * 1.1, y, Vec4{col.r, col.g, col.b, 1})
		line := fmt.tprintf("%s X%d", block_name(b), p.inventory[b])
		text_draw(line, x + ch_w * 2.0, y, ch_w, ch_h, Vec4{0.95, 0.95, 0.95, 1})
		y -= ch_h * 1.5
		if y < -0.62 do break
	}

	if p.food_count > 0 {
		hud_quad(x, y - ch_h, x + ch_w * 1.1, y, Vec4{0.72, 0.28, 0.22, 1})
		text_draw(
			fmt.tprintf("FOOD X%d  (G TO EAT)", p.food_count),
			x + ch_w * 2.0,
			y,
			ch_w,
			ch_h,
			Vec4{0.95, 0.8, 0.75, 1},
		)
	}

	text_draw(
		"1-9 SELECT   C CRAFT   V SMELT   E CLOSE",
		x,
		-0.74,
		ch_w * 0.85,
		ch_h * 0.85,
		Vec4{0.75, 0.82, 0.92, 1},
	)
}
