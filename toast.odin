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
	copy(g_toast_buf[:n], text[:n])
	g_toast_len = n
	g_toast_life = life
	g_toast_max = life
}

toast_tick :: proc(dt: f32) {
	if g_toast_life > 0 do g_toast_life -= dt
}

TOAST_Y :: f32(-0.80)

toast_draw :: proc(fbw, fbh: int) {
	if g_toast_life <= 0 || g_toast_len == 0 do return
	text := string(g_toast_buf[:g_toast_len])
	aspect := f32(fbw) / f32(max(fbh, 1))
	ch_h: f32 = 0.042
	ch_w := ch_h / aspect * (f32(GLYPH_W) / f32(GLYPH_H))
	// fade in the last 0.4s so it doesn't just vanish
	a := clamp(g_toast_life / 0.4, 0, 1)
	w := text_width(text, ch_w)
	pad: f32 = 0.02
	hud_quad(-w * 0.5 - pad, TOAST_Y - 0.01, w * 0.5 + pad, TOAST_Y + ch_h + 0.01, Vec4{0.05, 0.05, 0.08, 0.75 * a})
	text_center(text, TOAST_Y, ch_w, ch_h, Vec4{1, 1, 1, a})
}
