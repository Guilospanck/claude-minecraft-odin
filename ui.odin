package main

import "core:fmt"
import gl "vendor:OpenGL"

// ---- Minecraft-style GUI palette + bevel helpers ----
// A light "stone" panel with sunken slots and dark engraved text, matching the
// classic Minecraft inventory chrome (rather than the old flat dark-navy panels).
@(private = "file") MC_PANEL :: Vec4{0.78, 0.78, 0.78, 1.0}
@(private = "file") MC_PANEL_HI :: Vec4{1.0, 1.0, 1.0, 1.0} // raised bevel: top-left highlight
@(private = "file") MC_PANEL_LO :: Vec4{0.33, 0.33, 0.33, 1.0} // raised bevel: bottom-right shadow
@(private = "file") MC_SLOT :: Vec4{0.545, 0.545, 0.545, 1.0}
@(private = "file") MC_SLOT_HI :: Vec4{1.0, 1.0, 1.0, 1.0} // sunken slot: bottom-right highlight
@(private = "file") MC_SLOT_LO :: Vec4{0.22, 0.22, 0.22, 1.0} // sunken slot: top-left shadow
@(private = "file") MC_TEXT :: Vec4{0.24, 0.24, 0.24, 1.0} // dark engraved label text
@(private = "file") MC_TEXT_DIM :: Vec4{0.40, 0.40, 0.42, 1.0}

// A bevelled rectangle: `br` shows along the bottom+right edge, `tl` along the
// top+left, with `face` filling the middle. Raised (light tl) reads as a panel
// popping out; sunken (dark tl) reads as an inset slot. The x offset is divided
// by aspect so the bevel is an even thickness in pixels on both axes.
@(private = "file")
ui_bevel :: proc(x0, y0, x1, y1, t, aspect: f32, face, tl, br: Vec4) {
	tx := t / aspect
	hud_quad(x0, y0, x1, y1, br)
	hud_quad(x0, y0 + t, x1 - tx, y1, tl)
	hud_quad(x0 + tx, y0 + t, x1 - tx, y1 - t, face)
}

// A raised stone panel (the window chrome behind an inventory/chest screen).
@(private = "file")
ui_panel :: proc(x0, y0, x1, y1, aspect: f32) {
	ui_bevel(x0, y0, x1, y1, 0.014, aspect, MC_PANEL, MC_PANEL_HI, MC_PANEL_LO)
}

// One requirement line for a tooltip: an ingredient, how many are needed, and
// how many you currently have (drawn green if you have enough, red if not).
ReqLine :: struct {
	block:      BlockId,
	need, have: int,
}

// A dark Minecraft-style tooltip near the cursor: a title (what it makes) and a
// list of requirements with have/need counts. Kept on-screen by flipping to the
// cursor's left when it would run off the right edge.
@(private = "file")
ui_reqs_tooltip :: proc(mnx, mny, aspect: f32, title: string, reqs: []ReqLine) {
	ch_h := f32(0.036)
	ch_w := ch_h / aspect * (f32(GLYPH_W) / f32(GLYPH_H))
	rows := len(reqs) + 1
	boxw := f32(0.46)
	boxh := f32(rows) * ch_h * 1.5 + 0.02
	x0 := mnx + 0.02
	x1 := x0 + boxw
	if x1 > 0.98 {x0 = mnx - 0.02 - boxw;x1 = mnx - 0.02}
	y1 := clamp(mny + 0.05, -0.9 + boxh, 0.95)
	y0 := y1 - boxh
	hud_quad(x0 - 0.006, y0 - 0.006, x1 + 0.006, y1 + 0.006, Vec4{0.55, 0.45, 0.75, 0.95}) // violet border
	hud_quad(x0, y0, x1, y1, Vec4{0.06, 0.05, 0.10, 0.97}) // dark fill
	ty := y1 - ch_h * 1.2
	text_draw(title, x0 + 0.012, ty, ch_w, ch_h, Vec4{1, 0.92, 0.55, 1})
	ty -= ch_h * 1.5
	for r in reqs {
		ok := r.have >= r.need
		text_draw(
			fmt.tprintf("%d %s  (have %d)", r.need, block_name(r.block), r.have),
			x0 + 0.012,
			ty,
			ch_w * 0.9,
			ch_h * 0.9,
			ok ? Vec4{0.45, 0.95, 0.5, 1} : Vec4{0.98, 0.5, 0.5, 1},
		)
		ty -= ch_h * 1.5
	}
}

// Dim the world behind an open menu.
@(private = "file")
ui_dim :: proc() {hud_quad(-1, -1, 1, 1, Vec4{0, 0, 0, 0.6})}

g_show_inventory: bool
g_show_quit_confirm: bool

