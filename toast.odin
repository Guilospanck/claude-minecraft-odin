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
	padx := 0.022 / aspect
	pady: f32 = 0.018
	rise := (1 - clamp(elapsed / 0.22, 0, 1)) * 0.03 // small upward slide-in
	y := TOAST_Y - rise
	// a soft rounded-looking plate: an outer border quad under an inner fill
	hud_quad(-w * 0.5 - padx - 0.004, y - pady - 0.004, w * 0.5 + padx + 0.004, y + ch_h + pady + 0.004, Vec4{0.9, 0.78, 0.4, 0.5 * a})
	hud_quad(-w * 0.5 - padx, y - pady, w * 0.5 + padx, y + ch_h + pady, Vec4{0.06, 0.06, 0.09, 0.82 * a})
	text_center(text, y, ch_w, ch_h, Vec4{1, 1, 1, a})
}
