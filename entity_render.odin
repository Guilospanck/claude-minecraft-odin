package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import gl "vendor:OpenGL"

// One box of a mob model: centre offset from the feet (local, pre-yaw), full
// size, colour, and a leg-swing sign (0 = static part).
MobPart :: struct {
	offset: Vec3,
	size:   Vec3,
	color:  Vec3,
	swing:  f32,
}

@(private = "file")
EntVert :: struct {
	pos:   Vec3,
	shade: f32,
}

e_prog: u32
e_mvp: i32
e_color: i32
e_ambient: i32
e_vao: u32
e_vbo: u32

@(private = "file")
PINK :: Vec3{0.93, 0.62, 0.64}
@(private = "file")
WHITE :: Vec3{0.95, 0.95, 0.92}
@(private = "file")
BROWN :: Vec3{0.46, 0.31, 0.18}
@(private = "file")
DARK :: Vec3{0.22, 0.20, 0.20}
@(private = "file")
ORANGE :: Vec3{0.95, 0.66, 0.16}
@(private = "file")
CREAM :: Vec3{0.86, 0.78, 0.62}
@(private = "file")
ZGREEN :: Vec3{0.30, 0.55, 0.32}
@(private = "file")
ZSKIN :: Vec3{0.26, 0.46, 0.30}
@(private = "file")
PANTS :: Vec3{0.26, 0.30, 0.52}
@(private = "file")
RBROWN :: Vec3{0.60, 0.45, 0.30}
@(private = "file")
BONE :: Vec3{0.90, 0.90, 0.84}

@(private = "file")
pig_parts := [7]MobPart {
	{{0, 0.50, 0}, {0.6, 0.5, 0.9}, PINK, 0},
	{{0, 0.55, -0.55}, {0.5, 0.5, 0.45}, PINK, 0},
	{{0, 0.48, -0.8}, {0.28, 0.2, 0.12}, {0.8, 0.5, 0.52}, 0},
	{{-0.2, 0.18, -0.28}, {0.2, 0.36, 0.2}, PINK, 1},
	{{0.2, 0.18, -0.28}, {0.2, 0.36, 0.2}, PINK, 1},
	{{-0.2, 0.18, 0.28}, {0.2, 0.36, 0.2}, PINK, -1},
	{{0.2, 0.18, 0.28}, {0.2, 0.36, 0.2}, PINK, -1},
}

@(private = "file")
sheep_parts := [6]MobPart {
	{{0, 0.78, 0}, {0.7, 0.66, 0.95}, WHITE, 0},
	{{0, 0.88, -0.62}, {0.45, 0.5, 0.42}, CREAM, 0},
	{{-0.22, 0.25, -0.3}, {0.18, 0.5, 0.18}, DARK, 1},
	{{0.22, 0.25, -0.3}, {0.18, 0.5, 0.18}, DARK, 1},
	{{-0.22, 0.25, 0.3}, {0.18, 0.5, 0.18}, DARK, -1},
	{{0.22, 0.25, 0.3}, {0.18, 0.5, 0.18}, DARK, -1},
}

@(private = "file")
cow_parts := [7]MobPart {
	{{0, 0.88, 0}, {0.76, 0.66, 1.05}, BROWN, 0},
	{{0, 0.98, -0.72}, {0.5, 0.5, 0.45}, BROWN, 0},
	{{0, 0.9, -0.98}, {0.32, 0.26, 0.12}, {0.9, 0.85, 0.8}, 0},
	{{-0.26, 0.3, -0.34}, {0.2, 0.6, 0.2}, {0.3, 0.22, 0.15}, 1},
	{{0.26, 0.3, -0.34}, {0.2, 0.6, 0.2}, {0.3, 0.22, 0.15}, 1},
	{{-0.26, 0.3, 0.34}, {0.2, 0.6, 0.2}, {0.3, 0.22, 0.15}, -1},
	{{0.26, 0.3, 0.34}, {0.2, 0.6, 0.2}, {0.3, 0.22, 0.15}, -1},
}

@(private = "file")
chicken_parts := [5]MobPart {
	{{0, 0.34, 0}, {0.36, 0.4, 0.5}, WHITE, 0},
	{{0, 0.56, -0.22}, {0.3, 0.32, 0.3}, WHITE, 0},
	{{0, 0.53, -0.42}, {0.14, 0.1, 0.16}, ORANGE, 0},
	{{-0.1, 0.12, 0.05}, {0.09, 0.24, 0.09}, ORANGE, 1},
	{{0.1, 0.12, 0.05}, {0.09, 0.24, 0.09}, ORANGE, -1},
}

@(private = "file")
zombie_parts := [6]MobPart {
	{{-0.13, 0.45, 0}, {0.22, 0.9, 0.22}, PANTS, 1}, // left leg
	{{0.13, 0.45, 0}, {0.22, 0.9, 0.22}, PANTS, -1}, // right leg
	{{0, 1.2, 0}, {0.5, 0.62, 0.28}, ZGREEN, 0}, // body
	{{0, 1.68, 0}, {0.42, 0.42, 0.42}, ZSKIN, 0}, // head
	{{-0.36, 1.2, 0.28}, {0.16, 0.6, 0.16}, ZGREEN, -1}, // left arm
	{{0.36, 1.2, -0.28}, {0.16, 0.6, 0.16}, ZGREEN, 1}, // right arm
}

