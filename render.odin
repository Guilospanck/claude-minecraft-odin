package main

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import gl "vendor:OpenGL"
import stbiw "vendor:stb/image"

// programs / texture
r_chunk_prog: u32
r_line_prog: u32
r_atlas: u32

// chunk shader uniforms
u_mvp: i32
u_campos: i32
u_tex: i32
u_alpha: i32
u_fogcol: i32
u_fogstart: i32
u_fogend: i32
u_ambient: i32

// line shader uniforms
lu_mvp: i32
lu_color: i32

// block-outline buffers
r_outline_vao: u32
r_outline_vbo: u32

@(private = "file")
set_mat4 :: proc(loc: i32, m: Mat4) {
	mm := m
	gl.UniformMatrix4fv(loc, 1, false, transmute([^]f32)(&mm[0, 0]))
}

render_init :: proc(atlas: u32) {
	r_atlas = atlas

	ok: bool
	if r_chunk_prog, ok = gl.load_shaders_source(CHUNK_VERT, CHUNK_FRAG); !ok {
		fmt.panicf("chunk shader failed to compile/link")
	}
	if r_line_prog, ok = gl.load_shaders_source(LINE_VERT, LINE_FRAG); !ok {
		fmt.panicf("line shader failed to compile/link")
	}

	u_mvp = gl.GetUniformLocation(r_chunk_prog, "uMVP")
	u_campos = gl.GetUniformLocation(r_chunk_prog, "uCamPos")
	u_tex = gl.GetUniformLocation(r_chunk_prog, "uTex")
	u_alpha = gl.GetUniformLocation(r_chunk_prog, "uAlpha")
	u_fogcol = gl.GetUniformLocation(r_chunk_prog, "uFogColor")
	u_fogstart = gl.GetUniformLocation(r_chunk_prog, "uFogStart")
	u_fogend = gl.GetUniformLocation(r_chunk_prog, "uFogEnd")
	u_ambient = gl.GetUniformLocation(r_chunk_prog, "uAmbient")
	lu_mvp = gl.GetUniformLocation(r_line_prog, "uMVP")
	lu_color = gl.GetUniformLocation(r_line_prog, "uColor")

	gl.Enable(gl.DEPTH_TEST)
	gl.Enable(gl.CULL_FACE)
	gl.CullFace(gl.BACK)
	gl.FrontFace(gl.CCW)
	gl.ClearColor(SKY_COLOR.r, SKY_COLOR.g, SKY_COLOR.b, 1.0)

	entity_render_init()
	sky_init()
	text_init()
	minimap_init()
	icons_init()

	gl.GenVertexArrays(1, &r_outline_vao)
	gl.GenBuffers(1, &r_outline_vbo)
	gl.BindVertexArray(r_outline_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, r_outline_vbo)
	gl.BufferData(gl.ARRAY_BUFFER, 24 * size_of(Vec3), nil, gl.DYNAMIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, i32(size_of(Vec3)), 0)
	gl.BindVertexArray(0)
}

@(private = "file")
setup_chunk_vao :: proc(vao, vbo: u32) {
	gl.BindVertexArray(vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, i32(size_of(Vertex)), offset_of(Vertex, pos))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, i32(size_of(Vertex)), offset_of(Vertex, uv))
	gl.EnableVertexAttribArray(2)
	gl.VertexAttribPointer(2, 1, gl.FLOAT, false, i32(size_of(Vertex)), offset_of(Vertex, shade))
	gl.EnableVertexAttribArray(3)
	gl.VertexAttribPointer(
		3,
		1,
		gl.FLOAT,
		false,
		i32(size_of(Vertex)),
		offset_of(Vertex, blocklight),
	)
	gl.EnableVertexAttribArray(4)
	gl.VertexAttribPointer(4, 3, gl.FLOAT, false, i32(size_of(Vertex)), offset_of(Vertex, tint))
	gl.BindVertexArray(0)
}

@(private = "file")
upload_buffer :: proc(vbo: u32, verts: [dynamic]Vertex) {
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
	if len(verts) > 0 {
		gl.BufferData(
			gl.ARRAY_BUFFER,
			len(verts) * size_of(Vertex),
			raw_data(verts),
			gl.DYNAMIC_DRAW,
		)
	} else {
		gl.BufferData(gl.ARRAY_BUFFER, 0, nil, gl.DYNAMIC_DRAW)
	}
}

