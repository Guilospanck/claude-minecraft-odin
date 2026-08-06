package main

import ad "assetdef"

Vertex :: struct {
	pos:        Vec3,
	uv:         Vec2,
	shade:      f32, // face directional shade * AO (dimmed by day-night ambient)
	blocklight: f32, // local block light 0..1 (immune to day-night)
	tint:       Vec3, // per-block colour tint (biome grass gradient; white otherwise)
}

// Biome grass tint: warmer/yellower when hot-dry, cooler/blue-green when cold-wet.
// Uses the shared world_climate (same temp/humidity the biome was chosen from)
// so the tint never drifts from the biome the ground was actually generated as.
@(private = "file")
grass_tint :: proc(seed: u64, wx, wz: int) -> Vec3 {
	temp, moist := world_climate(seed, wx, wz)
	return Vec3 {
		clamp(1.0 + 0.20 * temp - 0.05 * moist, 0.65, 1.3),
		clamp(1.0 - 0.03 * abs(temp) + 0.06 * moist, 0.70, 1.15),
		clamp(1.0 - 0.18 * temp + 0.12 * moist, 0.50, 1.25),
	}
}

MeshData :: struct {
	opaque: [dynamic]Vertex,
	water:  [dynamic]Vertex,
}

FaceDef :: struct {
	n:     Ivec3, // outward normal
	uaxis: int, // in-plane axis mapped to U
	vaxis: int, // in-plane axis mapped to V
	pos:   [4]Ivec3, // corner offsets (0/1), CCW seen from outside
	uv:    [4][2]int, // per-corner (u,v) selector: 0 -> min, 1 -> max
}

// Corner winding verified CCW-outward; triangles are (0,1,2)+(0,2,3).
FACES := [Face]FaceDef {
	.PosX = {
		{1, 0, 0},
		2,
		1,
		{{1, 0, 1}, {1, 0, 0}, {1, 1, 0}, {1, 1, 1}},
		{{0, 1}, {1, 1}, {1, 0}, {0, 0}},
	},
	.NegX = {
		{-1, 0, 0},
		2,
		1,
		{{0, 0, 0}, {0, 0, 1}, {0, 1, 1}, {0, 1, 0}},
		{{0, 1}, {1, 1}, {1, 0}, {0, 0}},
	},
	.PosY = {
		{0, 1, 0},
		0,
		2,
		{{0, 1, 1}, {1, 1, 1}, {1, 1, 0}, {0, 1, 0}},
		{{0, 0}, {1, 0}, {1, 1}, {0, 1}},
	},
	.NegY = {
		{0, -1, 0},
		0,
		2,
		{{0, 0, 0}, {1, 0, 0}, {1, 0, 1}, {0, 0, 1}},
		{{0, 0}, {1, 0}, {1, 1}, {0, 1}},
	},
	.PosZ = {
		{0, 0, 1},
		0,
		1,
		{{0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}},
		{{0, 1}, {1, 1}, {1, 0}, {0, 0}},
	},
	.NegZ = {
		{0, 0, -1},
		0,
		1,
		{{1, 0, 0}, {0, 0, 0}, {0, 1, 0}, {1, 1, 0}},
		{{0, 1}, {1, 1}, {1, 0}, {0, 0}},
	},
}

// Per-face directional shade (fake sky lighting).
FACE_SHADE := [Face]f32 {
	.PosY = 1.0,
	.NegY = 0.5,
	.PosX = 0.6,
	.NegX = 0.6,
	.PosZ = 0.8,
	.NegZ = 0.8,
}

// Ambient-occlusion level (0 = most occluded .. 3 = open) -> brightness.
AO_LIGHT := [4]f32{0.35, 0.55, 0.78, 1.0}

@(private = "file")
axis_ivec :: proc(axis, sign: int) -> Ivec3 {
	v: Ivec3
	v[axis] = sign
	return v
}

@(private = "file")
is_opaque_at :: proc(w: ^World, x, y, z: int) -> bool {
	return block_is_opaque(world_block(w, x, y, z))
}