@(private = "file")
rabbit_parts := [6]MobPart {
	{{0, 0.20, 0.05}, {0.24, 0.24, 0.36}, RBROWN, 0}, // body
	{{0, 0.30, -0.18}, {0.22, 0.22, 0.20}, RBROWN, 0}, // head
	{{-0.06, 0.46, -0.16}, {0.06, 0.20, 0.05}, RBROWN, 0}, // left ear
	{{0.06, 0.46, -0.16}, {0.06, 0.20, 0.05}, RBROWN, 0}, // right ear
	{{-0.08, 0.09, 0}, {0.10, 0.18, 0.14}, RBROWN, 1}, // left hind leg
	{{0.08, 0.09, 0}, {0.10, 0.18, 0.14}, RBROWN, -1}, // right hind leg
}

@(private = "file")
skeleton_parts := [6]MobPart {
	{{-0.11, 0.45, 0}, {0.14, 0.9, 0.14}, BONE, 1}, // left leg
	{{0.11, 0.45, 0}, {0.14, 0.9, 0.14}, BONE, -1}, // right leg
	{{0, 1.2, 0}, {0.36, 0.6, 0.2}, BONE, 0}, // body
	{{0, 1.66, 0}, {0.4, 0.4, 0.4}, BONE, 0}, // head
	{{-0.28, 1.2, 0.1}, {0.12, 0.6, 0.12}, BONE, -1}, // left arm
	{{0.28, 1.2, -0.1}, {0.12, 0.6, 0.12}, BONE, 1}, // right arm
}

@(private = "file")
PSKIN :: Vec3{0.86, 0.70, 0.56}
@(private = "file")
PSHIRT :: Vec3{0.20, 0.55, 0.75}

@(private = "file")
player_parts := [6]MobPart {
	{{-0.11, 0.45, 0}, {0.14, 0.9, 0.14}, PANTS, 0}, // left leg
	{{0.11, 0.45, 0}, {0.14, 0.9, 0.14}, PANTS, 0}, // right leg
	{{0, 1.2, 0}, {0.4, 0.62, 0.22}, PSHIRT, 0}, // body
	{{0, 1.66, 0}, {0.42, 0.42, 0.42}, PSKIN, 0}, // head
	{{-0.31, 1.2, 0}, {0.14, 0.6, 0.14}, PSKIN, 0}, // left arm
	{{0.31, 1.2, 0}, {0.14, 0.6, 0.14}, PSKIN, 0}, // right arm
}

@(private = "file")
remotes_buf: [dynamic]RemotePlayer

// Draw other networked players as blue humanoids.
remotes_render_frame :: proc(vp: Mat4, ambient: f32) {
	if !net_active() do return
	net_remotes_snapshot(&remotes_buf)
	if len(remotes_buf) == 0 do return
	gl.UseProgram(e_prog)
	gl.Uniform1f(e_ambient, ambient)
	gl.BindVertexArray(e_vao)
	for rp in remotes_buf {
		base :=
			linalg.matrix4_translate_f32(rp.pos) *
			linalg.matrix4_rotate_f32(-rp.yaw, Vec3{0, 1, 0})
		for pt in player_parts {
			model :=
				base *
				linalg.matrix4_translate_f32(pt.offset) *
				linalg.matrix4_scale_f32(pt.size)
			ent_set_mat4(e_mvp, vp * model)
			gl.Uniform3f(e_color, pt.color.r, pt.color.g, pt.color.b)
			gl.DrawArrays(gl.TRIANGLES, 0, 36)
		}
	}
	gl.BindVertexArray(0)
}

mob_parts :: proc(k: MobKind) -> []MobPart {
	switch k {
	case .Pig:
		return pig_parts[:]
	case .Sheep:
		return sheep_parts[:]
	case .Cow:
		return cow_parts[:]
	case .Chicken:
		return chicken_parts[:]
	case .Rabbit:
		return rabbit_parts[:]
	case .Zombie:
		return zombie_parts[:]
	case .Skeleton:
		return skeleton_parts[:]
	}
	return pig_parts[:]
}

@(private = "file")
ent_set_mat4 :: proc(loc: i32, m: Mat4) {
	mm := m
	gl.UniformMatrix4fv(loc, 1, false, transmute([^]f32)(&mm[0, 0]))
}

