package main

import "core:math"
import "core:math/linalg"
import gl "vendor:OpenGL"

STAR_COUNT :: 420
DOME_DIST :: f32(500.0)

sky_prog: u32
sky_mvp: i32
sky_color: i32
sky_psize: i32
star_vao: u32
star_vbo: u32
disk_vao: u32
disk_vbo: u32

@(private = "file")
sky_set_mat4 :: proc(loc: i32, m: Mat4) {
	mm := m
	gl.UniformMatrix4fv(loc, 1, false, transmute([^]f32)(&mm[0, 0]))
}

// Direction of the sun for a time-of-day t (arcs east -> up -> west).
sun_direction :: proc(t: f32) -> Vec3 {
	th := (t - 0.25) * 2 * math.PI
	return linalg.normalize(Vec3{math.cos(th), math.sin(th), 0.30})
}

@(private = "file")
build_disk :: proc(center, dir: Vec3, size: f32) -> [6]Vec3 {
	up0 := math.abs(dir.y) > 0.99 ? Vec3{1, 0, 0} : Vec3{0, 1, 0}
	right := linalg.normalize(linalg.cross(dir, up0)) * size
	up := linalg.normalize(linalg.cross(right, dir)) * size
	a := center - right - up
	b := center + right - up
	c := center + right + up
	d := center - right + up
	return [6]Vec3{a, b, c, a, c, d}
}

sky_init :: proc() {
	ok: bool
	if sky_prog, ok = gl.load_shaders_source(SKY_VERT, SKY_FRAG); !ok {
		return
	}
	sky_mvp = gl.GetUniformLocation(sky_prog, "uMVP")
	sky_color = gl.GetUniformLocation(sky_prog, "uColor")
	sky_psize = gl.GetUniformLocation(sky_prog, "uPointSize")

	// star field on the upper hemisphere (deterministic LCG)
	stars: [STAR_COUNT]Vec3
	seed: u32 = 0x9E3779B1
	rnd :: proc(s: ^u32) -> f32 {
		s^ = s^ * 1664525 + 1013904223
		return f32(s^ >> 8) / f32(1 << 24)
	}
	for i in 0 ..< STAR_COUNT {
		theta := rnd(&seed) * 2 * math.PI
		phi := math.acos(rnd(&seed)) // [0, pi/2] -> upper hemisphere
		dir := Vec3{math.sin(phi) * math.cos(theta), math.cos(phi), math.sin(phi) * math.sin(theta)}
		stars[i] = dir * DOME_DIST
	}
	gl.GenVertexArrays(1, &star_vao)
	gl.GenBuffers(1, &star_vbo)
	gl.BindVertexArray(star_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, star_vbo)
	gl.BufferData(gl.ARRAY_BUFFER, STAR_COUNT * size_of(Vec3), &stars[0], gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, i32(size_of(Vec3)), 0)

	gl.GenVertexArrays(1, &disk_vao)
	gl.GenBuffers(1, &disk_vbo)
	gl.BindVertexArray(disk_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, disk_vbo)
	gl.BufferData(gl.ARRAY_BUFFER, 6 * size_of(Vec3), nil, gl.DYNAMIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, i32(size_of(Vec3)), 0)
	gl.BindVertexArray(0)
}

@(private = "file")
draw_disk :: proc(center, dir: Vec3, size: f32, col: Vec4) {
	verts := build_disk(center, dir, size)
	gl.BindVertexArray(disk_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, disk_vbo)
	gl.BufferSubData(gl.ARRAY_BUFFER, 0, 6 * size_of(Vec3), &verts[0])
	gl.Uniform4f(sky_color, col.r, col.g, col.b, col.a)
	gl.DrawArrays(gl.TRIANGLES, 0, 6)
}

// Draw stars, moon and sun into the background (no depth) so terrain occludes.
sky_render :: proc(cam_pos: Vec3, vp: Mat4, t: f32) {
	sun := sun_direction(t)
	moon := Vec3{-sun.x, -sun.y, sun.z}

	dome := vp * linalg.matrix4_translate_f32(cam_pos)

	gl.UseProgram(sky_prog)
	sky_set_mat4(sky_mvp, dome)
	gl.Disable(gl.DEPTH_TEST)
	gl.DepthMask(false)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

	// stars fade in as the sun drops below the horizon
	star_a := clamp((0.10 - sun.y) * 3.0, 0, 1) * 0.9
	if star_a > 0.01 {
		gl.Enable(gl.PROGRAM_POINT_SIZE)
		gl.Uniform1f(sky_psize, 2.0)
		gl.Uniform4f(sky_color, 1, 1, 1, star_a)
		gl.BindVertexArray(star_vao)
		gl.DrawArrays(gl.POINTS, 0, STAR_COUNT)
	}

	moon_a := clamp((moon.y + 0.15) * 3.0, 0, 1)
	if moon_a > 0.01 {
		draw_disk(moon * DOME_DIST, moon, 16, Vec4{0.90, 0.92, 1.0, moon_a})
	}
	sun_a := clamp((sun.y + 0.15) * 3.0, 0, 1)
	if sun_a > 0.01 {
		draw_disk(sun * DOME_DIST, sun, 26, Vec4{1.0, 0.96, 0.75, sun_a})
	}

	gl.BindVertexArray(0)
	gl.Disable(gl.BLEND)
	gl.DepthMask(true)
	gl.Enable(gl.DEPTH_TEST)
}