// The inventory (E), crafting (T), and tools (X) screens are one tabbed panel,
// like Minecraft's inventory: a shared frame with the hotbar always visible,
// selected by pressing E/T/X directly (arrow keys are used for grid
// navigation within the Items tab instead of tab-switching).
InvTab :: enum {
	Items,
	Craft,
	Tools,
	Skills,
}
INV_TAB_COUNT :: len(InvTab)
g_inv_tab: InvTab

// Craft tab shows a scrollable window into RECIPES (the list outgrew the screen
// once building blocks were added). g_craft_scroll is the index of the top
// visible recipe; the mouse wheel moves it (see main loop).
CRAFT_VISIBLE :: 7
g_craft_scroll: int

craft_scroll_clamp :: proc() {
	maxs := max(0, len(RECIPES) - CRAFT_VISIBLE)
	if g_craft_scroll < 0 do g_craft_scroll = 0
	if g_craft_scroll > maxs do g_craft_scroll = maxs
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
	case .Skills:
		return "SKILLS"
	}
	return "?"
}

// Tab bar across the top of the inventory panel; the active tab is boxed and
// bright, others dim. Purely visual — E/T/X and LEFT/RIGHT drive selection.
@(private = "file")
ui_draw_tabs :: proc(fbw, fbh: int, ch_w, ch_h, y: f32) {
	aspect := f32(fbw) / f32(max(fbh, 1))
	labels := [INV_TAB_COUNT]string{"ITEMS", "CRAFT", "GEAR", "SKILLS"}
	seg: f32 = 0.29
	total := seg * f32(INV_TAB_COUNT)
	x0 := -total * 0.5
	for i in 0 ..< INV_TAB_COUNT {
		active := InvTab(i) == g_inv_tab
		cx := x0 + f32(i) * seg + seg * 0.5
		w2 := seg * 0.44
		bx0, bx1 := cx - w2, cx + w2
		by0, by1 := y - ch_h * 1.05, y + ch_h * 0.55
		if active {
			ui_bevel(bx0, by0, bx1, by1, 0.008, aspect, Vec4{0.86, 0.86, 0.86, 1}, MC_PANEL_HI, MC_PANEL_LO)
		} else {
			ui_bevel(bx0, by0, bx1, by1, 0.006, aspect, Vec4{0.60, 0.60, 0.60, 1}, MC_SLOT_LO, MC_SLOT_HI)
		}
		lw := text_width(labels[i], ch_w)
		text_draw(labels[i], cx - lw * 0.5, y, ch_w, ch_h, active ? MC_TEXT : MC_TEXT_DIM)
	}
}

// Tools tab content: tools (1-4) then armor (5-8), each with tier + durability
// and its next upgrade; press the number to craft/upgrade it.
@(private = "file")
ui_draw_tools_tab :: proc(p: ^Player, aspect, ch_w, ch_h, top: f32) {
	NUMCOL :: Vec4{0.45, 0.32, 0.08, 1} // engraved gold number
	GOOD :: Vec4{0.13, 0.45, 0.13, 1} // affordable upgrade (green)
	BAD :: Vec4{0.62, 0.22, 0.22, 1} // can't afford (red)
	step := ch_h * 1.55
	y := top
	for k in ToolKind {
		tier := p.tool_tier[k]
		have := tier > 0 \
			? fmt.tprintf("%s %s  DUR %d", TIER_NAMES[tier], tool_name(k), p.tool_dur[k]) \
			: fmt.tprintf("%s: none", tool_name(k))
		text_draw(fmt.tprintf("%d", int(k) + 1), -0.56, y, ch_w, ch_h, NUMCOL)
		text_draw(have, -0.48, y, ch_w * 0.85, ch_h * 0.85, MC_TEXT)

		next, block, count, ok := tool_next(p, k)
		msg: string
		col := MC_TEXT_DIM
		if ok {
			msg = fmt.tprintf("-> %s (%d %s)", TIER_NAMES[next], count, block_name(block))
			col = inv_has(p, block, count) ? GOOD : BAD
		} else {
			msg = "(max)"
		}
		text_draw(msg, 0.16, y, ch_w * 0.85, ch_h * 0.85, col)
		y -= step
	}

	y -= ch_h * 0.5
	text_draw(
		fmt.tprintf("ARMOR: %d PTS  -  %d%% DAMAGE REDUCTION", armor_points(p), int(armor_reduction(p) * 100)),
		-0.56,
		y,
		ch_w * 0.9,
		ch_h * 0.9,
		NUMCOL,
	)
	y -= step
	for s in ArmorSlot {
		tier := p.armor_tier[s]
		have := tier > 0 \
			? fmt.tprintf("%s %s  DUR %d", TIER_NAMES[tier], armor_name(s), p.armor_dur[s]) \
			: fmt.tprintf("%s: none", armor_name(s))
		text_draw(fmt.tprintf("%d", TOOL_KIND_COUNT + int(s) + 1), -0.56, y, ch_w, ch_h, NUMCOL)
		text_draw(have, -0.48, y, ch_w * 0.85, ch_h * 0.85, MC_TEXT)

		next, block, count, ok := armor_next(p, s)
		msg: string
		col := MC_TEXT_DIM
		if ok {
			msg = fmt.tprintf("-> %s (%d %s)", TIER_NAMES[next], count, block_name(block))
			col = inv_has(p, block, count) ? GOOD : BAD
		} else {
			msg = "(max)"
		}
		text_draw(msg, 0.16, y, ch_w * 0.85, ch_h * 0.85, col)
		y -= step
	}

	// Hover a row → a tooltip showing its next upgrade's cost vs what you have.
	mnx, mny := cursor_ndc()
	hr := inv_hit_tools_row(mnx, mny)
	if hr >= 1 && hr <= TOOL_KIND_COUNT {
		k := ToolKind(hr - 1)
		if nt, block, count, ok := tool_next(p, k); ok {
			reqs := [1]ReqLine{{block, count, inv_count(p, block)}}
			ui_reqs_tooltip(mnx, mny, aspect, fmt.tprintf("%s %s", TIER_NAMES[nt], tool_name(k)), reqs[:])
		}
	} else if hr > TOOL_KIND_COUNT && hr <= TOOL_KIND_COUNT + ARMOR_SLOT_COUNT {
		as := ArmorSlot(hr - 1 - TOOL_KIND_COUNT)
		if nt, block, count, ok := armor_next(p, as); ok {
			reqs := [1]ReqLine{{block, count, inv_count(p, block)}}
			ui_reqs_tooltip(mnx, mny, aspect, fmt.tprintf("%s %s", TIER_NAMES[nt], armor_name(as)), reqs[:])
		}
	}
}

