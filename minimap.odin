package main

import gl "vendor:OpenGL"

// Top-down surface map of the loaded area around the player, drawn top-right.
MINIMAP_N :: 64 // texel resolution
MINIMAP_SCALE :: 2 // world blocks per texel

@(private = "file")
MMVert :: struct {
	pos: Vec2,
	uv:  Vec2,
}

mm_prog: u32
mm_umap: i32
mm_tex: u32
mm_vao: u32
mm_vbo: u32
@(private = "file")
mm_buf: [MINIMAP_N * MINIMAP_N * 3]u8
@(private = "file")
mm_counter: int

minimap_init :: proc() {
	ok: bool
	if mm_prog, ok = gl.load_shaders_source(MINIMAP_VERT, MINIMAP_FRAG); !ok do return
	mm_umap = gl.GetUniformLocation(mm_prog, "uMap")

	gl.GenTextures(1, &mm_tex)
	gl.BindTexture(gl.TEXTURE_2D, mm_tex)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.RGB8,
		MINIMAP_N,
		MINIMAP_N,
		0,
		gl.RGB,
		gl.UNSIGNED_BYTE,
		nil,
	)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	gl.GenVertexArrays(1, &mm_vao)
	gl.GenBuffers(1, &mm_vbo)
	gl.BindVertexArray(mm_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, mm_vbo)
	gl.BufferData(gl.ARRAY_BUFFER, 6 * size_of(MMVert), nil, gl.DYNAMIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, i32(size_of(MMVert)), offset_of(MMVert, pos))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, i32(size_of(MMVert)), offset_of(MMVert, uv))
	gl.BindVertexArray(0)
}

@(private = "file")
surface_color :: proc(w: ^World, wx, wz: int) -> [3]u8 {
	for y := CHUNK_H - 1; y >= 0; y -= 1 {
		b := world_block(w, wx, y, wz)
		if b == .Air do continue
		base := b == .Water ? Vec3{0.20, 0.42, 0.72} : block_color(b)
		relief := clamp(0.55 + 0.45 * f32(y - 44) / 40.0, 0.45, 1.15) // height shading
		c := base * relief
		return [3]u8 {
			u8(clamp(c.r, 0, 1) * 255),
			u8(clamp(c.g, 0, 1) * 255),
			u8(clamp(c.b, 0, 1) * 255),
		}
	}
	return [3]u8{18, 18, 26} // unloaded / void
}

@(private = "file")
minimap_rebuild :: proc(w: ^World, p: ^Player) {
	cx := int(p.pos.x)
	cz := int(p.pos.z)
	half := MINIMAP_N / 2
	for j in 0 ..< MINIMAP_N {
		for i in 0 ..< MINIMAP_N {
			wx := cx + (i - half) * MINIMAP_SCALE
			wz := cz + (j - half) * MINIMAP_SCALE
			col := surface_color(w, wx, wz)
			row := MINIMAP_N - 1 - j // north (-z) at the top
			idx := (row * MINIMAP_N + i) * 3
			mm_buf[idx] = col[0]
			mm_buf[idx + 1] = col[1]
			mm_buf[idx + 2] = col[2]
		}
	}
	gl.BindTexture(gl.TEXTURE_2D, mm_tex)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexSubImage2D(
		gl.TEXTURE_2D,
		0,
		0,
		0,
		MINIMAP_N,
		MINIMAP_N,
		gl.RGB,
		gl.UNSIGNED_BYTE,
		&mm_buf[0],
	)
	gl.BindTexture(gl.TEXTURE_2D, 0)
}

minimap_draw :: proc(w: ^World, p: ^Player, fbw, fbh: int) {
	if mm_prog == 0 do return
	mm_counter += 1
	if mm_counter % 12 == 1 do minimap_rebuild(w, p) // ~5 rebuilds/sec

	aspect := f32(fbw) / f32(max(fbh, 1))
	size: f32 = 0.34
	wn := size / aspect
	x1: f32 = 0.97
	x0 := x1 - wn
	y1: f32 = 0.97
	y0 := y1 - size

	hud_quad(x0 - 0.008, y0 - 0.008, x1 + 0.008, y1 + 0.008, Vec4{0.08, 0.08, 0.10, 0.9})

	verts := [6]MMVert {
		{{x0, y0}, {0, 0}},
		{{x1, y0}, {1, 0}},
		{{x1, y1}, {1, 1}},
		{{x0, y0}, {0, 0}},
		{{x1, y1}, {1, 1}},
		{{x0, y1}, {0, 1}},
	}
	gl.UseProgram(mm_prog)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, mm_tex)
	gl.Uniform1i(mm_umap, 0)
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.CULL_FACE)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.BindVertexArray(mm_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, mm_vbo)
	gl.BufferSubData(gl.ARRAY_BUFFER, 0, 6 * size_of(MMVert), &verts[0])
	gl.DrawArrays(gl.TRIANGLES, 0, 6)
	gl.Disable(gl.BLEND)
	gl.Enable(gl.CULL_FACE)
	gl.Enable(gl.DEPTH_TEST)

	// player marker at the centre
	cx := (x0 + x1) * 0.5
	cy := (y0 + y1) * 0.5
	m := size * 0.03
	hud_quad(cx - m, cy - m, cx + m, cy + m, Vec4{1, 1, 1, 1})
}
