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
		"E INVENTORY   T CRAFT   O SETTINGS   G EAT   F FLY",
		-0.64,
		cw(0.04, aspect),
		0.04,
		Vec4{0.7, 0.75, 0.82, 1},
	)
}

// Settings menu (O): up/down select, left/right adjust.
ui_draw_settings :: proc(fbw, fbh: int) {
	aspect := f32(fbw) / f32(max(fbh, 1))
	hud_quad(-0.62, -0.62, 0.62, 0.72, Vec4{0.05, 0.05, 0.08, 0.92})
	ch_h: f32 = 0.055
	ch_w := ch_h / aspect * (f32(GLYPH_W) / f32(GLYPH_H))
	text_center("SETTINGS", 0.58, ch_w * 1.3, ch_h * 1.3, Vec4{1, 0.88, 0.5, 1})

	rows := [SETTINGS_COUNT]string {
		fmt.tprintf("MOUSE SENS: %d", int(g_settings.mouse_sens * 10000)),
		fmt.tprintf("FOV: %d", int(g_settings.fov_deg)),
		fmt.tprintf("RENDER DIST: %d", g_settings.render_radius),
		fmt.tprintf("VOLUME: %d", int(g_settings.volume * 100)),
		fmt.tprintf("DAY LENGTH: %dS", int(g_settings.day_length)),
	}
	y: f32 = 0.36
	for i in 0 ..< SETTINGS_COUNT {
		selected := i == g_settings_sel
		col := selected ? Vec4{1, 1, 0.5, 1} : Vec4{0.85, 0.9, 0.95, 1}
		text_draw(
			fmt.tprintf("%s%s", selected ? "> " : "  ", rows[i]),
			-0.5,
			y,
			ch_w,
			ch_h,
			col,
		)
		y -= ch_h * 1.5
	}
	text_center(
		"UP/DOWN SELECT   LEFT/RIGHT ADJUST   O CLOSE",
		-0.5,
		ch_w * 0.6,
		ch_h * 0.6,
		Vec4{0.7, 0.8, 0.9, 1},
	)
}

// Crafting menu (T): recipes with input->output swatches; press 1-4 to craft.
ui_draw_crafting :: proc(p: ^Player, w: ^World, fbw, fbh: int) {
	aspect := f32(fbw) / f32(max(fbh, 1))
	hud_quad(-0.82, -0.68, 0.82, 0.78, Vec4{0.05, 0.05, 0.08, 0.92})
	ch_h: f32 = 0.05
	ch_w := ch_h / aspect * (f32(GLYPH_W) / f32(GLYPH_H))
	sw := ch_h / aspect * 1.1
	text_center("CRAFTING", 0.66, ch_w * 1.3, ch_h * 1.3, Vec4{1, 0.88, 0.5, 1})

	y: f32 = 0.44
	for i in 0 ..< len(RECIPES) {
		r := RECIPES[i]
		a: f32 = recipe_can_make(p, w, r) ? 1.0 : 0.4
		x: f32 = -0.72
		text_draw(fmt.tprintf("%d", i + 1), x, y, ch_w, ch_h, Vec4{1, 0.9, 0.5, a})
		x += ch_w * 2.5
		for j in 0 ..< r.n_in {
			ing := r.inputs[j]
			col := block_color(ing.block)
			hud_quad(x, y - ch_h, x + sw, y, Vec4{col.r, col.g, col.b, a})
			text_draw(fmt.tprintf("X%d", ing.count), x + sw + 0.006, y, ch_w * 0.9, ch_h * 0.9, Vec4{0.9, 0.9, 0.9, a})
			x += sw + ch_w * 3.5
		}
		text_draw("->", x, y, ch_w, ch_h, Vec4{1, 1, 1, a})
		x += ch_w * 3.5
		oc := block_color(r.out)
		hud_quad(x, y - ch_h, x + sw, y, Vec4{oc.r, oc.g, oc.b, a})
		x += sw + 0.01
		note := r.needs_furnace ? " (FURNACE)" : ""
		text_draw(
			fmt.tprintf("%s%s", block_name(r.out), note),
			x,
			y,
			ch_w * 0.85,
			ch_h * 0.85,
			Vec4{0.9, 0.95, 1, a},
		)
		y -= ch_h * 1.9
	}
	text_center("PRESS 1-4 TO CRAFT   T CLOSE", -0.58, ch_w * 0.6, ch_h * 0.6, Vec4{0.7, 0.8, 0.9, 1})
}