// Skills tab: each skill's level, an XP bar toward the next level, and what its
// current level does for you — the Stardew-style progression at a glance.
@(private = "file")
ui_draw_skills_tab :: proc(p: ^Player, ch_w, ch_h, top: f32) {
	step := ch_h * 2.3
	y := top
	for s in Skill {
		lvl := p.skill_level[s]
		text_draw(fmt.tprintf("%s   LV %d", skill_name(s), lvl), -0.52, y, ch_w, ch_h, MC_TEXT)
		bx0, bx1 := f32(0.02), f32(0.5)
		by0, by1 := y - ch_h * 0.9, y - ch_h * 0.1
		hud_quad(bx0 - 0.005, by0 - 0.005, bx1 + 0.005, by1 + 0.005, Vec4{0.2, 0.2, 0.22, 1})
		prog := skill_progress(p, s)
		if prog > 0 do hud_quad(bx0, by0, bx0 + (bx1 - bx0) * prog, by1, Vec4{0.40, 0.86, 0.28, 1})
		text_draw(skill_perk(s, lvl), -0.52, y - ch_h * 1.5, ch_w * 0.78, ch_h * 0.78, MC_TEXT_DIM)
		y -= step
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
		fmt.tprintf("REAL TIME DAY/NIGHT: %s", g_settings.real_time ? "ON" : "OFF"),
		g_settings.real_time \
			? "DAY LENGTH: (REAL TIME ON)" \
			: fmt.tprintf("DAY LENGTH: %dS", int(g_settings.day_length)),
		fmt.tprintf("PEACEFUL (NO HOSTILES): %s", g_settings.peaceful ? "ON" : "OFF"),
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
	bs := ch_h * 1.35 // mini-slot height
	bw := bs / aspect
	craft_scroll_clamp()
	lo := g_craft_scroll
	hi := min(len(RECIPES), lo + CRAFT_VISIBLE)
	pitch := ch_h * 1.95
	y := top
	mnx, mny := cursor_ndc()
	hovr := inv_hit_craft_row(mnx, mny)
	if lo > 0 do text_center("^  more above", top + ch_h * 1.3, ch_w * 0.7, ch_h * 0.7, MC_TEXT_DIM)
	for i in lo ..< hi {
		r := RECIPES[i]
		can := recipe_can_make(p, w, r)
		txt := can ? MC_TEXT : MC_TEXT_DIM
		if i == hovr do hud_quad(-0.40, y - pitch + ch_h * 0.6, 0.46, y + ch_h * 0.55, Vec4{1, 1, 1, 0.4})
		sy := y - bs + ch_h * 0.35 // mini-slots aligned to the text line
		x: f32 = -0.34
		if i - lo < 9 {
			text_draw(fmt.tprintf("%d", i - lo + 1), x, y, ch_w, ch_h, can ? Vec4{0.45, 0.32, 0.08, 1} : MC_TEXT_DIM)
		}
		x += ch_w * 1.7
		for j in 0 ..< r.n_in {
			ing := r.inputs[j]
			ui_craft_slot(x, sy, bw, bs, aspect, ing.block, ing.count, ch_w, ch_h)
			x += bw + ch_w * 1.1
		}
		text_draw(">", x, y, ch_w, ch_h, txt)
		x += ch_w * 2.0
		ui_craft_slot(x, sy, bw, bs, aspect, r.out, r.out_count, ch_w, ch_h)
		x += bw + ch_w * 1.2
		note := r.needs_furnace ? "  (FURNACE)" : ""
		text_draw(fmt.tprintf("%s%s", block_name(r.out), note), x, y, ch_w * 0.85, ch_h * 0.85, txt)
		y -= pitch
	}
	if hi < len(RECIPES) do text_center("v  more below", y + ch_h * 0.1, ch_w * 0.7, ch_h * 0.7, MC_TEXT_DIM)

	// Hover a recipe row → a tooltip listing exactly what it needs and what you
	// have, the Minecraft way.
	if hovr >= 0 {
		r := RECIPES[hovr]
		reqs: [3]ReqLine
		for j in 0 ..< r.n_in do reqs[j] = {r.inputs[j].block, r.inputs[j].count, inv_count(p, r.inputs[j].block)}
		note := r.needs_furnace ? " (NEAR FURNACE)" : ""
		ui_reqs_tooltip(
			mnx,
			mny,
			aspect,
			fmt.tprintf("%dx %s%s", r.out_count, block_name(r.out), note),
			reqs[:r.n_in],
		)
	}
}

// A small sunken slot with a block icon and its count, for the craft rows.
@(private = "file")
ui_craft_slot :: proc(x0, y0, bw, bs, aspect: f32, blk: BlockId, count: int, ch_w, ch_h: f32) {
	ui_bevel(x0, y0, x0 + bw, y0 + bs, 0.005, aspect, MC_SLOT, MC_SLOT_LO, MC_SLOT_HI)
	if blk != .Air do ui_block_icon(x0 + bw * 0.12, y0 + bs * 0.12, x0 + bw * 0.88, y0 + bs * 0.88, blk)
	if count > 1 {
		s := fmt.tprintf("%d", count)
		cw := ch_w * 0.62
		ax := bw / bs
		text_draw(s, x0 + bw - text_width(s, cw) - 0.004 * ax, y0 + ch_h * 0.62 + 0.006, cw, ch_h * 0.62, Vec4{1, 1, 1, 1})
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
	// Slots are square in pixels (w = sz/aspect), so a border that should look
	// even all the way round needs its horizontal offset scaled by w/sz (=
	// 1/aspect); using the same NDC value on both axes is what made the old
	// highlight look off-centre and squished.
	ax := w / sz
	aspect := sz / w // w == sz/aspect, so aspect recovers from the two
	// The selected/equipped slot gets a bright frame drawn behind it.
	if selected {
		t := f32(0.011)
		hud_quad(x0 - t * ax, y0 - t, x0 + w + t * ax, y0 + sz + t, Vec4{1.0, 0.98, 0.86, 1})
	}
	// A sunken Minecraft slot: dark top-left edge, light bottom-right, grey face.
	ui_bevel(x0, y0, x0 + w, y0 + sz, 0.006, aspect, MC_SLOT, MC_SLOT_LO, MC_SLOT_HI)
	if use_tex {
		if blk != .Air do ui_block_icon(x0 + w * 0.12, y0 + sz * 0.12, x0 + w * 0.88, y0 + sz * 0.88, blk)
	} else if count > 0 {
		hud_quad(x0 + w * 0.20, y0 + sz * 0.20, x0 + w * 0.80, y0 + sz * 0.80, Vec4{flat.r, flat.g, flat.b, 1})
	}
	// A tiny drop shadow keeps numbers legible over any icon.
	shadowed :: proc(s: string, x, y, cw, ch, ax: f32, col: Vec4) {
		text_draw(s, x + 0.003 * ax, y - 0.003, cw, ch, Vec4{0, 0, 0, 0.7})
		text_draw(s, x, y, cw, ch, col)
	}
	if num_label != "" {
		shadowed(num_label, x0 + 0.006 * ax, y0 + sz - 0.006, ch_w * 0.72, ch_h * 0.72, ax, Vec4{1, 0.95, 0.55, 1})
	}
	if count > 0 {
		s := fmt.tprintf("%d", count)
		cw2 := ch_w * 0.8
		// text_draw grows downward from its y, so sit the count a text-height up
		// from the slot floor to keep it inside the slot (over the grey face).
		shadowed(s, x0 + w - text_width(s, cw2) - 0.006 * ax, y0 + ch_h * 0.8 + 0.008, cw2, ch_h * 0.8, ax, Vec4{1, 1, 1, 1})
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

	// Dark chrome bar behind the slots (Minecraft hotbar look). Kept flush with
	// the slot tops so it doesn't ride up over the XP bar drawn just above.
	m := gap
	ui_bevel(
		x0 - m,
		y0 - m,
		x0 + total + m,
		y0 + sz,
		0.007,
		aspect,
		Vec4{0.11, 0.11, 0.12, 0.86},
		Vec4{0.52, 0.52, 0.55, 0.9},
		Vec4{0.02, 0.02, 0.02, 0.9},
	)

	for i in 0 ..< 9 {
		bx := x0 + f32(i) * (w + gap)
		s := p.slots[i]
		ui_slot(bx, y0, w, sz, true, s.id, Vec3{}, s.count, cw, ch_h, i == p.selected_slot, fmt.tprintf("%d", i + 1))
	}
}

// Chest panel (opened with R on a chest): the chest's slot grid on top, your
// whole inventory below. Drag stacks between them (left = whole/swap/merge,
// right = split/one); R empties the chest into your inventory.
ui_draw_chest :: proc(p: ^Player, w: ^World, fbw, fbh: int) {
	aspect := f32(fbw) / f32(max(fbh, 1))
	ui_dim()
	ui_panel(-0.82, -0.30, 0.82, 0.92, aspect)
	ch_h: f32 = 0.045
	ch_w := ch_h / aspect * (f32(GLYPH_W) / f32(GLYPH_H))
	text_center("CHEST", 0.85, ch_w * 1.2, ch_h * 1.2, MC_TEXT)

	ch := w.chests[g_chest_pos] // a copy is fine for drawing
	mnx, mny := cursor_ndc()
	hov := chest_view_hit(aspect, mnx, mny)

	// section labels above the chest grid and the player grid
	_, cy, _, csz := chest_view_rect(aspect, 0)
	_, py, _, _ := chest_view_rect(aspect, CHEST_SLOTS)
	lx := gx0chest(aspect)
	text_draw("CHEST", lx, cy + csz + 0.02, ch_w * 0.8, ch_h * 0.8, MC_TEXT)
	text_draw("YOUR INVENTORY", lx, py + csz + 0.02, ch_w * 0.8, ch_h * 0.8, MC_TEXT)

	for vi in 0 ..< CHEST_VIEW_N {
		x0, y0, sw, sz := chest_view_rect(aspect, vi)
		s := chest_view_stack(p, &ch, vi)^
		if vi == hov {
			hud_quad(x0 - 0.009, y0 - 0.009, x0 + sw + 0.009, y0 + sz + 0.009, Vec4{0.3, 0.85, 0.95, 1})
		}
		// mark the equipped hotbar slot
		equipped := vi >= CHEST_SLOTS + 27 && (vi - CHEST_SLOTS - 27) == p.selected_slot
		ui_slot(x0, y0, sw, sz, true, s.id, Vec3{}, s.count, ch_w, ch_h, equipped, "")
	}

	text_center(
		"DRAG TO MOVE STACKS   RIGHT-CLICK SPLIT   R TAKE ALL   E CLOSE",
		-0.25,
		ch_w * 0.6,
		ch_h * 0.6,
		MC_TEXT,
	)

	// held stack rides the cursor
	if g_cursor_stack.id != .Air {
		_, _, sw, sz := chest_view_rect(aspect, 0)
		ui_block_icon(mnx - sw * 0.5, mny - sz * 0.5, mnx + sw * 0.5, mny + sz * 0.5, g_cursor_stack.id)
		if g_cursor_stack.count > 1 {
			cs := fmt.tprintf("%d", g_cursor_stack.count)
			text_draw(cs, mnx + sw * 0.5 - text_width(cs, ch_w * 0.8), mny - sz * 0.5, ch_w * 0.8, ch_h * 0.8, Vec4{1, 1, 1, 1})
		}
	}
}

// Left edge of the chest-screen grid (for the section labels).
gx0chest :: proc(aspect: f32) -> f32 {
	x0, _, _, _ := chest_view_rect(aspect, 0)
	return x0
}

INV_COLS :: 9

// The stack currently held on the cursor while rearranging the inventory (empty
// when id == .Air). Left/right clicks move items between this and the slots.
g_cursor_stack: ItemStack

// Screen rectangle (NDC) of inventory slot `slot`: 0..8 are the hotbar row
// along the bottom, 9..35 are the 3x9 storage grid above it. Shared by the
// renderer and the mouse hit-test so a click always lands where it looks.
inv_slot_rect :: proc(aspect: f32, slot: int) -> (x0, y0, sw, sz: f32) {
	sz = 0.105
	sw = sz / aspect
	gap := f32(0.008)
	row_pitch := sz + gap // tight rows, like Minecraft's inventory grid
	gx0 := -(f32(INV_COLS) * (sw + gap) - gap) * 0.5
	storage_top := f32(0.27) // top edge of the first storage row (grid is vertically centred)
	if slot >= HOTBAR_SLOTS {
		s := slot - HOTBAR_SLOTS // 0..26
		x0 = gx0 + f32(s % 9) * (sw + gap)
		y0 = storage_top - f32(s / 9) * row_pitch - sz
	} else {
		x0 = gx0 + f32(slot) * (sw + gap)
		y0 = storage_top - 3 * row_pitch - 0.03 - sz // hotbar row, a small gap below the 3 storage rows
	}
	return
}

// The chest screen shows all the chest's slots plus the player's whole
// inventory in one grid so you can drag between them. A "view index" spans
// both: 0..CHEST_SLOTS-1 are chest slots, then CHEST_SLOTS.. are the player's
// slots (storage first, then hotbar). Compact geometry so it all fits.
CHEST_VIEW_N :: CHEST_SLOTS + INV_SLOTS

chest_view_rect :: proc(aspect: f32, vi: int) -> (x0, y0, sw, sz: f32) {
	sz = 0.078
	sw = sz / aspect
	gap := f32(0.008)
	pitch := sz + 0.036
	gx0 := -(f32(9) * (sw + gap) - gap) * 0.5
	top := f32(0.80)
	col, gridrow: int
	if vi < CHEST_SLOTS { 	// chest: rows 0..2
		col = vi % 9;gridrow = vi / 9
	} else if vi < CHEST_SLOTS + 27 { 	// player storage: rows 4..6 (gap row 3)
		s := vi - CHEST_SLOTS;col = s % 9;gridrow = s / 9 + 4
	} else { 	// player hotbar: row 7
		col = vi - CHEST_SLOTS - 27;gridrow = 7
	}
	x0 = gx0 + f32(col) * (sw + gap)
	y0 = top - f32(gridrow) * pitch - sz
	return
}

// Map a chest-view index to the actual stack it refers to. Chest indices resolve
// against `ch`, player indices against `p` (storage slots 9.., then hotbar 0..8).
chest_view_stack :: proc(p: ^Player, ch: ^Chest, vi: int) -> ^ItemStack {
	if vi < CHEST_SLOTS do return &ch.slots[vi]
	pv := vi - CHEST_SLOTS
	if pv < 27 do return &p.slots[HOTBAR_SLOTS + pv] // storage
	return &p.slots[pv - 27] // hotbar
}

chest_view_hit :: proc(aspect, nx, ny: f32) -> int {
	for vi in 0 ..< CHEST_VIEW_N {
		x0, y0, sw, sz := chest_view_rect(aspect, vi)
		if nx >= x0 && nx <= x0 + sw && ny >= y0 && ny <= y0 + sz do return vi
	}
	return -1
}

// Which inventory slot (0..INV_SLOTS-1) the NDC point is over, or -1.
inv_hit_slot :: proc(aspect, nx, ny: f32) -> int {
	for slot in 0 ..< INV_SLOTS {
		x0, y0, sw, sz := inv_slot_rect(aspect, slot)
		if nx >= x0 && nx <= x0 + sw && ny >= y0 && ny <= y0 + sz do return slot
	}
	return -1
}

// Left-click on any slot (`dst`) with the cursor stack: pick up a whole stack,
// drop it, merge onto a same-type stack (remainder stays on the cursor), or
// swap. Works on player and chest slots alike.
stack_click :: proc(dst: ^ItemStack) {
	held := &g_cursor_stack
	if held.id == .Air {
		g_cursor_stack = dst^ // pick up whole stack
		dst^ = {}
	} else if dst.id == .Air {
		dst^ = held^ // drop into empty slot
		held^ = {}
	} else if dst.id == held.id {
		space := STACK_MAX - dst.count // merge same type
		move := min(space, held.count)
		dst.count += move
		held.count -= move
		if held.count == 0 do held^ = {}
	} else {
		dst^, held^ = held^, dst^ // swap different types
	}
}

// Right-click on any slot: with nothing held, pick up half a stack; with a
// stack held, drop a single item onto an empty or same-type slot.
stack_rclick :: proc(dst: ^ItemStack) {
	held := &g_cursor_stack
	if held.id == .Air {
		if dst.id == .Air do return
		half := (dst.count + 1) / 2 // ceil half onto the cursor
		g_cursor_stack = {dst.id, half}
		dst.count -= half
		if dst.count == 0 do dst^ = {}
	} else if dst.id == .Air {
		dst^ = {held.id, 1} // place one
		held.count -= 1
		if held.count == 0 do held^ = {}
	} else if dst.id == held.id && dst.count < STACK_MAX {
		dst.count += 1 // add one to the same type
		held.count -= 1
		if held.count == 0 do held^ = {}
	}
}

inv_click_slot :: proc(p: ^Player, slot: int) {stack_click(&p.slots[slot])}
inv_rclick_slot :: proc(p: ^Player, slot: int) {stack_rclick(&p.slots[slot])}

// Move a whole stack from `src` into the [lo,hi) slot range: fill same-type
// stacks first, then the first empty slot. Shared by shift-click quick-move.
@(private = "file")
stack_move_into :: proc(src: ^ItemStack, slots: []ItemStack, lo, hi: int) {
	if src.id == .Air do return
	for i in lo ..< hi {
		if src.count == 0 do break
		d := &slots[i]
		if d.id == src.id && d.count < STACK_MAX {
			m := min(STACK_MAX - d.count, src.count)
			d.count += m;src.count -= m
		}
	}
	for i in lo ..< hi {
		if src.count == 0 do break
		d := &slots[i]
		if d.id == .Air {d^ = src^;src^ = {};return}
	}
	if src.count == 0 do src^ = {}
}

// Shift-click quick-move: a storage stack jumps to the hotbar, a hotbar stack to
// storage — the same one-click transfer Minecraft does.
inv_quick_move :: proc(p: ^Player, slot: int) {
	to_hotbar := slot >= HOTBAR_SLOTS
	lo, hi := to_hotbar ? 0 : HOTBAR_SLOTS, to_hotbar ? HOTBAR_SLOTS : INV_SLOTS
	stack_move_into(&p.slots[slot], p.slots[:], lo, hi)
}

// Press a hotbar number (1-9) while hovering a slot to swap that item straight
// into the numbered hotbar slot (Minecraft's number-key swap).
inv_swap_to_hotbar :: proc(p: ^Player, slot, hotbar: int) {
	if slot == hotbar do return
	p.slots[slot], p.slots[hotbar] = p.slots[hotbar], p.slots[slot]
}

// Put a cursor stack back into the inventory grid (used when a menu closes so a
// held stack isn't lost). Any overflow is left in `s` for the caller to drop.
inv_return_to_grid :: proc(p: ^Player, s: ^ItemStack) {
	stack_move_into(s, p.slots[:], 0, INV_SLOTS)
}

// Shift-click inside the chest screen: chest slots dump into your inventory and
// inventory slots dump into the chest.
inv_quick_move_chest :: proc(p: ^Player, ch: ^Chest, vi: int) {
	src := chest_view_stack(p, ch, vi)
	if src.id == .Air do return
	if vi < CHEST_SLOTS {
		stack_move_into(src, p.slots[:], 0, INV_SLOTS) // chest -> player (hotbar first)
	} else {
		stack_move_into(src, ch.slots[:], 0, CHEST_SLOTS) // player -> chest
	}
}

// Which Tools-tab row the NDC point is over, returned as the 1-8 "select"
// number (1-4 tools, 5-8 armor) or -1. Mirrors ui_draw_tools_tab's layout
// (ch_h = 0.045, rows pitched 1.9*ch_h from top=0.66).
inv_hit_tools_row :: proc(nx, ny: f32) -> int {
	ch_h := f32(0.045)
	step := ch_h * 1.55
	top := f32(0.30)
	if nx < -0.58 || nx > 0.60 do return -1
	for k in 0 ..< 4 { 	// tools
		y := top - f32(k) * step
		if ny <= y + ch_h * 0.5 && ny >= y - step + ch_h * 0.5 do return k + 1
	}
	armor0 := top - 4 * step - ch_h * 0.5 - step // first armor row (after the ARMOR header)
	for s in 0 ..< 4 {
		y := armor0 - f32(s) * step
		if ny <= y + ch_h * 0.5 && ny >= y - step + ch_h * 0.5 do return 5 + s
	}
	return -1
}

// Which Craft-tab recipe row the NDC point is over, or -1. Mirrors the row
// layout in ui_draw_craft_tab (called with ch_h scaled by 0.95, from top).
// Which tab button (0 Items / 1 Craft / 2 Tools) the NDC point is over, or -1.
// Mirrors ui_draw_tabs called from ui_draw_inventory (y = 0.44, ch scaled 0.9).
inv_hit_tab :: proc(nx, ny: f32) -> int {
	y := f32(0.44)
	ch_h := f32(0.045 * 0.9)
	if ny < y - ch_h * 1.05 || ny > y + ch_h * 0.55 do return -1
	seg := f32(0.29)
	x0 := -seg * f32(INV_TAB_COUNT) * 0.5
	for i in 0 ..< INV_TAB_COUNT {
		cx := x0 + f32(i) * seg + seg * 0.5
		w2 := seg * 0.44
		if nx >= cx - w2 && nx <= cx + w2 do return i
	}
	return -1
}

CRAFT_ROW_CH_H :: f32(0.045 * 0.95)
inv_hit_craft_row :: proc(nx, ny: f32) -> int {
	top := f32(0.30)
	spacing := CRAFT_ROW_CH_H * 1.95
	craft_scroll_clamp()
	hi := min(len(RECIPES), g_craft_scroll + CRAFT_VISIBLE)
	for i in g_craft_scroll ..< hi {
		y := top - f32(i - g_craft_scroll) * spacing
		if nx >= -0.40 && nx <= 0.46 && ny <= y + CRAFT_ROW_CH_H * 0.55 && ny >= y - spacing + CRAFT_ROW_CH_H * 0.6 {
			return i
		}
	}
	return -1
}

// Full-screen inventory: a tabbed Minecraft-style panel (ITEMS / CRAFT /
// TOOLS, selected with E/T/X) with the hotbar mirrored at the bottom on
// every tab. Items are a real selectable grid (arrow keys move the cursor,
// a number key assigns the highlighted item to that hotbar slot); Craft and
// Tools let you make/upgrade things right here, not just look at them.
ui_draw_inventory :: proc(p: ^Player, w: ^World, fbw, fbh: int) {
	aspect := f32(fbw) / f32(max(fbh, 1))

	ui_dim() // darken the world behind
	ui_panel(-0.62, -0.50, 0.62, 0.66, aspect) // centred stone window

	ch_h: f32 = 0.045
	ch_w := ch_h / aspect * (f32(GLYPH_W) / f32(GLYPH_H))

	// Title for the current tab, then the tab buttons under it.
	title :=
		g_inv_tab == .Items \
		? "INVENTORY" \
		: (g_inv_tab == .Craft ? "CRAFTING" : (g_inv_tab == .Tools ? "EQUIPMENT" : "SKILLS"))
	text_center(title, 0.54, ch_w * 1.1, ch_h * 1.1, MC_TEXT)
	ui_draw_tabs(fbw, fbh, ch_w * 0.9, ch_h * 0.9, 0.44)

	mnx, mny := cursor_ndc() // OS cursor released while a menu is open
	_, hotbar_y, sw, sz := inv_slot_rect(aspect, 0)

	switch g_inv_tab {
	case .Items:
		hov := inv_hit_slot(aspect, mnx, mny)
		// Storage grid (slots 9..35) then the hotbar row (0..8), all real slots.
		for slot in 0 ..< INV_SLOTS {
			x0, y0, _, _ := inv_slot_rect(aspect, slot)
			s := p.slots[slot]
			if slot == hov {
				hud_quad(x0 - 0.010, y0 - 0.010, x0 + sw + 0.010, y0 + sz + 0.010, Vec4{1, 1, 1, 0.85})
			}
			num := slot < HOTBAR_SLOTS ? fmt.tprintf("%d", slot + 1) : ""
			ui_slot(x0, y0, sw, sz, true, s.id, Vec3{}, s.count, ch_w, ch_h, slot == p.selected_slot, num)
		}
	case .Craft:
		ui_draw_craft_tab(p, w, aspect, ch_w * 0.95, ch_h * 0.95, 0.30)
	case .Tools:
		ui_draw_tools_tab(p, aspect, ch_w, ch_h, 0.30)
	case .Skills:
		ui_draw_skills_tab(p, ch_w, ch_h, 0.30)
	}

	action_hint: string
	switch g_inv_tab {
	case .Items:
		action_hint = "SHIFT-CLICK MOVE    HOVER + 1-9 SWAP    CLICK OUTSIDE TO DROP    RIGHT-CLICK SPLIT"
	case .Craft:
		action_hint = "CLICK OR PRESS 1-9 TO CRAFT"
	case .Tools:
		action_hint = "PRESS 1-4 TOOLS    5-8 ARMOR"
	case .Skills:
		action_hint = "SKILLS LEVEL UP AS YOU MINE, FIGHT, FARM AND FORAGE"
	}
	text_center(action_hint, -0.38, ch_w * 0.6, ch_h * 0.6, MC_TEXT)
	text_center(
		"E INVENTORY    T CRAFT    X EQUIP    R USE/CHEST    G EAT",
		-0.44,
		ch_w * 0.55,
		ch_h * 0.55,
		MC_TEXT_DIM,
	)

	// The held stack rides the cursor, drawn last so it's on top of everything.
	if g_cursor_stack.id != .Air && g_inv_tab == .Items {
		ui_block_icon(mnx - sw * 0.5, mny - sz * 0.5, mnx + sw * 0.5, mny + sz * 0.5, g_cursor_stack.id)
		if g_cursor_stack.count > 1 {
			s := fmt.tprintf("%d", g_cursor_stack.count)
			text_draw(s, mnx + sw * 0.5 - text_width(s, ch_w * 0.8), mny - sz * 0.5, ch_w * 0.8, ch_h * 0.8, Vec4{1, 1, 1, 1})
		}
	}
}

// Left edge of the 9-wide inventory grid (for row labels).
gx0inv :: proc(aspect: f32) -> f32 {
	x0, _, _, _ := inv_slot_rect(aspect, HOTBAR_SLOTS) // first storage slot
	return x0
}
