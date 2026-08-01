package main

import "core:testing"

@(private = "file")
make_test_world :: proc() -> (World, ^Chunk) {
	w: World
	world_init(&w, 12345)
	c := chunk_make(Ivec2{0, 0}) // blocks zero-initialised == .Air
	c.generated = true
	c.dirty = false
	w.chunks[Ivec2{0, 0}] = c
	return w, c
}

@(private = "file")
free_test_world :: proc(w: ^World) {
	for _, c in w.chunks {
		chunk_free(c)
	}
	delete(w.chunks)
	delete(w.mobs)
}

@(test)
test_noise_determinism :: proc(t: ^testing.T) {
	a := value_noise2(999, 12.3, -4.5)
	b := value_noise2(999, 12.3, -4.5)
	testing.expect(t, a == b, "value noise must be deterministic")
	testing.expect(t, a >= -1.0001 && a <= 1.0001, "value noise in [-1,1]")

	c := fbm3(7, 1.1, 2.2, 3.3, 4)
	d := fbm3(7, 1.1, 2.2, 3.3, 4)
	testing.expect(t, c == d, "fbm3 deterministic")
}

@(test)
test_floor_div :: proc(t: ^testing.T) {
	testing.expect(t, floor_div(0, 16) == 0)
	testing.expect(t, floor_div(15, 16) == 0)
	testing.expect(t, floor_div(16, 16) == 1)
	testing.expect(t, floor_div(-1, 16) == -1)
	testing.expect(t, floor_div(-16, 16) == -1)
	testing.expect(t, floor_div(-17, 16) == -2)
}

@(test)
test_chunk_index :: proc(t: ^testing.T) {
	testing.expect(t, chunk_index(0, 0, 0) == 0)
	testing.expect(t, chunk_index(1, 0, 0) == 1)
	testing.expect(t, chunk_index(0, 0, 1) == CHUNK_W)
	testing.expect(t, chunk_index(0, 1, 0) == CHUNK_W * CHUNK_D)

	c := chunk_make(Ivec2{0, 0})
	defer chunk_free(c)
	chunk_set(c, 3, 4, 5, .Stone)
	testing.expect(t, chunk_get(c, 3, 4, 5) == .Stone)
	testing.expect(t, chunk_get(c, -1, 0, 0) == .Air, "out of bounds reads as air")
}

@(test)
test_raycast_hits_block :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	chunk_set(c, 2, 2, 2, .Stone)

	hit := raycast(&w, Vec3{2.5, 2.5, 10.0}, Vec3{0, 0, -1}, 20.0)
	testing.expect(t, hit.hit, "ray should hit the block")
	testing.expect(t, hit.bx == 2 && hit.by == 2 && hit.bz == 2, "correct block coords")
	testing.expect(t, hit.nz == 1, "face normal points back toward origin (+z)")

	miss := raycast(&w, Vec3{2.5, 2.5, 10.0}, Vec3{0, 1, 0}, 20.0)
	testing.expect(t, !miss.hit, "ray into empty space misses")

	// entry distance: from z=10 moving -z, the ray enters the z=2 voxel at z=3
	testing.expect(t, hit.t > 6.999 && hit.t < 7.001, "raycast entry distance == 7")
}

@(test)
test_ray_aabb_distance :: proc(t: ^testing.T) {
	// unit ray hits a box whose near face is at distance 4
	ok, dist := ray_aabb(Vec3{0, 0, 0}, Vec3{1, 0, 0}, Vec3{4, -1, -1}, Vec3{5, 1, 1})
	testing.expect(t, ok, "ray should hit the box")
	testing.expect(t, dist > 3.999 && dist < 4.001, "near-face distance == 4")
}

@(test)
test_collision_lands_on_floor :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	for x in 0 ..< CHUNK_W {
		for z in 0 ..< CHUNK_D {
			chunk_set(c, x, 10, z, .Stone)
		}
	}
	p: Player
	player_init(&p, Vec3{8.5, 14.0, 8.5})
	for _ in 0 ..< 240 {
		physics_update(&w, &p, 1.0 / 60.0)
	}
	testing.expect(t, p.on_ground, "player should be grounded")
	testing.expect(t, p.pos.y >= 10.9 && p.pos.y <= 11.1, "feet rest on top of the floor block")
}

