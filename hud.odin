package main

import "core:fmt"
import gl "vendor:OpenGL"

h_prog: u32
h_color: i32
h_vao: u32
h_vbo: u32

hud_init :: proc() {
	ok: bool
	if h_prog, ok = gl.load_shaders_source(HUD_VERT, HUD_FRAG); !ok {
		fmt.panicf("hud shader failed to compile/link")
	}
	h_color = gl.GetUniformLocation(h_prog, "uColor")

	gl.GenVertexArrays(1, &h_vao)
	gl.GenBuffers(1, &h_vbo)
	gl.BindVertexArray(h_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, h_vbo)
	gl.BufferData(gl.ARRAY_BUFFER, 4 * size_of(Vec2), nil, gl.DYNAMIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, i32(size_of(Vec2)), 0)
	gl.BindVertexArray(0)
}

// Screen-space crosshair (two short lines) drawn directly in NDC.
hud_draw :: proc(fbw, fbh: i32) {
	aspect := f32(fbw) / f32(max(fbh, 1))
	s: f32 = 0.02
	verts := [4]Vec2{{-s / aspect, 0}, {s / aspect, 0}, {0, -s}, {0, s}}

	gl.BindVertexArray(h_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, h_vbo)
	gl.BufferSubData(gl.ARRAY_BUFFER, 0, 4 * size_of(Vec2), &verts[0])
	gl.UseProgram(h_prog)
	gl.Uniform4f(h_color, 1.0, 1.0, 1.0, 0.85)
	gl.Disable(gl.DEPTH_TEST)
	gl.DrawArrays(gl.LINES, 0, 4)
	gl.Enable(gl.DEPTH_TEST)
}