entity_render_init :: proc() {
	ok: bool
	if e_prog, ok = gl.load_shaders_source(ENTITY_VERT, ENTITY_FRAG); !ok {
		fmt.panicf("entity shader failed to compile/link")
	}
	e_mvp = gl.GetUniformLocation(e_prog, "uMVP")
	e_color = gl.GetUniformLocation(e_prog, "uColor")
	e_ambient = gl.GetUniformLocation(e_prog, "uAmbient")

	// Unit cube centred at the origin (-0.5..0.5), reusing the world face
	// tables for correct CCW winding and per-face shading.
	verts: [36]EntVert
	n := 0
	for face in Face {
		fd := FACES[face]
		sh := FACE_SHADE[face]
		quad: [4]EntVert
		for i in 0 ..< 4 {
			off := fd.pos[i]
			quad[i] = EntVert{Vec3{f32(off.x) - 0.5, f32(off.y) - 0.5, f32(off.z) - 0.5}, sh}
		}
		idx := [6]int{0, 1, 2, 0, 2, 3}
		for j in idx {
			verts[n] = quad[j]
			n += 1
		}
	}

	gl.GenVertexArrays(1, &e_vao)
	gl.GenBuffers(1, &e_vbo)
	gl.BindVertexArray(e_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, e_vbo)
	gl.BufferData(gl.ARRAY_BUFFER, 36 * size_of(EntVert), &verts[0], gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, i32(size_of(EntVert)), offset_of(EntVert, pos))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 1, gl.FLOAT, false, i32(size_of(EntVert)), offset_of(EntVert, shade))
	gl.BindVertexArray(0)
}

entity_render_frame :: proc(mobs: ^[dynamic]Mob, vp: Mat4, ambient: f32) {
	if len(mobs^) == 0 do return
	gl.UseProgram(e_prog)
	gl.Uniform1f(e_ambient, ambient)
	gl.BindVertexArray(e_vao)
	for i in 0 ..< len(mobs^) {
		m := &mobs^[i]
		// -yaw so the model's local -Z (its face) points along the heading.
		base := linalg.matrix4_translate_f32(m.pos) * linalg.matrix4_rotate_f32(-m.yaw, Vec3{0, 1, 0})
		sw := math.sin(m.walk_phase)
		for pt in mob_parts(m.kind) {
			off := pt.offset
			off.z += pt.swing * sw * 0.16 // leg shuffle
			model :=
				base *
				linalg.matrix4_translate_f32(off) *
				linalg.matrix4_scale_f32(pt.size)
			ent_set_mat4(e_mvp, vp * model)
			gl.Uniform3f(e_color, pt.color.r, pt.color.g, pt.color.b)
			gl.DrawArrays(gl.TRIANGLES, 0, 36)
		}
	}
	gl.BindVertexArray(0)
}

// Rotation whose local +Z points along `fwd`.
@(private = "file")
mat_from_forward :: proc(fwd: Vec3) -> Mat4 {
	f := linalg.normalize(fwd)
	up0 := math.abs(f.y) > 0.99 ? Vec3{1, 0, 0} : Vec3{0, 1, 0}
	r := linalg.normalize(linalg.cross(up0, f))
	u := linalg.cross(f, r)
	m := linalg.MATRIX4F32_IDENTITY
	m[0, 0] = r.x;m[1, 0] = r.y;m[2, 0] = r.z
	m[0, 1] = u.x;m[1, 1] = u.y;m[2, 1] = u.z
	m[0, 2] = f.x;m[1, 2] = f.y;m[2, 2] = f.z
	return m
}

arrows_render_frame :: proc(arrows: ^[dynamic]Arrow, vp: Mat4, ambient: f32) {
	if len(arrows^) == 0 do return
	gl.UseProgram(e_prog)
	gl.Uniform1f(e_ambient, ambient)
	gl.Uniform3f(e_color, 0.82, 0.78, 0.70)
	gl.BindVertexArray(e_vao)
	for i in 0 ..< len(arrows^) {
		a := &arrows^[i]
		fwd := a.vel
		if linalg.length(fwd) < 0.001 do fwd = Vec3{0, 0, 1}
		model :=
			linalg.matrix4_translate_f32(a.pos) *
			mat_from_forward(fwd) *
			linalg.matrix4_scale_f32(Vec3{0.06, 0.06, 0.45})
		ent_set_mat4(e_mvp, vp * model)
		gl.DrawArrays(gl.TRIANGLES, 0, 36)
	}
	gl.BindVertexArray(0)
}

// Dropped items as small bobbing, spinning cubes coloured by their block.
items_render_frame :: proc(items: ^[dynamic]Item, vp: Mat4, ambient: f32) {
	if len(items^) == 0 do return
	gl.UseProgram(e_prog)
	gl.Uniform1f(e_ambient, ambient)
	gl.BindVertexArray(e_vao)
	for i in 0 ..< len(items^) {
		it := &items^[i]
		bob := 0.25 + math.sin(it.age * 3) * 0.07
		model :=
			linalg.matrix4_translate_f32(it.pos + Vec3{0, bob, 0}) *
			linalg.matrix4_rotate_f32(it.spin, Vec3{0, 1, 0}) *
			linalg.matrix4_scale_f32(Vec3{0.3, 0.3, 0.3})
		ent_set_mat4(e_mvp, vp * model)
		col := it.food ? Vec3{0.72, 0.28, 0.22} : block_color(it.block)
		gl.Uniform3f(e_color, col.r, col.g, col.b)
		gl.DrawArrays(gl.TRIANGLES, 0, 36)
	}
	gl.BindVertexArray(0)
}