chunk_upload :: proc(c: ^Chunk, md: ^MeshData) {
	if !c.gl_init {
		gl.GenVertexArrays(1, &c.opaque_vao)
		gl.GenBuffers(1, &c.opaque_vbo)
		gl.GenVertexArrays(1, &c.water_vao)
		gl.GenBuffers(1, &c.water_vbo)
		setup_chunk_vao(c.opaque_vao, c.opaque_vbo)
		setup_chunk_vao(c.water_vao, c.water_vbo)
		c.gl_init = true
	}
	c.opaque_count = i32(len(md.opaque))
	upload_buffer(c.opaque_vbo, md.opaque)
	c.water_count = i32(len(md.water))
	upload_buffer(c.water_vbo, md.water)
	gl.BindBuffer(gl.ARRAY_BUFFER, 0)
}

chunk_gl_free :: proc(c: ^Chunk) {
	if !c.gl_init do return
	gl.DeleteBuffers(1, &c.opaque_vbo)
	gl.DeleteVertexArrays(1, &c.opaque_vao)
	gl.DeleteBuffers(1, &c.water_vbo)
	gl.DeleteVertexArrays(1, &c.water_vao)
	c.gl_init = false
}

// Rebuild + upload up to MAX_MESH_PER_FRAME dirty chunks, nearest first.
render_remesh :: proc(w: ^World, cam: Vec3) {
	g_center = world_chunk_at(w, int(math.floor(cam.x)), int(math.floor(cam.z)))
	dirty := make([dynamic]Ivec2, 0, 32)
	defer delete(dirty)
	for coord, c in w.chunks {
		if c.generated && c.dirty do append(&dirty, coord)
	}
	slice.sort_by(dirty[:], proc(a, b: Ivec2) -> bool {
		da := (a.x - g_center.x) * (a.x - g_center.x) + (a.y - g_center.y) * (a.y - g_center.y)
		db := (b.x - g_center.x) * (b.x - g_center.x) + (b.y - g_center.y) * (b.y - g_center.y)
		return da < db
	})
	n := 0
	for coord in dirty {
		if n >= MAX_MESH_PER_FRAME do break
		c := w.chunks[coord]
		md := mesh_chunk(w, c)
		chunk_upload(c, &md)
		mesh_free(&md)
		c.dirty = false
		n += 1
	}
}

@(private = "file")
draw_outline :: proc(w: ^World, p: ^Player, vp: Mat4) {
	eye := p.pos + Vec3{0, EYE_HEIGHT, 0}
	hit := raycast(w, eye, camera_front(p.yaw, p.pitch), REACH)
	if !hit.hit do return

	e: f32 = 0.002
	lo := Vec3{f32(hit.bx) - e, f32(hit.by) - e, f32(hit.bz) - e}
	hi := Vec3{f32(hit.bx + 1) + e, f32(hit.by + 1) + e, f32(hit.bz + 1) + e}
	corners := [8]Vec3 {
		{lo.x, lo.y, lo.z},
		{hi.x, lo.y, lo.z},
		{hi.x, lo.y, hi.z},
		{lo.x, lo.y, hi.z},
		{lo.x, hi.y, lo.z},
		{hi.x, hi.y, lo.z},
		{hi.x, hi.y, hi.z},
		{lo.x, hi.y, hi.z},
	}
	edges := [24]int{0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7}
	verts: [24]Vec3
	for i in 0 ..< 24 {
		verts[i] = corners[edges[i]]
	}

	gl.BindBuffer(gl.ARRAY_BUFFER, r_outline_vbo)
	gl.BufferSubData(gl.ARRAY_BUFFER, 0, 24 * size_of(Vec3), &verts[0])
	gl.UseProgram(r_line_prog)
	set_mat4(lu_mvp, vp)
	gl.Uniform4f(lu_color, 0.05, 0.05, 0.05, 1.0)
	gl.BindVertexArray(r_outline_vao)
	gl.DrawArrays(gl.LINES, 0, 24)
}

