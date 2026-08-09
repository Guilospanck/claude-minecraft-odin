package main

import "core:c"
import gl "vendor:OpenGL"
import "vendor:glfw"

// Global input state. GLFW callbacks use the "c" calling convention and cannot
// capture, so they write into this shared struct that the main loop drains.
InputState :: struct {
	last_x, last_y:       f64,
	have_last:            bool,
	dx, dy:               f64, // accumulated mouse delta since last frame
	mx, my:               f64, // absolute cursor position (window/screen coords)
	break_req, place_req: bool, // one-shot mouse clicks
	fly_toggle:           bool, // one-shot F press
	craft:                bool, // one-shot C press
	smelt:                bool, // one-shot V press
	inv_toggle:           bool, // one-shot E press
	eat:                  bool, // one-shot G press
	start:                bool, // Enter (title screen)
	settings_toggle:      bool, // O
	craft_toggle:         bool, // T
	portal:               bool, // P (build a nether portal)
	interact:             bool, // one-shot R press (use/till/plant/harvest/sleep)
	confirm:              bool, // one-shot Y press (confirm quit)
	tools_toggle:         bool, // one-shot X press (tools/craft menu)
	skills_toggle:        bool, // one-shot K press (skills menu)
	dev_toggle:           bool, // one-shot ` press (dev/creative overlay)
	tool_cycle:           bool, // one-shot H press (cycle the held tool)
	nav_up, nav_down:     bool, // arrow keys (menus)
	nav_left, nav_right:  bool,
	select:               int, // 1..9, or 0 for none
	scroll:               f32, // accumulated mouse-wheel delta since last frame
	quit:                 bool,
	fb_w, fb_h:           i32,
}

g_input: InputState
g_win: glfw.WindowHandle
g_cursor_free: bool // true while a menu has released the OS cursor for clicking
g_prev_left_ui: bool // left-button state last frame, for menu press/release edges
g_prev_right_ui: bool // right-button state last frame (inventory split/place)
g_prev_mid: bool // middle-button state last frame, for pick-block edges

cursor_cb :: proc "c" (win: glfw.WindowHandle, x, y: f64) {
	if !g_input.have_last {
		g_input.last_x = x
		g_input.last_y = y
		g_input.have_last = true
	}
	g_input.dx += x - g_input.last_x
	g_input.dy += y - g_input.last_y
	g_input.last_x = x
	g_input.last_y = y
	g_input.mx = x
	g_input.my = y
}

// Absolute cursor position in normalized device coords ([-1,1], y up), for
// hit-testing menus while the OS cursor is released. Returns something far
// off-screen if the window size isn't known yet.
cursor_ndc :: proc() -> (f32, f32) {
	ww, wh := glfw.GetWindowSize(g_win)
	if ww <= 0 || wh <= 0 do return -2, -2
	nx := f32(g_input.mx) / f32(ww) * 2 - 1
	ny := 1 - f32(g_input.my) / f32(wh) * 2
	return nx, ny
}

scroll_cb :: proc "c" (win: glfw.WindowHandle, xoff, yoff: f64) {
	g_input.scroll += f32(yoff)
}

mouse_cb :: proc "c" (win: glfw.WindowHandle, button, action, mods: c.int) {
	if action == glfw.PRESS {
		if button == glfw.MOUSE_BUTTON_LEFT {
			// Ctrl+click is macOS's universal secondary click -> treat as place.
			// (Some setups deliver it as left+ctrl rather than a right button.)
			if (mods & glfw.MOD_CONTROL) != 0 {
				g_input.place_req = true
			} else {
				g_input.break_req = true
			}
		}
		if button == glfw.MOUSE_BUTTON_RIGHT do g_input.place_req = true
	}
}

key_cb :: proc "c" (win: glfw.WindowHandle, key, scancode, action, mods: c.int) {
	if action != glfw.PRESS do return
	switch key {
	case glfw.KEY_ESCAPE:
		g_input.quit = true
	case glfw.KEY_F:
		g_input.fly_toggle = true
	case glfw.KEY_C:
		g_input.craft = true
	case glfw.KEY_V:
		g_input.smelt = true
	case glfw.KEY_E:
		g_input.inv_toggle = true
	case glfw.KEY_G:
		g_input.eat = true
	case glfw.KEY_ENTER:
		g_input.start = true
	case glfw.KEY_O:
		g_input.settings_toggle = true
	case glfw.KEY_T:
		g_input.craft_toggle = true
	case glfw.KEY_P:
		g_input.portal = true
	case glfw.KEY_R:
		g_input.interact = true
	case glfw.KEY_Y:
		g_input.confirm = true
	case glfw.KEY_X:
		g_input.tools_toggle = true
	case glfw.KEY_GRAVE_ACCENT:
		g_input.dev_toggle = true
	case glfw.KEY_H:
		g_input.tool_cycle = true
	case glfw.KEY_K:
		g_input.skills_toggle = true
	case glfw.KEY_Q:
		g_input.place_req = true // keyboard place (trackpads may lack right-click)
	case glfw.KEY_UP:
		g_input.nav_up = true
	case glfw.KEY_DOWN:
		g_input.nav_down = true
	case glfw.KEY_LEFT:
		g_input.nav_left = true
	case glfw.KEY_RIGHT:
		g_input.nav_right = true
	case glfw.KEY_1 ..= glfw.KEY_9:
		g_input.select = int(key - glfw.KEY_1) + 1
	}
}

framebuffer_cb :: proc "c" (win: glfw.WindowHandle, width, height: c.int) {
	g_input.fb_w = i32(width)
	g_input.fb_h = i32(height)
	gl.Viewport(0, 0, i32(width), i32(height))
}