// Classic 3-neighbour AO. side1/side2 = edge neighbours, corner = diagonal.
@(private = "file")
vertex_ao :: proc(s1, s2, cor: bool) -> int {
	if s1 && s2 do return 0
	return 3 - (b2i(s1) + b2i(s2) + b2i(cor))
}

@(private = "file")
emit_face :: proc(w: ^World, arr: ^[dynamic]Vertex, b: BlockId, face: Face, wx, wy, wz: int, bl: f32) {
	fd := FACES[face]
	tile := block_tile(b, face)
	u0, v0, u1, v1 := tile_uv(tile)
	shade := FACE_SHADE[face]
	n := fd.n
	tint := (b == .Grass || b == .Leaves) ? grass_tint(w.seed, wx, wz) : Vec3{1, 1, 1}

	verts: [4]Vertex
	for i in 0 ..< 4 {
		off := fd.pos[i]
		verts[i].pos = Vec3{f32(wx + off.x), f32(wy + off.y), f32(wz + off.z)}
		verts[i].tint = tint

		sel := fd.uv[i]
		verts[i].uv = Vec2{sel[0] == 0 ? u0 : u1, sel[1] == 0 ? v0 : v1}

		sign_u := 2 * off[fd.uaxis] - 1
		sign_v := 2 * off[fd.vaxis] - 1
		du := axis_ivec(fd.uaxis, sign_u)
		dv := axis_ivec(fd.vaxis, sign_v)
		s1 := is_opaque_at(w, wx + n.x + du.x, wy + n.y + du.y, wz + n.z + du.z)
		s2 := is_opaque_at(w, wx + n.x + dv.x, wy + n.y + dv.y, wz + n.z + dv.z)
		cc := is_opaque_at(
			w,
			wx + n.x + du.x + dv.x,
			wy + n.y + du.y + dv.y,
			wz + n.z + du.z + dv.z,
		)
		ao := vertex_ao(s1, s2, cc)
		verts[i].shade = shade * AO_LIGHT[ao]
		verts[i].blocklight = bl
	}

	// Split along the diagonal that keeps AO gradients symmetric.
	if verts[0].shade + verts[2].shade >= verts[1].shade + verts[3].shade {
		append(arr, verts[0], verts[1], verts[2], verts[0], verts[2], verts[3])
	} else {
		append(arr, verts[1], verts[2], verts[3], verts[1], verts[3], verts[0])
	}
}

// One double-sided textured quad (front + back winding, so it shows through
// back-face culling). Corners p0..p3 go bottom-left, bottom-right, top-right,
// top-left; UVs map top->v0, bottom->v1.
@(private = "file")
emit_sprite_quad :: proc(arr: ^[dynamic]Vertex, p0, p1, p2, p3: Vec3, u0, v0, u1, v1, shade, bl: f32) {
	v: [4]Vertex
	v[0] = {p0, {u0, v1}, shade, bl, {1, 1, 1}}
	v[1] = {p1, {u1, v1}, shade, bl, {1, 1, 1}}
	v[2] = {p2, {u1, v0}, shade, bl, {1, 1, 1}}
	v[3] = {p3, {u0, v0}, shade, bl, {1, 1, 1}}
	// front (CCW) then back (reversed) so the cross is visible from both sides
	append(arr, v[0], v[1], v[2], v[0], v[2], v[3])
	append(arr, v[0], v[2], v[1], v[0], v[3], v[2])
}

// A cross-sprite (two crossed vertical quads) filling the cell horizontally from
// `inset`..1-inset and vertically y0..y1.
@(private = "file")
emit_sprite :: proc(arr: ^[dynamic]Vertex, b: BlockId, wx, wy, wz: int, bl, inset, y0, y1: f32) {
	u0, v0, u1, v1 := tile_uv(block_tile(b, .PosY))
	shade: f32 = 0.9
	lo := f32(0) + inset
	hi := f32(1) - inset
	x := f32(wx)
	y := f32(wy)
	z := f32(wz)
	// diagonal A: (lo,lo) -> (hi,hi)
	emit_sprite_quad(
		arr,
		{x + lo, y + y0, z + lo},
		{x + hi, y + y0, z + hi},
		{x + hi, y + y1, z + hi},
		{x + lo, y + y1, z + lo},
		u0, v0, u1, v1, shade, bl,
	)
	// diagonal B: (lo,hi) -> (hi,lo)
	emit_sprite_quad(
		arr,
		{x + lo, y + y0, z + hi},
		{x + hi, y + y0, z + lo},
		{x + hi, y + y1, z + lo},
		{x + lo, y + y1, z + hi},
		u0, v0, u1, v1, shade, bl,
	)
}

