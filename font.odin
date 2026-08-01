package main

import "core:fmt"
import gl "vendor:OpenGL"

// Self-contained 5x7 bitmap font (uppercase + digits + a little punctuation),
// baked into a single-channel GL texture at startup. text_draw batches a
// string into textured quads in NDC space.

FONT_CHARS :: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ:-./"
GLYPH_W :: 5
GLYPH_H :: 7
CELL_W :: 6 // glyph + 1px advance gap
FONT_N :: len(FONT_CHARS)

// Each row's low 5 bits are the pixels (bit4 = leftmost).
FONT_GLYPHS := [FONT_N][7]u8 {
	{0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110}, // 0
	{0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110}, // 1
	{0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111}, // 2
	{0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110}, // 3
	{0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010}, // 4
	{0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110}, // 5
	{0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110}, // 6
	{0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000}, // 7
	{0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110}, // 8
	{0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100}, // 9
	{0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001}, // A
	{0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110}, // B
	{0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110}, // C
	{0b11100, 0b10010, 0b10001, 0b10001, 0b10001, 0b10010, 0b11100}, // D
	{0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111}, // E
	{0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000}, // F
	{0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111}, // G
	{0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001}, // H
	{0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110}, // I
	{0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100}, // J
	{0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001}, // K
	{0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111}, // L
	{0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001}, // M
	{0b10001, 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001}, // N
	{0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110}, // O
	{0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000}, // P
	{0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101}, // Q
	{0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001}, // R
	{0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110}, // S
	{0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100}, // T
	{0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110}, // U
	{0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100}, // V
	{0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001}, // W
	{0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001}, // X
	{0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100}, // Y
	{0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111}, // Z
	{0b00000, 0b00100, 0b00100, 0b00000, 0b00100, 0b00100, 0b00000}, // :
	{0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000}, // -
	{0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00100, 0b00100}, // .
	{0b00001, 0b00010, 0b00010, 0b00100, 0b01000, 0b01000, 0b10000}, // /
}

font_tex: u32
text_prog: u32
text_ufont: i32
text_ucolor: i32
text_vao: u32
text_vbo: u32
@(private = "file")
font_atlas_w: int

@(private = "file")
TextVert :: struct {
	pos: Vec2,
	uv:  Vec2,
}

@(private = "file")
char_index :: proc(ch: u8) -> int {
	c := ch
	if c >= 'a' && c <= 'z' do c -= 32 // fold to uppercase
	chars := FONT_CHARS
	for i in 0 ..< FONT_N {
		if chars[i] == c do return i
	}
	return -1
}

text_init :: proc() {
	ok: bool
	if text_prog, ok = gl.load_shaders_source(TEXT_VERT, TEXT_FRAG); !ok {
		cmsg, _, lmsg, _ := gl.get_last_error_messages()
		fmt.eprintln("text shader failed:", cmsg, lmsg)
		return
	}
	text_ufont = gl.GetUniformLocation(text_prog, "uFont")
	text_ucolor = gl.GetUniformLocation(text_prog, "uColor")

	font_atlas_w = FONT_N * CELL_W
	pixels := make([]u8, font_atlas_w * GLYPH_H)
	defer delete(pixels)
	for gi in 0 ..< FONT_N {
		g := FONT_GLYPHS[gi]
		for row in 0 ..< GLYPH_H {
			for col in 0 ..< GLYPH_W {
				if (g[row] >> uint(GLYPH_W - 1 - col)) & 1 == 1 {
					pixels[row * font_atlas_w + gi * CELL_W + col] = 255
				}
			}
		}
	}

	gl.GenTextures(1, &font_tex)
	gl.BindTexture(gl.TEXTURE_2D, font_tex)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.R8,
		i32(font_atlas_w),
		i32(GLYPH_H),
		0,
		gl.RED,
		gl.UNSIGNED_BYTE,
		raw_data(pixels),
	)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	gl.GenVertexArrays(1, &text_vao)
	gl.GenBuffers(1, &text_vbo)
	gl.BindVertexArray(text_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, text_vbo)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, i32(size_of(TextVert)), offset_of(TextVert, pos))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, i32(size_of(TextVert)), offset_of(TextVert, uv))
	gl.BindVertexArray(0)
}

// Approximate NDC width of a string at glyph width ch_w.
text_width :: proc(s: string, ch_w: f32) -> f32 {
	return f32(len(s)) * ch_w * f32(CELL_W) / f32(GLYPH_W)
}

// Draw a string horizontally centred on x=0 at NDC height y.
text_center :: proc(s: string, y, ch_w, ch_h: f32, color: Vec4) {
	text_draw(s, -text_width(s, ch_w) * 0.5, y, ch_w, ch_h, color)
}

// Draw `s` with its top-left at NDC (x,y); ch_w/ch_h are per-glyph NDC size.
text_draw :: proc(s: string, x, y, ch_w, ch_h: f32, color: Vec4) {
	if text_prog == 0 do return
	verts := make([dynamic]TextVert, 0, len(s) * 6)
	defer delete(verts)

	advance := ch_w * f32(CELL_W) / f32(GLYPH_W)
	inv_w := 1.0 / f32(font_atlas_w)
	pen := x
	for i in 0 ..< len(s) {
		ch := s[i]
		gi := char_index(ch)
		if gi < 0 {
			pen += advance
			continue
		}
		u0 := f32(gi * CELL_W) * inv_w
		u1 := f32(gi * CELL_W + GLYPH_W) * inv_w
		x0 := pen
		x1 := pen + ch_w
		yt := y
		yb := y - ch_h
		append(
			&verts,
			TextVert{{x0, yt}, {u0, 0}},
			TextVert{{x1, yt}, {u1, 0}},
			TextVert{{x1, yb}, {u1, 1}},
			TextVert{{x0, yt}, {u0, 0}},
			TextVert{{x1, yb}, {u1, 1}},
			TextVert{{x0, yb}, {u0, 1}},
		)
		pen += advance
	}
	if len(verts) == 0 do return

	gl.UseProgram(text_prog)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, font_tex)
	gl.Uniform1i(text_ufont, 0)
	gl.Uniform4f(text_ucolor, color.r, color.g, color.b, color.a)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.CULL_FACE) // text quads are wound CW
	gl.BindVertexArray(text_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, text_vbo)
	gl.BufferData(
		gl.ARRAY_BUFFER,
		len(verts) * size_of(TextVert),
		raw_data(verts),
		gl.DYNAMIC_DRAW,
	)
	gl.DrawArrays(gl.TRIANGLES, 0, i32(len(verts)))
	gl.Enable(gl.CULL_FACE)
	gl.Enable(gl.DEPTH_TEST)
	gl.Disable(gl.BLEND)
}
