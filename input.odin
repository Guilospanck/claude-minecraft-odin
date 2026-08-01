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
	nav_up, nav_down:     bool, // arrow keys (menus)
	nav_left, nav_right:  bool,
	select:               int, // 1..9, or 0 for none
	quit:                 bool,
	fb_w, fb_h:           i32,
}

g_input: InputState
g_win: glfw.WindowHandle

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
}

mouse_cb :: proc "c" (win: glfw.WindowHandle, button, action, mods: c.int) {
	if action == glfw.PRESS {
		if button == glfw.MOUSE_BUTTON_LEFT do g_input.break_req = true
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