// An arbitrary box (all 6 faces, unculled) for furniture-style blocks that
// shouldn't look like a plain full cube — reuses the same FACES corner
// table as normal cubes, just remapping each corner's 0/1 offsets to
// caller-given [x0,x1]/[y0,y1]/[z0,z1] extents. Unlike emit_face, this
// always emits every face regardless of neighbours: the AO/occlusion math
// in emit_face assumes flush full-height cells, which doesn't hold for a
// partial box, so — same trade-off already accepted for cross-sprites — it
// skips AO and neighbour culling entirely in favour of flat per-face
// directional shading.
@(private = "file")
emit_box :: proc(
	arr: ^[dynamic]Vertex,
	b: BlockId,
	wx, wy, wz: int,
	x0, x1, y0, y1, z0, z1, bl: f32,
) {
	for face in Face {
		fd := FACES[face]
		tile := block_tile(b, face)
		u0, v0, u1, v1 := tile_uv(tile)
		shade := FACE_SHADE[face]

		verts: [4]Vertex
		for i in 0 ..< 4 {
			off := fd.pos[i]
			x := off.x == 1 ? x1 : x0
			y := off.y == 1 ? y1 : y0
			z := off.z == 1 ? z1 : z0
			verts[i].pos = Vec3{f32(wx) + x, f32(wy) + y, f32(wz) + z}
			verts[i].tint = Vec3{1, 1, 1}
			sel := fd.uv[i]
			verts[i].uv = Vec2{sel[0] == 0 ? u0 : u1, sel[1] == 0 ? v0 : v1}
			verts[i].shade = shade
			verts[i].blocklight = bl
		}
		append(arr, verts[0], verts[1], verts[2], verts[0], verts[2], verts[3])
	}
}

@(private = "file")
emit_lowbox :: proc(arr: ^[dynamic]Vertex, b: BlockId, wx, wy, wz: int, top_h, bl: f32) {
	emit_box(arr, b, wx, wy, wz, 0, 1, 0, top_h, 0, 1, bl)
}

@(private = "file")
emit_door :: proc(arr: ^[dynamic]Vertex, b: BlockId, wx, wy, wz: int, d: Door, bl: f32) {
	x0, x1, z0, z1 := door_extents(d)
	emit_box(arr, b, wx, wy, wz, x0, x1, 0, 0.95, z0, z1, bl)
}

// A stair: a full lower slab plus an upper half-block on the "tall" side. The
// facing (0..3) says which side the tall half sits on, so the step you climb
// faces the opposite way (see stair_facing use sites in village.odin).
@(private = "file")
emit_stair :: proc(arr: ^[dynamic]Vertex, wx, wy, wz: int, facing: u8, bl: f32) {
	emit_box(arr, .Stair, wx, wy, wz, 0, 1, 0, 0.5, 0, 1, bl) // lower slab
	switch facing {
	case 0:
		emit_box(arr, .Stair, wx, wy, wz, 0, 1, 0.5, 1, 0.5, 1, bl) // tall on +Z
	case 1:
		emit_box(arr, .Stair, wx, wy, wz, 0, 1, 0.5, 1, 0, 0.5, bl) // tall on -Z
	case 2:
		emit_box(arr, .Stair, wx, wy, wz, 0.5, 1, 0.5, 1, 0, 1, bl) // tall on +X
	case:
		emit_box(arr, .Stair, wx, wy, wz, 0, 0.5, 0.5, 1, 0, 1, bl) // tall on -X
	}
}

