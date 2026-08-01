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

// Public filled NDC rect with its own program + blend state (for UI panels).
hud_quad :: proc(x0, y0, x1, y1: f32, col: Vec4) {
	gl.UseProgram(h_prog)
	gl.Disable(gl.DEPTH_TEST)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	hud_rect(x0, y0, x1, y1, col)
	gl.Disable(gl.BLEND)
	gl.Enable(gl.DEPTH_TEST)
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

// Ten heart icons at the bottom-left; each represents 2 health points.
hud_draw_health :: proc(health, fbw, fbh: int) {
	aspect := f32(fbw) / f32(max(fbh, 1))
	sz: f32 = 0.052
	w := sz / aspect
	gap: f32 = 0.004
	x_start: f32 = -0.97
	y0: f32 = -0.91
	for i in 0 ..< 10 {
		x0 := x_start + f32(i) * (w + gap)
		hp := health - i * 2
		idx := hp >= 2 ? 0 : (hp == 1 ? 1 : 2) // full / half / empty heart
		hud_icon(x0, y0, x0 + w, y0 + sz, idx)
	}
}

// Ten drumstick icons at the bottom-right (each = 2 hunger points).
hud_draw_hunger :: proc(hunger, fbw, fbh: int) {
	aspect := f32(fbw) / f32(max(fbh, 1))
	sz: f32 = 0.052
	w := sz / aspect
	gap: f32 = 0.004
	y0: f32 = -0.91
	x_end: f32 = 0.97
	for i in 0 ..< 10 {
		x1 := x_end - f32(i) * (w + gap)
		hg := hunger - i * 2
		idx := hg >= 2 ? 3 : (hg == 1 ? 4 : 5) // full / half / empty drumstick
		hud_icon(x1 - w, y0, x1, y0 + sz, idx)
	}
}

// A swatch of the currently selected block, bottom-centre.
hud_draw_selected :: proc(sel: BlockId, fbw, fbh: int) {
	gl.UseProgram(h_prog)
	gl.Disable(gl.DEPTH_TEST)
	aspect := f32(fbw) / f32(max(fbh, 1))
	sz: f32 = 0.09
	w := sz / aspect
	y0: f32 = -0.985
	b: f32 = 0.006
	hud_rect(-w / 2 - b, y0 - b, w / 2 + b, y0 + sz + b, Vec4{0.9, 0.9, 0.9, 1}) // border
	col := block_color(sel)
	hud_rect(-w / 2, y0, w / 2, y0 + sz, Vec4{col.r, col.g, col.b, 1})
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