render_frame :: proc(w: ^World, p: ^Player, fbw, fbh: i32) {
	sky, ambient, _ := daynight(w.time_of_day)

	// When the camera is submerged, murk the fog and dim the light.
	eye := p.pos + Vec3{0, EYE_HEIGHT, 0}
	underwater :=
		world_block(w, int(math.floor(eye.x)), int(math.floor(eye.y)), int(math.floor(eye.z))) ==
		.Water
	fog_col := sky
	fog_start := f32(CHUNK_W * (g_settings.render_radius - 2))
	fog_end := f32(CHUNK_W * g_settings.render_radius)
	nether := w.dimension == .Nether
	if nether {
		fog_col = Vec3{0.24, 0.05, 0.05} // murky red haze
		fog_start = 3.0
		fog_end = f32(CHUNK_W * g_settings.render_radius) * 0.65
		ambient = 0.72 // dim ambient glow, no sun
	} else if underwater {
		fog_col = Vec3{0.10, 0.24, 0.42}
		fog_start = 1.5
		fog_end = 22.0
		ambient *= 0.72
	} else if w.raining {
		fog_col = fog_col * 0.55 + Vec3{0.5, 0.54, 0.58} * 0.45 // grey overcast haze
		// Both ends must shrink together — scaling only fog_end left
		// fog_start (still the full render-distance value) past the new
		// fog_end, inverting the fog shader's (vDist-start)/(end-start)
		// ratio so nearly everything on screen clamped to full fog colour.
		fog_start *= 0.55
		fog_end *= 0.55 // shorter visibility in the rain
		ambient *= 0.8
	}

	gl.ClearColor(fog_col.r, fog_col.g, fog_col.b, 1.0)
	gl.Viewport(0, 0, fbw, fbh)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

	aspect := f32(fbw) / f32(max(fbh, 1))
	// Eating nods the camera down and back up — a bump peaking mid-animation.
	eat_bob: f32 = 0
	if p.eat_timer > 0 {
		t := 1.0 - p.eat_timer / EAT_ANIM_DURATION
		eat_bob = math.sin(clamp(t, 0, 1) * math.PI)
	}
	view := view_matrix(eye - Vec3{0, 0.06 * eat_bob, 0}, p.yaw, p.pitch - 0.05 * eat_bob)
	proj := proj_matrix(aspect)
	vp := proj * view

	if !underwater && !nether do sky_render(eye, vp, w.time_of_day)

	gl.UseProgram(r_chunk_prog)
	set_mat4(u_mvp, vp)
	gl.Uniform3f(u_campos, eye.x, eye.y, eye.z)
	gl.Uniform1i(u_tex, 0)
	gl.Uniform3f(u_fogcol, fog_col.r, fog_col.g, fog_col.b)
	gl.Uniform1f(u_fogstart, fog_start)
	gl.Uniform1f(u_fogend, fog_end)
	gl.Uniform1f(u_ambient, ambient)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, r_atlas)

	// opaque pass
	gl.Disable(gl.BLEND)
	gl.DepthMask(true)
	gl.Uniform1f(u_alpha, 1.0)
	for _, c in w.chunks {
		if c.gl_init && c.opaque_count > 0 {
			gl.BindVertexArray(c.opaque_vao)
			gl.DrawArrays(gl.TRIANGLES, 0, c.opaque_count)
		}
	}

	// translucent water pass
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.DepthMask(false)
	gl.Uniform1f(u_alpha, 0.65)
	for _, c in w.chunks {
		if c.gl_init && c.water_count > 0 {
			gl.BindVertexArray(c.water_vao)
			gl.DrawArrays(gl.TRIANGLES, 0, c.water_count)
		}
	}
	gl.DepthMask(true)
	gl.Disable(gl.BLEND)

	entity_render_frame(&w.mobs, vp, ambient)
	villagers_render_frame(&w.villagers, vp, ambient)
	items_render_frame(&w.items, vp, ambient)
	arrows_render_frame(&w.arrows, vp, ambient)
	particles_render_frame(&w.particles, vp, ambient)
	remotes_render_frame(vp, ambient)

	draw_outline(w, p, vp)

	held_item_render(p, proj, ambient) // first-person view model, over the world

	if underwater {
		hud_quad(-1, -1, 1, 1, Vec4{0.12, 0.30, 0.55, 0.38}) // submerged tint
	}

	hud_draw(fbw, fbh)
	if p.mine_frac > 0 { 	// break-progress bar under the crosshair
		hud_quad(-0.11, -0.125, 0.11, -0.09, Vec4{0.1, 0.1, 0.1, 0.7})
		hud_quad(-0.10, -0.118, -0.10 + 0.20 * p.mine_frac, -0.097, Vec4{0.9, 0.9, 0.95, 0.95})
	}
	hud_draw_health(p.health, int(fbw), int(fbh))
	hud_draw_hunger(int(p.hunger), int(fbw), int(fbh))
	hud_draw_oxygen(p.oxygen, int(fbw), int(fbh))
	toast_draw(int(fbw), int(fbh))
	ui_draw_hotbar(p, int(fbw), int(fbh))
	minimap_draw(w, p, int(fbw), int(fbh))
	gl.BindVertexArray(0)
}

// Read the back buffer and write it to a PNG (rows flipped to top-down).
render_screenshot :: proc(path: string, w, h: i32) {
	n := int(w) * int(h) * 4
	buf := make([]u8, n)
	defer delete(buf)
	gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
	gl.ReadPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(buf))

	row := int(w) * 4
	flip := make([]u8, n)
	defer delete(flip)
	for y in 0 ..< int(h) {
		src := y * row
		dst := (int(h) - 1 - y) * row
		copy(flip[dst:dst + row], buf[src:src + row])
	}

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	_ = stbiw.write_png(cpath, w, h, 4, raw_data(flip), i32(row))
	fmt.println("screenshot ->", path)
}