@(test)
test_ground_stable_high_fps :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	for x in 0 ..< CHUNK_W {
		for z in 0 ..< CHUNK_D {
			chunk_set(c, x, 10, z, .Stone)
		}
	}
	p: Player
	player_init(&p, Vec3{8.5, 13.0, 8.5})
	dt: f32 = 1.0 / 240.0
	for _ in 0 ..< 600 {
		physics_update(&w, &p, dt) // settle onto the floor
	}
	stable := true
	for _ in 0 ..< 240 {
		physics_update(&w, &p, dt)
		if !p.on_ground {
			stable = false
			break
		}
	}
	testing.expect(t, stable, "on_ground must stay true at 240 fps (no flicker)")
	testing.expect(t, p.pos.y >= 10.9 && p.pos.y <= 11.1, "still resting on the floor")
}

@(test)
test_no_tunnel_terminal_velocity :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	// a single 1-block-thick floor at y=40
	for x in 0 ..< CHUNK_W {
		for z in 0 ..< CHUNK_D {
			chunk_set(c, x, 40, z, .Stone)
		}
	}
	p: Player
	player_init(&p, Vec3{8.5, 44.0, 8.5})
	p.vel.y = -TERMINAL_VEL
	// worst case: one big clamped-dt step that would otherwise skip the floor
	for _ in 0 ..< 30 {
		physics_update(&w, &p, 0.05)
	}
	testing.expect(t, p.pos.y >= 40.9, "must not tunnel through the 1-block floor")
	testing.expect(t, p.on_ground, "should come to rest on the floor")
}

@(test)
test_mesher_single_block :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	chunk_set(c, 8, 40, 8, .Stone)

	md := mesh_chunk(&w, c)
	defer mesh_free(&md)
	testing.expect(t, len(md.opaque) == 36, "isolated cube => 6 faces * 6 verts")
	testing.expect(t, len(md.water) == 0, "no water")
}

@(test)
test_save_load_roundtrip :: proc(t: ^testing.T) {
	c := chunk_make(Ivec2{3, -2})
	defer chunk_free(c)
	for i in 0 ..< CHUNK_BLOCKS {
		c.blocks[i] = BlockId(u8(i % 11))
	}
	save_chunk(c)

	c2, ok := load_chunk(Ivec2{3, -2})
	testing.expect(t, ok, "load must succeed")
	if ok {
		eq := true
		for i in 0 ..< CHUNK_BLOCKS {
			if c2.blocks[i] != c.blocks[i] {
				eq = false
				break
			}
		}
		testing.expect(t, eq, "round-tripped blocks must match")
		chunk_free(c2)
	}
}

@(test)
test_block_light_propagation :: proc(t: ^testing.T) {
	c := chunk_make(Ivec2{0, 0})
	defer chunk_free(c)
	chunk_set(c, 8, 40, 8, .Glowstone)
	compute_light(c)
	// emitter cell full, adjacent air one less, and it decays with distance
	testing.expect(t, chunk_light_at(c, 8, 40, 8) == 15, "emitter is full")
	testing.expect(t, chunk_light_at(c, 9, 40, 8) == 14, "adjacent air is 14")
	testing.expect(t, chunk_light_at(c, 11, 40, 8) == 12, "3 blocks away is 12")
	testing.expect(t, chunk_light_at(c, 8, 40 + 15, 8) == 0, "beyond range is dark")
}

@(test)
test_light_blocked_by_solid :: proc(t: ^testing.T) {
	c := chunk_make(Ivec2{0, 0})
	defer chunk_free(c)
	chunk_set(c, 8, 40, 8, .Glowstone)
	chunk_set(c, 9, 40, 8, .Stone) // wall directly beside the emitter
	compute_light(c)
	// the opaque wall cell holds no propagated light, and light is blocked past it
	testing.expect(t, chunk_light_at(c, 9, 40, 8) == 0, "opaque cell not lit")
	testing.expect(t, chunk_light_at(c, 10, 40, 8) < 14, "light does not pass straight through")
}
