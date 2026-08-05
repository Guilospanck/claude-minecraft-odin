package main

import "core:fmt"
import gl "vendor:OpenGL"

g_show_inventory: bool
g_show_quit_confirm: bool

// The inventory (E), crafting (T), and tools (X) screens are one tabbed panel,
// like Minecraft's inventory: a shared frame with the hotbar always visible,
// switchable with LEFT/RIGHT while open (or by pressing E/T/X directly).
InvTab :: enum {
	Items,
	Craft,
	Tools,
}
INV_TAB_COUNT :: len(InvTab)
g_inv_tab: InvTab

inv_tab_cycle :: proc(dir: int) {
	n := INV_TAB_COUNT
	g_inv_tab = InvTab((int(g_inv_tab) + dir + n) % n)
}

@(private = "file")
inv_tab_name :: proc(t: InvTab) -> string {
	switch t {
	case .Items:
		return "ITEMS"
	case .Craft:
		return "CRAFT"
	case .Tools:
		return "TOOLS"
	}
	return "?"
}

// Tab bar across the top of the inventory panel; the active tab is boxed and
// bright, others dim. Purely visual — E/T/X and LEFT/RIGHT drive selection.
@(private = "file")
ui_draw_tabs :: proc(fbw, fbh: int, ch_w, ch_h, y: f32) {
	aspect := f32(fbw) / f32(max(fbh, 1))
	labels := [INV_TAB_COUNT]string{"E ITEMS", "T CRAFT", "X TOOLS"}
	seg: f32 = 0.34
	total := seg * f32(INV_TAB_COUNT)
	x0 := -total * 0.5
	for i in 0 ..< INV_TAB_COUNT {
		active := InvTab(i) == g_inv_tab
		cx := x0 + f32(i) * seg + seg * 0.5
		w2 := seg * 0.42
		col := active ? Vec4{0.95, 0.85, 0.4, 1} : Vec4{0.55, 0.58, 0.64, 1}
		if active {
			hud_quad(cx - w2, y - ch_h * 1.3, cx + w2, y + ch_h * 0.35, Vec4{0.16, 0.16, 0.2, 1})
		}
		lw := text_width(labels[i], ch_w)
		text_draw(labels[i], cx - lw * 0.5, y, ch_w, ch_h, col)
	}
}