// Minecraft-style hotbar: 9 slots (keys 1-9) with block swatch, count, and a
// highlight on the selected slot.
ui_draw_hotbar :: proc(p: ^Player, fbw, fbh: int) {
	aspect := f32(fbw) / f32(max(fbh, 1))
	sz: f32 = 0.11
	w := sz / aspect
	gap: f32 = 0.012
	total := f32(9) * (w + gap) - gap
	x0 := -total * 0.5
	y0: f32 = -0.97

	sel := -1
	for i in 0 ..< 9 do if HOTBAR[i] == p.selected do sel = i

	ch_h: f32 = 0.032
	cw := ch_h / aspect * (f32(GLYPH_W) / f32(GLYPH_H))

	for i in 0 ..< 9 {
		bx := x0 + f32(i) * (w + gap)
		b := HOTBAR[i]
		cnt := p.inventory[b]

		border := i == sel ? Vec4{1, 1, 1, 0.95} : Vec4{0.12, 0.12, 0.15, 0.75}
		hud_quad(bx - 0.006, y0 - 0.006, bx + w + 0.006, y0 + sz + 0.006, border)

		col := block_color(b)
		a: f32 = cnt > 0 ? 1.0 : 0.35
		hud_quad(bx, y0, bx + w, y0 + sz, Vec4{col.r, col.g, col.b, a})

		num := fmt.tprintf("%d", i + 1)
		text_draw(num, bx + 0.004, y0 + sz - 0.004, cw * 0.8, ch_h * 0.8, Vec4{0.95, 0.95, 0.6, 0.9})
		if cnt > 0 {
			s := fmt.tprintf("%d", cnt)
			text_draw(
				s,
				bx + w - text_width(s, cw) - 0.004,
				y0 + ch_h + 0.004,
				cw,
				ch_h,
				Vec4{1, 1, 1, 1},
			)
		}
	}
}

// Full-screen inventory panel: title, every owned block with a colour swatch
// and count, and a controls footer. Toggled with E.
ui_draw_inventory :: proc(p: ^Player, fbw, fbh: int) {
	aspect := f32(fbw) / f32(max(fbh, 1))

	hud_quad(-0.86, -0.88, 0.86, 0.88, Vec4{0.05, 0.05, 0.08, 0.9})

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

	// --- right column: how to get / make things ---
	hx: f32 = 0.06
	hy: f32 = 0.74
	text_draw("HOW TO", hx, hy, ch_w * 1.3, ch_h * 1.3, Vec4{1, 0.88, 0.5, 1})
	hy -= ch_h * 2.2
	help := [?]string {
		"MINE: HOLD LMB ON A BLOCK",
		"PLACE: RMB (USES A SLOT)",
		"1-9: PICK A HOTBAR SLOT",
		"",
		"CRAFT (C):",
		"  8 STONE -> FURNACE",
		"  4 SAND + 1 ORE -> GLOWSTONE",
		"",
		"SMELT (V, NEAR A FURNACE):",
		"  ORE + WOOD -> IRON",
		"  SAND + WOOD -> GLASS",
		"",
		"KILL ANIMALS -> FOOD (EAT: G)",
	}
	for line in help {
		if line != "" {
			text_draw(line, hx, hy, ch_w * 0.82, ch_h * 0.82, Vec4{0.85, 0.9, 0.96, 1})
		}
		hy -= ch_h * 1.15
	}

	text_draw(
		"1-9 SELECT   C CRAFT   V SMELT   E CLOSE",
		x,
		-0.78,
		ch_w * 0.85,
		ch_h * 0.85,
		Vec4{0.75, 0.82, 0.92, 1},
	)
}
