package main

// A short on-screen message (Minecraft's "action bar"), used for gameplay
// feedback — sleeping, tilling, chest actions, crafting, tool breaks — that
// previously only went to fmt.println and so was invisible during normal
// play. Showing a new toast replaces whatever is currently up.
//
// Backed by a fixed buffer (no heap allocation) rather than a cloned string:
// `odin test` runs @(test) procs concurrently across threads, and since this
// is a package-level global, a clone+delete-on-replace pattern here would
// race between tests (double-free/leak). The real game loop is
// single-threaded, so a fixed buffer is simplest and sidesteps that entirely.

TOAST_BUF_LEN :: 64

@(private = "file")
g_toast_buf: [TOAST_BUF_LEN]u8
@(private = "file")
g_toast_len: int
@(private = "file")
g_toast_life: f32
@(private = "file")
g_toast_max: f32

toast_show :: proc(text: string, life: f32 = 2.2) {
	n := min(len(text), TOAST_BUF_LEN)
	// If the same message is still up (e.g. a held key re-firing), just refresh
	// its time-to-live instead of restarting the slide-in animation.
	if g_toast_life > 0 && g_toast_len == n && string(g_toast_buf[:n]) == text[:n] {
		g_toast_life = max(g_toast_life, life)
		return
	}
	copy(g_toast_buf[:n], text[:n])
	g_toast_len = n
	g_toast_life = life
	g_toast_max = life
}

toast_tick :: proc(dt: f32) {
	if g_toast_life > 0 do g_toast_life -= dt
}

// Sits well above the hotbar/health/hunger cluster so it never overlaps them.
TOAST_Y :: f32(-0.64)

toast_draw :: proc(fbw, fbh: int) {
	if g_toast_life <= 0 || g_toast_len == 0 do return
	text := string(g_toast_buf[:g_toast_len])
	aspect := f32(fbw) / f32(max(fbh, 1))
	ch_h: f32 = 0.04
	ch_w := ch_h / aspect * (f32(GLYPH_W) / f32(GLYPH_H))
	// Ease in over the first 0.22s and out over the last 0.4s so it slides in
	// and fades away instead of popping.
	elapsed := g_toast_max - g_toast_life
	a := min(clamp(elapsed / 0.22, 0, 1), clamp(g_toast_life / 0.4, 0, 1))
	w := text_width(text, ch_w)
	padx: f32 = 0.028
	pady: f32 = 0.02
	rise := (1 - clamp(elapsed / 0.22, 0, 1)) * 0.03 // small upward slide-in
	y := TOAST_Y - rise
	cy := y + ch_h * 0.5 // vertical centre of the text
	hw := w * 0.5 + padx
	hh := ch_h * 0.5 + pady
	bx := 0.006 / aspect // border thickness, aspect-corrected so it's even all round
	by: f32 = 0.006
	// A framed plate: a solid gold border under a near-opaque dark fill, so the
	// message reads clearly against any background.
	hud_quad(-hw - bx, cy - hh - by, hw + bx, cy + hh + by, Vec4{0.85, 0.70, 0.30, 0.9 * a})
	hud_quad(-hw, cy - hh, hw, cy + hh, Vec4{0.07, 0.07, 0.10, 0.92 * a})
	text_center(text, y, ch_w, ch_h, Vec4{1, 1, 1, a})
}