// Tools tab content: tools (1-4) then armor (5-8), each with tier + durability
// and its next upgrade; press the number to craft/upgrade it.
@(private = "file")
ui_draw_tools_tab :: proc(p: ^Player, ch_w, ch_h, top: f32) {
	y := top
	for k in ToolKind {
		tier := p.tool_tier[k]
		have := tier > 0 \
			? fmt.tprintf("%s %s  DUR %d", TIER_NAMES[tier], tool_name(k), p.tool_dur[k]) \
			: fmt.tprintf("%s: none", tool_name(k))
		text_draw(fmt.tprintf("%d", int(k) + 1), -0.5, y, ch_w, ch_h, Vec4{1, 0.9, 0.5, 1})
		text_draw(have, -0.38, y, ch_w * 0.9, ch_h * 0.9, Vec4{0.9, 0.94, 0.98, 1})

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
		text_draw(msg, 0.22, y, ch_w * 0.9, ch_h * 0.9, col)
		y -= ch_h * 1.9
	}

	y -= ch_h * 0.6
	text_draw(
		fmt.tprintf("ARMOR: %d PTS - %d PCT REDUCTION", armor_points(p), int(armor_reduction(p) * 100)),
		-0.5,
		y,
		ch_w,
		ch_h,
		Vec4{1, 0.88, 0.5, 1},
	)
	y -= ch_h * 1.9
	for s in ArmorSlot {
		tier := p.armor_tier[s]
		have := tier > 0 \
			? fmt.tprintf("%s %s  DUR %d", TIER_NAMES[tier], armor_name(s), p.armor_dur[s]) \
			: fmt.tprintf("%s: none", armor_name(s))
		text_draw(fmt.tprintf("%d", TOOL_KIND_COUNT + int(s) + 1), -0.5, y, ch_w, ch_h, Vec4{1, 0.9, 0.5, 1})
		text_draw(have, -0.38, y, ch_w * 0.9, ch_h * 0.9, Vec4{0.9, 0.94, 0.98, 1})

		next, block, count, ok := armor_next(p, s)
		msg: string
		col := Vec4{0.6, 0.7, 0.8, 1}
		if ok {
			afford := p.inventory[block] >= count
			msg = fmt.tprintf("-> %s (%d %s)", TIER_NAMES[next], count, block_name(block))
			col = afford ? Vec4{0.6, 0.95, 0.6, 1} : Vec4{0.8, 0.5, 0.5, 1}
		} else {
			msg = "(max)"
		}
		text_draw(msg, 0.22, y, ch_w * 0.9, ch_h * 0.9, col)
		y -= ch_h * 1.9
	}
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
		"WASD MOVE   HOLD LMB MINE   PLACE: RMB / CTRL-CLICK / Q",
		-0.55,
		cw(0.038, aspect),
		0.038,
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

// Craft tab content: each recipe as real-textured input icons -> output icon;
// press the number key to make it. Dimmed when you can't afford it yet.
@(private = "file")
ui_draw_craft_tab :: proc(p: ^Player, w: ^World, aspect, ch_w, ch_h, top: f32) {
	sw := ch_h / aspect * 1.3
	y := top
	for i in 0 ..< len(RECIPES) {
		r := RECIPES[i]
		afford: f32 = recipe_can_make(p, w, r) ? 1.0 : 0.35
		x: f32 = -0.86
		text_draw(fmt.tprintf("%d", i + 1), x, y, ch_w, ch_h, Vec4{1, 0.9, 0.5, afford})
		x += ch_w * 2.2
		for j in 0 ..< r.n_in {
			ing := r.inputs[j]
			hud_quad(x - 0.004, y - ch_h - 0.004, x + sw + 0.004, y + 0.004, Vec4{0.12, 0.12, 0.15, afford})
			ui_block_icon(x, y - ch_h, x + sw, y, ing.block)
			text_draw(fmt.tprintf("X%d", ing.count), x + sw + 0.008, y, ch_w * 0.85, ch_h * 0.85, Vec4{0.9, 0.9, 0.9, afford})
			x += sw + ch_w * 2.8
		}
		text_draw(">", x, y, ch_w, ch_h, Vec4{1, 1, 1, afford})
		x += ch_w * 2.2
		hud_quad(x - 0.004, y - ch_h - 0.004, x + sw + 0.004, y + 0.004, Vec4{0.12, 0.12, 0.15, afford})
		ui_block_icon(x, y - ch_h, x + sw, y, r.out)
		x += sw + 0.01
		note := r.needs_furnace ? " (FURNACE)" : ""
		text_draw(
			fmt.tprintf("%dX %s%s", r.out_count, block_name(r.out), note),
			x,
			y,
			ch_w * 0.8,
			ch_h * 0.8,
			Vec4{0.9, 0.95, 1, afford},
		)
		y -= ch_h * 2.1
	}
}

// One Minecraft-style slot: bordered square, a real block texture (or a flat
// colour swatch for the handful of non-block items like raw food), and a
// count badge in the bottom-right corner. Shared by the hotbar, the
// inventory grid, and the chest panel's slot-styled rows.
@(private = "file")
ui_slot :: proc(
	x0, y0, w, sz: f32,
	use_tex: bool,
	blk: BlockId,
	flat: Vec3,
	count: int,
	ch_w, ch_h: f32,
	selected: bool,
	num_label: string,
) {
	border := selected ? Vec4{1, 1, 1, 0.95} : Vec4{0.10, 0.10, 0.13, 0.85}
	hud_quad(x0 - 0.005, y0 - 0.005, x0 + w + 0.005, y0 + sz + 0.005, border)
	hud_quad(x0, y0, x0 + w, y0 + sz, Vec4{0.17, 0.17, 0.21, 1})
	if use_tex {
		ui_block_icon(x0 + w * 0.10, y0 + sz * 0.10, x0 + w * 0.90, y0 + sz * 0.90, blk)
	} else if count > 0 {
		hud_quad(x0 + w * 0.20, y0 + sz * 0.20, x0 + w * 0.80, y0 + sz * 0.80, Vec4{flat.r, flat.g, flat.b, 1})
	}
	if num_label != "" {
		text_draw(num_label, x0 + 0.004, y0 + sz - 0.004, ch_w * 0.75, ch_h * 0.75, Vec4{0.95, 0.95, 0.6, 0.9})
	}
	if count > 0 {
		s := fmt.tprintf("%d", count)
		cw2 := ch_w * 0.8
		text_draw(s, x0 + w - text_width(s, cw2) - 0.005, y0 + 0.005, cw2, ch_h * 0.8, Vec4{1, 1, 1, 1})
	}
}

// Minecraft-style hotbar: 9 slots (keys 1-9) with real block textures, counts,
// and a highlight on the selected slot.
ui_draw_hotbar :: proc(p: ^Player, fbw, fbh: int) {
	aspect := f32(fbw) / f32(max(fbh, 1))
	sz: f32 = 0.11
	w := sz / aspect
	gap: f32 = 0.012
	total := f32(9) * (w + gap) - gap
	x0 := -total * 0.5
	y0: f32 = -0.97

	ch_h: f32 = 0.032
	cw := ch_h / aspect * (f32(GLYPH_W) / f32(GLYPH_H))

	for i in 0 ..< 9 {
		bx := x0 + f32(i) * (w + gap)
		b := HOTBAR[i]
		ui_slot(bx, y0, w, sz, true, b, Vec3{}, p.inventory[b], cw, ch_h, b == p.selected, fmt.tprintf("%d", i + 1))
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

// One entry in the inventory grid: either a real block (textured icon) or one
// of the handful of non-block counters (food/seeds/wheat) shown as a flat
// colour swatch since they have no world block/texture of their own.
@(private = "file")
InvEntry :: struct {
	use_tex: bool,
	blk:     BlockId,
	flat:    Vec3,
	count:   int,
}

// Full-screen inventory: a tabbed Minecraft-style panel (ITEMS / CRAFT /
// TOOLS — E/T/X or LEFT/RIGHT to switch) with the hotbar mirrored at the
// bottom on every tab. Items are real block textures in a slot grid; Craft
// and Tools let you make/upgrade things right here, not just look at them.
ui_draw_inventory :: proc(p: ^Player, w: ^World, fbw, fbh: int) {
	aspect := f32(fbw) / f32(max(fbh, 1))

	// Reaches all the way to ~-0.99/0.99 so it fully covers the world's own
	// hotbar/health/hunger/oxygen HUD sitting underneath (health hearts start
	// as far out as x=-0.97) instead of leaving slivers of it peeking out.
	hud_quad(-0.99, -0.99, 0.99, 0.90, Vec4{0.05, 0.05, 0.08, 0.97})

	ch_h: f32 = 0.045
	ch_w := ch_h / aspect * (f32(GLYPH_W) / f32(GLYPH_H))
	ui_draw_tabs(fbw, fbh, ch_w * 1.05, ch_h * 1.05, 0.82)

	cols :: 9
	sz: f32 = 0.095
	sw := sz / aspect
	gap: f32 = 0.010
	grid_w := f32(cols) * (sw + gap) - gap
	gx0 := -grid_w * 0.5
	content_top: f32 = 0.66

	switch g_inv_tab {
	case .Items:
		// Gather owned entries: every held block, then the non-block counters.
		entries := make([dynamic]InvEntry, 0, 40, context.temp_allocator)
		for b in BlockId {
			if b == .Air do continue
			if p.inventory[b] <= 0 do continue
			append(&entries, InvEntry{use_tex = true, blk = b, count = p.inventory[b]})
		}
		if p.raw_food > 0 do append(&entries, InvEntry{flat = {0.72, 0.28, 0.22}, count = p.raw_food})
		if p.cooked_food > 0 do append(&entries, InvEntry{flat = {0.55, 0.35, 0.2}, count = p.cooked_food})
		if p.bread > 0 do append(&entries, InvEntry{flat = {0.78, 0.58, 0.30}, count = p.bread})
		if p.wheat > 0 do append(&entries, InvEntry{flat = {0.82, 0.70, 0.28}, count = p.wheat})
		if p.seeds > 0 do append(&entries, InvEntry{flat = {0.55, 0.62, 0.30}, count = p.seeds})

		for e, i in entries {
			row := i / cols
			col := i % cols
			x0 := gx0 + f32(col) * (sw + gap)
			y0 := content_top - f32(row) * (sz + gap) - sz
			ui_slot(x0, y0, sw, sz, e.use_tex, e.blk, e.flat, e.count, ch_w, ch_h, false, "")
		}
		if len(entries) == 0 {
			text_center("(EMPTY)", content_top - sz * 0.5, ch_w, ch_h, Vec4{0.6, 0.6, 0.65, 1})
		}
		text_center(
			"RAW=RED  COOKED=BROWN  BREAD=TAN  WHEAT=GOLD  SEEDS=GREEN",
			0.10,
			ch_w * 0.62,
			ch_h * 0.62,
			Vec4{0.65, 0.7, 0.76, 1},
		)
	case .Craft:
		ui_draw_craft_tab(p, w, aspect, ch_w * 0.95, ch_h * 0.95, content_top)
	case .Tools:
		ui_draw_tools_tab(p, ch_w, ch_h, content_top)
	}

	// Hotbar mirrored at a fixed position on every tab, same as Minecraft.
	hy0: f32 = -0.60
	text_draw("HOTBAR", gx0, hy0 + sz + 0.03, ch_w * 0.85, ch_h * 0.85, Vec4{0.7, 0.75, 0.82, 1})
	for i in 0 ..< 9 {
		x0 := gx0 + f32(i) * (sw + gap)
		b := HOTBAR[i]
		ui_slot(x0, hy0, sw, sz, true, b, Vec3{}, p.inventory[b], ch_w, ch_h, b == p.selected, fmt.tprintf("%d", i + 1))
	}

	action_hint: string
	switch g_inv_tab {
	case .Items:
		action_hint = "1-9 SELECT A HOTBAR SLOT"
	case .Craft:
		action_hint = "1-8 TO CRAFT"
	case .Tools:
		action_hint = "1-4 TOOLS   5-8 ARMOR"
	}
	text_center(action_hint, hy0 - sz - 0.06, ch_w * 0.68, ch_h * 0.68, Vec4{0.75, 0.82, 0.92, 1})
	text_center(
		"LEFT/RIGHT SWITCH TABS   R USE/FARM/SLEEP/CHEST   G EAT   E/T/X CLOSE",
		hy0 - sz - 0.14,
		ch_w * 0.6,
		ch_h * 0.6,
		Vec4{0.65, 0.7, 0.76, 1},
	)
}
