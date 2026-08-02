package main

import "core:fmt"
import gl "vendor:OpenGL"

g_show_inventory: bool
g_show_quit_confirm: bool
g_show_tools: bool

// Tools menu (X): shows each tool's tier + durability and its next upgrade;
// press 1-4 to craft/upgrade.
ui_draw_tools :: proc(p: ^Player, fbw, fbh: int) {
	aspect := f32(fbw) / f32(max(fbh, 1))
	hud_quad(-0.72, -0.5, 0.72, 0.62, Vec4{0.05, 0.05, 0.08, 0.94})
	ch_h: f32 = 0.055
	ch_w := ch_h / aspect * (f32(GLYPH_W) / f32(GLYPH_H))
	text_center("TOOLS", 0.52, ch_w * 1.3, ch_h * 1.3, Vec4{1, 0.88, 0.5, 1})

	y: f32 = 0.32
	for k in ToolKind {
		tier := p.tool_tier[k]
		have := tier > 0 \
			? fmt.tprintf("%s %s  DUR %d", TIER_NAMES[tier], tool_name(k), p.tool_dur[k]) \
			: fmt.tprintf("%s: none", tool_name(k))
		text_draw(fmt.tprintf("%d", int(k) + 1), -0.62, y, ch_w, ch_h, Vec4{1, 0.9, 0.5, 1})
		text_draw(have, -0.5, y, ch_w * 0.9, ch_h * 0.9, Vec4{0.9, 0.94, 0.98, 1})

		next, block, count, ok := tool_next(p, k)
		msg: string
		col := Vec4{0.6, 0.7, 0.8, 1}
		if ok {
			afford := p.inventory[block] >= count
			msg = fmt.tprintf("-> %s (%d %s)", TIER_NAMES[next], count, block_name(block))
			col = afford ? Vec4{0.6, 0.95, 0.6, 1} : Vec4{0.8, 0.5, 0.5, 1}
		} else {
			msg = "(max)"
		}
		text_draw(msg, 0.16, y, ch_w * 0.9, ch_h * 0.9, col)
		y -= ch_h * 1.7
	}
	text_center(
		"PRESS 1-4 TO CRAFT/UPGRADE   X CLOSE",
		-0.4,
		ch_w * 0.6,
		ch_h * 0.6,
		Vec4{0.7, 0.8, 0.9, 1},
	)
}

