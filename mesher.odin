package main

import ad "assetdef"

Vertex :: struct {
	pos:        Vec3,
	uv:         Vec2,
	shade:      f32, // face directional shade * AO (dimmed by day-night ambient)
	blocklight: f32, // local block light 0..1 (immune to day-night)
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

	verts: [4]Vertex
	for i in 0 ..< 4 {
		off := fd.pos[i]
		verts[i].pos = Vec3{f32(wx + off.x), f32(wy + off.y), f32(wz + off.z)}

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
