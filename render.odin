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

// Clear-weather horizon haze per biome (rgb + blend strength), so standing in a
// desert, swamp, jungle or snowfield each has its own air. Neutral (a=0) for
// plains/forest/ocean/beach, which keep the plain sky.
biome_atmosphere :: proc(b: Biome) -> Vec4 {
	#partial switch b {
	case .Desert:
		return {0.87, 0.74, 0.50, 0.38}
	case .Badlands:
		return {0.80, 0.57, 0.41, 0.38}
	case .Snow:
		return {0.86, 0.91, 1.00, 0.32}
	case .Taiga:
		return {0.72, 0.82, 0.90, 0.22}
	case .Jungle:
		return {0.58, 0.82, 0.60, 0.30}
	case .Swamp:
		return {0.55, 0.63, 0.51, 0.34}
	case .Savanna:
		return {0.85, 0.78, 0.54, 0.28}
	case .Meadow:
		return {0.80, 0.90, 0.94, 0.16}
	case .Mountains:
		return {0.82, 0.87, 0.94, 0.20}
	}
	return {0, 0, 0, 0}
}

// Cloud deck look for the biome + active weather. Clear skies are white and
// sparse (very sparse over deserts, overcast up north); storms turn the deck
// grey/dark and dense; fog has no deck at all. `day_bright` darkens it at night.
cloud_params :: proc(b: Biome, precip: Precip, raining: bool, day_bright: f32) -> (col: Vec3, alpha, coverage: f32) {
	coverage = 0.34
	#partial switch b {
	case .Desert, .Badlands:
		coverage = 0.12 // clear arid skies
	case .Savanna:
		coverage = 0.20
	case .Jungle, .Swamp:
		coverage = 0.50 // humid, cloudier
	case .Snow, .Taiga:
		coverage = 0.55 // overcast north
	case .Meadow:
		coverage = 0.30
	case .Mountains:
		coverage = 0.28
	}
	col = Vec3{0.99, 1.0, 1.0}
	alpha = 0.6
	if raining {
		#partial switch precip {
		case .Drizzle, .Rain:
			col = {0.60, 0.63, 0.68};coverage = 0.80;alpha = 0.85
		case .Thunder:
			col = {0.30, 0.32, 0.38};coverage = 0.92;alpha = 0.92 // dark thunderheads
		case .Snow, .Hail:
			col = {0.82, 0.84, 0.90};coverage = 0.88;alpha = 0.85
		case .Sandstorm:
			col = {0.72, 0.62, 0.42};coverage = 0.35;alpha = 0.5
		case .Fog:
			coverage = 0 // fog is a ground bank, no cloud deck
		}
	}
	col *= clamp(day_bright, 0.22, 1.0) // clouds darken with the night
	return
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
	} else if w.raining && w.active_precip != .None {
		// Tint + thicken the fog to match the kind of storm. Both ends must
		// shrink together — scaling only fog_end would leave fog_start past the
		// new fog_end and invert the shader's (vDist-start)/(end-start) ratio.
		#partial switch w.active_precip {
		case .Sandstorm:
			fog_col = fog_col * 0.3 + Vec3{0.80, 0.66, 0.40} * 0.7 // tan sand haze
			fog_start *= 0.35
			fog_end *= 0.35 // can barely see through it
			ambient *= 0.85
		case .Snow, .Hail:
			fog_col = fog_col * 0.5 + Vec3{0.82, 0.85, 0.9} * 0.5 // bright whiteout
			fog_start *= 0.6
			fog_end *= 0.6
			ambient *= 0.92
		case .Fog:
			fog_col = fog_col * 0.35 + Vec3{0.74, 0.80, 0.74} * 0.65 // pale grey-green murk
			fog_start *= 0.22
			fog_end *= 0.28 // a thick bank: can only see a short way
			ambient *= 0.88
		case:
			// rain family (drizzle/rain/thunder): grey overcast haze
			fog_col = fog_col * 0.55 + Vec3{0.5, 0.54, 0.58} * 0.45
			fog_start *= 0.55
			fog_end *= 0.55
			ambient *= 0.8
		}
		// a lightning flash briefly floods the scene with bright light
		if w.flash > 0 {
			fog_col = fog_col + Vec3{0.5, 0.5, 0.55} * w.flash
			ambient = min(1, ambient + w.flash * 0.6)
		}
	} else {
		// clear weather: tint the horizon haze by the biome you're standing in
		// (warm desert, cool snow, humid jungle, murky swamp). Uses the SMOOTHED
		// tint (eased in the update loop) so a border fades rather than snaps.
		at := w.sky_tint
		if at.a > 0.001 {
			fog_col = fog_col * (1 - at.a) + Vec3{at.r, at.g, at.b} * at.a
		}
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

	// cloud deck: biome/weather-varied, drifting with the wind, occluded by
	// terrain. Uses the SMOOTHED colour/coverage/alpha (eased in the update loop)
	// so the deck fades between biomes rather than popping.
	if !underwater && !nether {
		dx := w.cloud_time * 1.4 + w.wind_x * 2.5
		dz := w.cloud_time * 0.5 + w.wind_z * 2.5
		clouds_render(eye, vp, w.cloud_col, w.cloud_alpha, w.cloud_cover, dx, dz)
	}

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

	// Red "took damage" flash: strongest at the instant of the hit, fading out
	// over the invulnerability window — the same feedback MC gives on the screen.
	if p.hurt_timer > 0 {
		a := clamp(p.hurt_timer / 0.5, 0, 1) * 0.32
		hud_quad(-1, -1, 1, 1, Vec4{0.62, 0.02, 0.02, a})
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