// ESC confirmation overlay: Y quits, ESC resumes.
ui_draw_quit_confirm :: proc(fbw, fbh: int) {
	aspect := f32(fbw) / f32(max(fbh, 1))
	hud_quad(-1, -1, 1, 1, Vec4{0, 0, 0, 0.55}) // dim the world behind
	hud_quad(-0.52, -0.24, 0.52, 0.30, Vec4{0.08, 0.08, 0.12, 0.96})
	ch_h: f32 = 0.08
	ch_w := ch_h / aspect * (f32(GLYPH_W) / f32(GLYPH_H))
	text_center("QUIT GAME", 0.10, ch_w, ch_h, Vec4{1, 0.85, 0.5, 1})
	text_center(
		"Y = QUIT     ESC = KEEP PLAYING",
		-0.10,
		ch_w * 0.5,
		ch_h * 0.5,
		Vec4{0.9, 0.92, 0.96, 1},
	)
}

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
		"WASD MOVE   HOLD LMB MINE   RMB OR Q PLACE",
		-0.55,
		cw(0.04, aspect),
		0.04,
		Vec4{0.7, 0.75, 0.82, 1},
	)
	text_center(
		"E INV  T CRAFT  X TOOLS  R USE  G EAT  F FLY  P PORTAL",
		-0.62,
		cw(0.038, aspect),
		0.038,
		Vec4{0.7, 0.75, 0.82, 1},
	)
	text_center(
		"HOLD LMB TO MINE (RIGHT TOOL IS FASTER)",
		-0.70,
		cw(0.038, aspect),
		0.038,
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
	text_center("PRESS 1-7 TO CRAFT   T CLOSE", -0.58, ch_w * 0.6, ch_h * 0.6, Vec4{0.7, 0.8, 0.9, 1})
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

// Chest panel (opened with R on a chest): stored contents on the left, your
// blocks on the right. A hotbar number deposits that item; R takes everything.
ui_draw_chest :: proc(p: ^Player, w: ^World, fbw, fbh: int) {
	aspect := f32(fbw) / f32(max(fbh, 1))
	hud_quad(-0.86, -0.72, 0.86, 0.82, Vec4{0.05, 0.05, 0.08, 0.93})
	ch_h: f32 = 0.045
	ch_w := ch_h / aspect * (f32(GLYPH_W) / f32(GLYPH_H))
	text_center("CHEST", 0.74, ch_w * 1.3, ch_h * 1.3, Vec4{1, 0.88, 0.5, 1})

	ch, ok := w.chests[g_chest_pos]

	// left column: stored contents
	lx: f32 = -0.78
	ly: f32 = 0.56
	text_draw("STORED", lx, ly, ch_w * 1.1, ch_h * 1.1, Vec4{0.9, 0.82, 0.6, 1})
	ly -= ch_h * 2.0
	stored := false
	if ok {
		for b in BlockId {
			if b == .Air || ch.items[b] <= 0 do continue
			col := block_color(b)
			hud_quad(lx, ly - ch_h, lx + ch_w * 1.1, ly, Vec4{col.r, col.g, col.b, 1})
			text_draw(
				fmt.tprintf("%s X%d", block_name(b), ch.items[b]),
				lx + ch_w * 2.0,
				ly,
				ch_w,
				ch_h,
				Vec4{0.95, 0.95, 0.95, 1},
			)
			ly -= ch_h * 1.4
			stored = true
			if ly < -0.55 do break
		}
	}
	if !stored do text_draw("(empty)", lx, ly, ch_w, ch_h, Vec4{0.6, 0.6, 0.65, 1})

	// right column: the player's blocks
	rx: f32 = 0.12
	ry: f32 = 0.56
	text_draw("YOUR BLOCKS", rx, ry, ch_w * 1.1, ch_h * 1.1, Vec4{0.9, 0.82, 0.6, 1})
	ry -= ch_h * 2.0
	for b in BlockId {
		if b == .Air || p.inventory[b] <= 0 do continue
		col := block_color(b)
		hud_quad(rx, ry - ch_h, rx + ch_w * 1.1, ry, Vec4{col.r, col.g, col.b, 1})
		text_draw(
			fmt.tprintf("%s X%d", block_name(b), p.inventory[b]),
			rx + ch_w * 2.0,
			ry,
			ch_w,
			ch_h,
			Vec4{0.95, 0.95, 0.95, 1},
		)
		ry -= ch_h * 1.4
		if ry < -0.55 do break
	}

	text_center(
		"HOTBAR NUMBER = STORE ITEM    R = TAKE ALL    E CLOSE",
		-0.66,
		ch_w * 0.62,
		ch_h * 0.62,
		Vec4{0.72, 0.82, 0.92, 1},
	)
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

	if p.raw_food > 0 {
		hud_quad(x, y - ch_h, x + ch_w * 1.1, y, Vec4{0.72, 0.28, 0.22, 1})
		text_draw(
			fmt.tprintf("RAW FOOD X%d  (COOK: V)", p.raw_food),
			x + ch_w * 2.0,
			y,
			ch_w,
			ch_h,
			Vec4{0.95, 0.8, 0.75, 1},
		)
		y -= ch_h * 1.5
	}
	if p.cooked_food > 0 {
		hud_quad(x, y - ch_h, x + ch_w * 1.1, y, Vec4{0.55, 0.35, 0.2, 1})
		text_draw(
			fmt.tprintf("COOKED FOOD X%d  (EAT: G)", p.cooked_food),
			x + ch_w * 2.0,
			y,
			ch_w,
			ch_h,
			Vec4{0.95, 0.85, 0.7, 1},
		)
		y -= ch_h * 1.5
	}
	if p.bread > 0 {
		hud_quad(x, y - ch_h, x + ch_w * 1.1, y, Vec4{0.78, 0.58, 0.30, 1})
		text_draw(
			fmt.tprintf("BREAD X%d  (EAT: G)", p.bread),
			x + ch_w * 2.0,
			y,
			ch_w,
			ch_h,
			Vec4{0.95, 0.88, 0.72, 1},
		)
		y -= ch_h * 1.5
	}
	if p.wheat > 0 || p.seeds > 0 {
		hud_quad(x, y - ch_h, x + ch_w * 1.1, y, Vec4{0.82, 0.70, 0.28, 1})
		text_draw(
			fmt.tprintf("WHEAT X%d   SEEDS X%d  (BAKE: C)", p.wheat, p.seeds),
			x + ch_w * 2.0,
			y,
			ch_w,
			ch_h,
			Vec4{0.92, 0.90, 0.7, 1},
		)
	}

	// --- right column: how to get / make things ---
	hx: f32 = 0.06
	hy: f32 = 0.74
	text_draw("HOW TO", hx, hy, ch_w * 1.3, ch_h * 1.3, Vec4{1, 0.88, 0.5, 1})
	hy -= ch_h * 2.2
	help := [?]string {
		"MINE: HOLD LMB ON A BLOCK",
		"PLACE: RMB OR Q (USES A SLOT)",
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
		"KILL ANIMALS -> RAW FOOD",
		"COOK RAW FOOD AT A FURNACE (V)",
		"EAT: G (COOKED HEALS MORE)",
		"",
		"FARMING (R = USE):",
		"  R ON GRASS/DIRT -> TILL",
		"  R ON FARMLAND -> PLANT SEEDS",
		"  BREAK RIPE WHEAT -> WHEAT",
		"  3 WHEAT -> BREAD (C)",
		"",
		"TORCH: LIGHT   BED: R TO SLEEP",
		"CHEST: R TO OPEN/STORE",
		"",
		"TOOLS (X): PICK/AXE/SHOVEL/SWORD",
		"  HOLD LMB TO MINE",
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
