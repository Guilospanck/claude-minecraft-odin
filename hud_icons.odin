package main

import gl "vendor:OpenGL"

// Small pixel-art HUD icons (hearts + drumsticks + air bubble) baked into an
// RGBA texture. Icon indices: 0 heart-full, 1 heart-half, 2 heart-empty,
//               3 drum-full,  4 drum-half,  5 drum-empty, 6 bubble.
ICON_PX :: 8
ICON_COUNT :: 7
ICON_ATLAS_W :: ICON_PX * ICON_COUNT
ICON_BUBBLE :: 6

@(private = "file")
Col :: [4]u8
@(private = "file")
RED :: Col{212, 46, 52, 255}
@(private = "file")
RED_DK :: Col{74, 26, 30, 255}
@(private = "file")
MEAT :: Col{150, 88, 52, 255}
@(private = "file")
BONE :: Col{236, 226, 192, 255}
@(private = "file")
GRAY :: Col{62, 60, 56, 255}
@(private = "file")
BUBBLE_C :: Col{150, 205, 245, 255}
@(private = "file")
BUBBLE_HI :: Col{225, 245, 255, 255}
@(private = "file")
CLEAR :: Col{0, 0, 0, 0}

// bit7 = leftmost column
@(private = "file")
HEART := [8]u8{0x6C, 0xFE, 0xFE, 0xFE, 0x7C, 0x38, 0x10, 0x00}
@(private = "file")
DRUM_MEAT := [8]u8{0x0E, 0x1E, 0x1E, 0x3C, 0x70, 0x20, 0x00, 0x00}
@(private = "file")
DRUM_BONE := [8]u8{0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0xC0, 0x00}
@(private = "file")
BUBBLE := [8]u8{0x3C, 0x7E, 0xFF, 0xFF, 0xFF, 0xFF, 0x7E, 0x3C}

@(private = "file")
MMIVert :: struct {
	pos: Vec2,
	uv:  Vec2,
}

icon_prog: u32
icon_utex: i32
icon_tex: u32
icon_vao: u32
icon_vbo: u32

@(private = "file")
bit_on :: proc(mask: u8, col: int) -> bool {
	return (mask >> uint(7 - col)) & 1 == 1
}

icons_init :: proc() {
	ok: bool
	if icon_prog, ok = gl.load_shaders_source(ICON_VERT, ICON_FRAG); !ok do return
	icon_utex = gl.GetUniformLocation(icon_prog, "uTex")

	px := make([]u8, ICON_ATLAS_W * ICON_PX * 4)
	defer delete(px)
	for idx in 0 ..< ICON_COUNT {
		ox := idx * ICON_PX
		for row in 0 ..< ICON_PX {
			for col in 0 ..< ICON_PX {
				c := CLEAR
				switch idx {
				case 0:
					if bit_on(HEART[row], col) do c = RED
				case 1:
					if bit_on(HEART[row], col) do c = col < 4 ? RED : RED_DK
				case 2:
					if bit_on(HEART[row], col) do c = RED_DK
				case 3:
					if bit_on(DRUM_BONE[row], col) do c = BONE
					else if bit_on(DRUM_MEAT[row], col) do c = MEAT
				case 4:
					if bit_on(DRUM_BONE[row], col) do c = col < 4 ? BONE : GRAY
					else if bit_on(DRUM_MEAT[row], col) do c = col < 4 ? MEAT : GRAY
				case 5:
					if bit_on(DRUM_BONE[row], col) || bit_on(DRUM_MEAT[row], col) do c = GRAY
				case 6:
					if bit_on(BUBBLE[row], col) do c = (row < 3 && col < 4) ? BUBBLE_HI : BUBBLE_C
				}
				i := (row * ICON_ATLAS_W + ox + col) * 4
				px[i] = c.r;px[i + 1] = c.g;px[i + 2] = c.b;px[i + 3] = c.a
			}
		}
	}

	gl.GenTextures(1, &icon_tex)
	gl.BindTexture(gl.TEXTURE_2D, icon_tex)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.RGBA8,
		ICON_ATLAS_W,
		ICON_PX,
		0,
		gl.RGBA,
		gl.UNSIGNED_BYTE,
		raw_data(px),
	)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	gl.GenVertexArrays(1, &icon_vao)
	gl.GenBuffers(1, &icon_vbo)
	gl.BindVertexArray(icon_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, icon_vbo)
	gl.BufferData(gl.ARRAY_BUFFER, 6 * size_of(MMIVert), nil, gl.DYNAMIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, i32(size_of(MMIVert)), offset_of(MMIVert, pos))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, i32(size_of(MMIVert)), offset_of(MMIVert, uv))
	gl.BindVertexArray(0)
}

// Draw a real block texture (its top-face tile from the world atlas) into the
// NDC rect (x0,y0)-(x1,y1) — used for inventory/hotbar slot icons so they
// match what the block looks like in-world instead of a flat colour swatch.
ui_block_icon :: proc(x0, y0, x1, y1: f32, b: BlockId) {
	if icon_prog == 0 do return
	u0, v0, u1, v1 := tile_uv(block_tile(b, .PosY))
	verts := [6]MMIVert {
		{{x0, y1}, {u0, v0}},
		{{x1, y1}, {u1, v0}},
		{{x1, y0}, {u1, v1}},
		{{x0, y1}, {u0, v0}},
		{{x1, y0}, {u1, v1}},
		{{x0, y0}, {u0, v1}},
	}
	gl.UseProgram(icon_prog)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, r_atlas)
	gl.Uniform1i(icon_utex, 0)
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.CULL_FACE)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.BindVertexArray(icon_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, icon_vbo)
	gl.BufferSubData(gl.ARRAY_BUFFER, 0, 6 * size_of(MMIVert), &verts[0])
	gl.DrawArrays(gl.TRIANGLES, 0, 6)
	gl.Disable(gl.BLEND)
	gl.Enable(gl.CULL_FACE)
	gl.Enable(gl.DEPTH_TEST)
}

// Draw icon `idx` into the NDC rect (x0,y0)-(x1,y1).
hud_icon :: proc(x0, y0, x1, y1: f32, idx: int) {
	if icon_prog == 0 do return
	u0 := f32(idx) / f32(ICON_COUNT)
	u1 := f32(idx + 1) / f32(ICON_COUNT)
	verts := [6]MMIVert {
		{{x0, y1}, {u0, 0}},
		{{x1, y1}, {u1, 0}},
		{{x1, y0}, {u1, 1}},
		{{x0, y1}, {u0, 0}},
		{{x1, y0}, {u1, 1}},
		{{x0, y0}, {u0, 1}},
	}
	gl.UseProgram(icon_prog)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, icon_tex)
	gl.Uniform1i(icon_utex, 0)
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.CULL_FACE)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.BindVertexArray(icon_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, icon_vbo)
	gl.BufferSubData(gl.ARRAY_BUFFER, 0, 6 * size_of(MMIVert), &verts[0])
	gl.DrawArrays(gl.TRIANGLES, 0, 6)
	gl.Disable(gl.BLEND)
	gl.Enable(gl.CULL_FACE)
	gl.Enable(gl.DEPTH_TEST)
}