@(private = "file")
emit_fence :: proc(w: ^World, arr: ^[dynamic]Vertex, b: BlockId, wx, wy, wz: int, bl: f32) {
	emit_box(arr, b, wx, wy, wz, 0.4, 0.6, 0, 1.0, 0.4, 0.6, bl) // the post
	// A horizontal rail toward each neighbouring fence post (only, so a
	// lone post doesn't sprout stubs pointing at nothing) — each side's
	// rail reaches to the cell edge, so two adjacent posts' rails meet in
	// the middle and read as one connected line instead of isolated posts.
	if world_block(w, wx - 1, wy, wz) == .Fence {
		emit_box(arr, b, wx, wy, wz, 0, 0.5, 0.35, 0.55, 0.4, 0.6, bl)
	}
	if world_block(w, wx + 1, wy, wz) == .Fence {
		emit_box(arr, b, wx, wy, wz, 0.5, 1.0, 0.35, 0.55, 0.4, 0.6, bl)
	}
	if world_block(w, wx, wy, wz - 1) == .Fence {
		emit_box(arr, b, wx, wy, wz, 0.4, 0.6, 0.35, 0.55, 0, 0.5, bl)
	}
	if world_block(w, wx, wy, wz + 1) == .Fence {
		emit_box(arr, b, wx, wy, wz, 0.4, 0.6, 0.35, 0.55, 0.5, 1.0, bl)
	}
}

mesh_chunk :: proc(w: ^World, c: ^Chunk) -> MeshData {
	md: MeshData
	md.opaque = make([dynamic]Vertex, 0, 4096)
	md.water = make([dynamic]Vertex, 0, 256)

	compute_light(c)

	base_x := c.coord.x * CHUNK_W
	base_z := c.coord.y * CHUNK_D

	for y in 0 ..< CHUNK_H {
		for z in 0 ..< CHUNK_D {
			for x in 0 ..< CHUNK_W {
				b := c.blocks[chunk_index(x, y, z)]
				if b == .Air do continue
				wx := base_x + x
				wz := base_z + z
				if block_is_sprite(b) {
					bl := f32(chunk_light_at(c, x, y, z)) / 15.0
					if b == .Torch {
						emit_sprite(&md.opaque, b, wx, y, wz, bl, 0.34, 0.0, 0.62)
					} else {
						emit_sprite(&md.opaque, b, wx, y, wz, bl, 0.05, 0.0, 0.95)
					}
					continue
				}
				if b == .Door {
					bl := f32(chunk_light_at(c, x, y, z)) / 15.0
					emit_door(&md.opaque, b, wx, y, wz, w.doors[Ivec3{wx, y, wz}], bl)
					continue
				}
				if b == .Fence {
					bl := f32(chunk_light_at(c, x, y, z)) / 15.0
					emit_fence(w, &md.opaque, b, wx, y, wz, bl)
					continue
				}
				if b == .Stair {
					bl := f32(chunk_light_at(c, x, y, z)) / 15.0
					emit_stair(&md.opaque, wx, y, wz, w.stairs[Ivec3{wx, y, wz}], bl)
					continue
				}
				if block_is_lowbox(b) {
					bl := f32(chunk_light_at(c, x, y, z)) / 15.0
					emit_lowbox(&md.opaque, b, wx, y, wz, LOWBOX_HEIGHT, bl)
					continue
				}
				for face in Face {
					fn := FACES[face].n
					nb := world_block(w, wx + fn.x, y + fn.y, wz + fn.z)
					if !face_visible(b, nb) do continue
					arr := block_is_translucent(b) ? &md.water : &md.opaque
					// block light of the cell this face opens into
					bl := f32(chunk_light_at(c, x + fn.x, y + fn.y, z + fn.z)) / 15.0
					emit_face(w, arr, b, face, wx, y, wz, bl)
				}
			}
		}
	}
	return md
}

mesh_free :: proc(md: ^MeshData) {
	delete(md.opaque)
	delete(md.water)
}
