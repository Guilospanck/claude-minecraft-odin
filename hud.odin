package main

import "core:fmt"
import gl "vendor:OpenGL"

h_prog: u32
h_color: i32
h_vao: u32
h_vbo: u32
h_quad_vao: u32
h_quad_vbo: u32

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

	// filled-quad buffer (health bar): 6 vertices, updated per rect
	gl.GenVertexArrays(1, &h_quad_vao)
	gl.GenBuffers(1, &h_quad_vbo)
	gl.BindVertexArray(h_quad_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, h_quad_vbo)
	gl.BufferData(gl.ARRAY_BUFFER, 6 * size_of(Vec2), nil, gl.DYNAMIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, i32(size_of(Vec2)), 0)
	gl.BindVertexArray(0)
}

@(private = "file")
hud_rect :: proc(x0, y0, x1, y1: f32, col: Vec4) {
	verts := [6]Vec2{{x0, y0}, {x1, y0}, {x1, y1}, {x0, y0}, {x1, y1}, {x0, y1}}
	gl.BindVertexArray(h_quad_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, h_quad_vbo)
	gl.BufferSubData(gl.ARRAY_BUFFER, 0, 6 * size_of(Vec2), &verts[0])
	gl.Uniform4f(h_color, col.r, col.g, col.b, col.a)
	gl.DrawArrays(gl.TRIANGLES, 0, 6)
}

// Ten heart pips at the bottom-left; each represents 2 health points.
hud_draw_health :: proc(health, fbw, fbh: int) {
	gl.UseProgram(h_prog)
	gl.Disable(gl.DEPTH_TEST)
	aspect := f32(fbw) / f32(max(fbh, 1))
	sz: f32 = 0.04
	w := sz / aspect
	gap: f32 = 0.006
	x_start: f32 = -0.96
	y0: f32 = -0.90
	for i in 0 ..< 10 {
		x0 := x_start + f32(i) * (w + gap)
		filled := health > i * 2
		col := filled ? Vec4{0.90, 0.16, 0.16, 1} : Vec4{0.22, 0.22, 0.22, 1}
		hud_rect(x0, y0, x0 + w, y0 + sz, col)
	}
	gl.Enable(gl.DEPTH_TEST)
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
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.DrawArrays(gl.LINES, 0, 4)
	gl.Disable(gl.BLEND)
	gl.Enable(gl.DEPTH_TEST)
}
