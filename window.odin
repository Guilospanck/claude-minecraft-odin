package main

import "core:fmt"
import gl "vendor:OpenGL"
import "vendor:glfw"

window_init :: proc(width, height: i32, title: cstring) -> glfw.WindowHandle {
	if !glfw.Init() {
		fmt.panicf("glfw.Init failed")
	}
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 1)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, 1) // required on macOS core profile
	glfw.WindowHint(glfw.RESIZABLE, 1)

	win := glfw.CreateWindow(width, height, title, nil, nil)
	if win == nil {
		glfw.Terminate()
		fmt.panicf("failed to create GLFW window")
	}
	glfw.MakeContextCurrent(win)
	glfw.SwapInterval(1) // vsync
	gl.load_up_to(4, 1, glfw.gl_set_proc_address)

	g_win = win
	glfw.SetInputMode(win, glfw.CURSOR, glfw.CURSOR_DISABLED)
	glfw.SetKeyCallback(win, key_cb)
	glfw.SetMouseButtonCallback(win, mouse_cb)
	glfw.SetCursorPosCallback(win, cursor_cb)
	glfw.SetScrollCallback(win, scroll_cb)
	glfw.SetFramebufferSizeCallback(win, framebuffer_cb)

	fbw, fbh := glfw.GetFramebufferSize(win)
	g_input.fb_w = i32(fbw)
	g_input.fb_h = i32(fbh)
	return win
}
