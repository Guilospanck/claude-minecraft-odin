package main

import "core:math"
import "core:os"
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
	delete(w.items)
	delete(w.xp_orbs)
	delete(w.arrows)
	delete(w.particles)
	delete(w.crops)
	delete(w.chests)
	delete(w.doors)
	delete(w.stairs)
	delete(w.villagers)
	delete(w.villages)
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
test_xp_levels_roll_over :: proc(t: ^testing.T) {
	p: Player
	// level 0 needs 10; exactly 10 advances to level 1 with nothing left over
	xp_add(&p, 10)
	testing.expect(t, p.xp_level == 1 && p.xp_points == 0, "10 xp reaches level 1")
	// level 1 needs 14; adding 20 rolls to level 2 and carries the remaining 6
	xp_add(&p, 20)
	testing.expect(t, p.xp_level == 2 && p.xp_points == 6, "surplus xp carries into the next level")
	prog := xp_progress(&p)
	testing.expect(t, prog > 0 && prog < 1, "mid-level progress is a fraction")
}

@(test)
test_sneak_wont_walk_off_ledge :: proc(t: ^testing.T) {
	// A single 1x1 ledge block surrounded by a drop. Shoved east repeatedly, a
	// sneaking body must stay grounded on it; a normal body walks off and falls.
	shove :: proc(sneak: bool) -> (Vec3, bool) {
		w, c := make_test_world()
		defer free_test_world(&w)
		chunk_set(c, 2, 39, 2, .Stone)
		pos := Vec3{2.5, 40, 2.5}
		vel := Vec3{6, 0, 0}
		grounded := false
		for _ in 0 ..< 12 {
			if sneak {
				grounded = body_physics_sneak(&w, &pos, &vel, PLAYER_HW, PLAYER_H, 0.1)
			} else {
				grounded = body_physics(&w, &pos, &vel, PLAYER_HW, PLAYER_H, 0.1)
			}
			vel.x = 6 // keep shoving east each step
		}
		return pos, grounded
	}

	spos, sground := shove(true)
	testing.expect(t, sground, "sneaking body stays grounded on the ledge")
	testing.expect(t, spos.y > 39.5, "sneaking body never falls off the ledge")

	npos, nground := shove(false)
	testing.expect(t, !nground && npos.y < 39.0, "a non-sneaking body walks off and falls")
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
test_item_pickup :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	for x in 0 ..< CHUNK_W {
		for z in 0 ..< CHUNK_D {
			chunk_set(c, x, 10, z, .Stone)
		}
	}
	p: Player
	player_init(&p, Vec3{8.5, 11.0, 8.5})
	before := inv_count(&p, .Stone)
	item_spawn(&w.items, .Stone, Vec3{8.5, 11.2, 8.5})
	for _ in 0 ..< 90 {
		items_update(&w, &p, &w.items, 1.0 / 60.0)
	}
	testing.expect(t, inv_count(&p, .Stone) == before + 1, "item picked up into inventory")
	testing.expect(t, len(w.items) == 0, "item removed after pickup")
}

@(test)
test_craft_glowstone :: proc(t: ^testing.T) {
	p: Player
	inv_add(&p, .Sand, 5)
	inv_add(&p, .Ore, 2)
	try_craft(&p)
	testing.expect(t, inv_count(&p, .Glowstone) == 1, "crafted one glowstone")
	testing.expect(t, inv_count(&p, .Sand) == 1, "consumed 4 sand")
	testing.expect(t, inv_count(&p, .Ore) == 1, "consumed 1 ore")

	// not enough materials: no change
	try_craft(&p)
	testing.expect(t, inv_count(&p, .Glowstone) == 1, "no craft without materials")
}

@(test)
test_smelt_iron :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	chunk_set(c, 8, 40, 8, .Furnace)
	p: Player
	player_init(&p, Vec3{8.5, 40.0, 8.5}) // standing on the furnace cell
	p.slots = {}
	inv_add(&p, .Wood, 2)
	inv_add(&p, .Ore, 1)
	try_smelt(&w, &p)
	testing.expect(t, inv_count(&p, .Iron) == 1, "ore + wood smelts to iron")
	testing.expect(t, inv_count(&p, .Wood) == 1, "one wood fuel consumed")
	testing.expect(t, inv_count(&p, .Ore) == 0, "ore consumed")

	// no furnace nearby -> no smelt
	w2, _ := make_test_world()
	defer free_test_world(&w2)
	inv_add(&p, .Sand, 3)
	try_smelt(&w2, &p)
	testing.expect(t, inv_count(&p, .Glass) == 0, "no smelt without a furnace")
}

@(test)
test_arrow_hits_player :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	_ = c
	p: Player
	player_init(&p, Vec3{8.5, 40.0, 8.5})
	append(&w.arrows, Arrow{pos = Vec3{8.5, 41.0, 6.4}, vel = Vec3{0, 0, 8}, from_player = false})
	h0 := p.health
	for _ in 0 ..< 30 {
		arrows_update(&w, &p, 1.0 / 60.0)
	}
	testing.expect(t, p.health < h0, "arrow damages the player")
	testing.expect(t, len(w.arrows) == 0, "arrow consumed on hit")
}

@(test)
test_place_block :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	chunk_set(c, 8, 12, 3, .Stone) // a wall block to aim at
	p: Player
	player_init(&p, Vec3{8.5, 11.0, 8.5})
	p.yaw = 0 // look toward -z
	p.pitch = 0
	p.slots = {}
	p.selected_slot = 0
	p.slots[0] = {.Stone, 5}

	g_input = {}
	g_input.place_req = true
	handle_break_place(&w, &p, 0.016)
	g_input = {}

	testing.expect(t, world_block(&w, 8, 12, 4) == .Stone, "block placed against the wall")
	testing.expect(t, inv_count(&p, .Stone) == 4, "inventory decremented on place")

	// empty slot: nothing happens
	p.selected_slot = 1 // an empty hotbar slot
	g_input = {}
	g_input.place_req = true
	handle_break_place(&w, &p, 0.016)
	g_input = {}
	testing.expect(t, world_block(&w, 8, 12, 5) != .Iron, "no place from an empty slot")
}

@(test)
test_place_stair_records_facing :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	chunk_set(c, 8, 12, 3, .Stone) // aim at this, place onto its -Z face
	p: Player
	player_init(&p, Vec3{8.5, 11.0, 8.5})
	p.yaw = 0 // look toward -Z
	p.pitch = 0
	p.slots = {}
	p.selected_slot = 0
	p.slots[0] = {.Stair, 3}

	g_input = {}
	g_input.place_req = true
	handle_break_place(&w, &p, 0.016)
	g_input = {}

	testing.expect(t, world_block(&w, 8, 12, 4) == .Stair, "the stair was placed")
	f, ok := w.stairs[Ivec3{8, 12, 4}]
	testing.expect(t, ok && f == 1, "a stair placed looking -Z records facing 1")
}

@(test)
test_portal_is_walk_through :: proc(t: ^testing.T) {
	nw: World
	world_init(&nw, 777, .Nether)
	dest := portal_destination(&nw, 8, 8) // builds a return portal + landing
	oy := int(dest.y)

	// The interior reaches feet level (no full-block sill to jump onto), with a
	// solid floor under it, so you walk straight through.
	testing.expect(t, world_block(&nw, 9, oy, 8) == .Portal, "portal interior reaches ground level")
	testing.expect(t, block_is_solid(world_block(&nw, 9, oy - 1, 8)), "solid floor under the portal interior")

	// Standing in the portal at feet level is detected...
	p: Player
	p.pos = Vec3{9.5, f32(oy), 8.5}
	testing.expect(t, player_in_portal(&nw, p.pos), "walking in at feet level triggers travel")
	// ...but the arrival landing is clear of it (so you don't instantly bounce).
	testing.expect(t, !player_in_portal(&nw, dest), "the arrival spot is not inside the portal")
}

@(test)
test_portal_reused_not_duplicated :: proc(t: ^testing.T) {
	nw: World
	world_init(&nw, 313, .Nether)
	count_portals :: proc(w: ^World) -> int {
		n := 0
		for cz in -2 ..= 2 do for cx in -2 ..= 2 do world_ensure_chunk(w, Ivec2{cx, cz})
		for z in -24 ..< 24 do for x in -24 ..< 24 do for y in 1 ..< CHUNK_H {
			if world_block(w, x, y, z) == .Portal do n += 1
		}
		return n
	}

	dest := portal_destination(&nw, 4, 4) // builds the first portal
	first := count_portals(&nw)
	testing.expect(t, first > 0, "a portal was built the first time")

	// Coming back to a spot near that portal must REUSE it, not stamp a new one.
	_ = portal_destination(&nw, int(dest.x), int(dest.z))
	testing.expect(t, count_portals(&nw) == first, "no duplicate portal is built near an existing one")
}

@(test)
test_portal_collapses_when_frame_broken :: proc(t: ^testing.T) {
	nw: World
	world_init(&nw, 99, .Nether)
	dest := portal_destination(&nw, 8, 8) // builds a portal near x=8,z=8
	oy := int(dest.y)
	testing.expect(t, world_block(&nw, 9, oy, 8) == .Portal, "interior present before break")

	// Mine a frame block (the obsidian floor under the interior) -> interior clears.
	world_set_block(&nw, 9, oy - 1, 8, .Air)
	portal_collapse(&nw, 9, oy - 1, 8)
	testing.expect(t, world_block(&nw, 9, oy, 8) == .Air, "interior winks out when the frame is broken")
	testing.expect(t, world_block(&nw, 9, oy + 1, 8) == .Air, "the whole interior column collapses")
}

@(test)
test_step_or_block_hops_steps_but_not_fences :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	// ground plane; the walker's feet sit at y=40, heading +x toward x=3
	for lx in 0 ..< CHUNK_W do for lz in 0 ..< CHUNK_D do chunk_set(c, lx, 39, lz, .Stone)
	pos := Vec3{2.5, 40, 2.5}
	fwd := Vec3{1, 0, 0}
	hw := f32(0.3)
	h := f32(1.8)

	// nothing ahead -> keep walking
	hop, blocked := step_or_block(&w, pos, fwd, hw, h)
	testing.expect(t, !blocked && hop == 0, "clear path: no hop, not blocked")

	// a one-block step (solid at feet level, air above) -> hop it
	chunk_set(c, 3, 40, 2, .Stone)
	hop, blocked = step_or_block(&w, pos, fwd, hw, h)
	testing.expect(t, !blocked && hop > 0, "a one-block step is hopped")

	// a fence in the way -> blocked, never hopped (even though it's 1 tall)
	chunk_set(c, 3, 40, 2, .Fence)
	hop, blocked = step_or_block(&w, pos, fwd, hw, h)
	testing.expect(t, blocked && hop == 0, "a fence is impassable, not hopped")

	// a two-block wall -> blocked
	chunk_set(c, 3, 40, 2, .Stone)
	chunk_set(c, 3, 41, 2, .Stone)
	hop, blocked = step_or_block(&w, pos, fwd, hw, h)
	testing.expect(t, blocked && hop == 0, "a two-block wall is blocked")
}

@(test)
test_net_protocol :: proc(t: ^testing.T) {
	testing.expect(t, net_test_roundtrip(), "net message encode/decode must roundtrip")
}

@(test)
test_cooking :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	chunk_set(c, 8, 40, 8, .Furnace)
	p: Player
	player_init(&p, Vec3{8.5, 40.0, 8.5})
	p.slots = {}
	inv_add(&p, .Wood, 2)
	inv_add(&p, .RawFood, 3)
	try_smelt(&w, &p) // cook near the furnace
	testing.expect(t, inv_count(&p, .CookedFood) == 1, "raw food cooks to cooked")
	testing.expect(t, inv_count(&p, .RawFood) == 2, "one raw consumed")
	testing.expect(t, inv_count(&p, .Wood) == 1, "one wood fuel consumed")
}

@(test)
test_mob_drops_food :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	_ = c
	append(&w.mobs, Mob{kind = .Pig, pos = Vec3{8, 40, 8}, health = 1})
	mob_hit(&w, 0, Vec3{0, 0, 0}, 3)
	testing.expect(t, len(w.mobs) == 0, "mob dies")
	food := 0
	for it in w.items {
		if it.food do food += 1
	}
	testing.expect(t, food == 2, "passive death drops two food items")
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
	save_chunk(c, .Overworld)

	c2, ok := load_chunk(Ivec2{3, -2}, .Overworld)
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

// Overworld and nether chunks at the same (x,z) must not collide on disk.
@(test)
test_dimension_save_isolation :: proc(t: ^testing.T) {
	coord := Ivec2{5, 5}
	ov := chunk_make(coord)
	defer chunk_free(ov)
	nt := chunk_make(coord)
	defer chunk_free(nt)
	for i in 0 ..< CHUNK_BLOCKS {
		ov.blocks[i] = .Stone
		nt.blocks[i] = .Netherrack
	}
	save_chunk(ov, .Overworld)
	save_chunk(nt, .Nether)

	// re-load each and confirm the nether write did NOT clobber the overworld file
	ol, ook := load_chunk(coord, .Overworld)
	nl, nok := load_chunk(coord, .Nether)
	testing.expect(t, ook && nok, "both dimensions must load")
	if ook && nok {
		testing.expect(t, ol.blocks[0] == .Stone, "overworld chunk stays Stone")
		testing.expect(t, nl.blocks[0] == .Netherrack, "nether chunk stays Netherrack")
	}
	if ook do chunk_free(ol)
	if nok do chunk_free(nl)
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

@(test)
test_new_block_properties :: proc(t: ^testing.T) {
	// sprites: non-solid, non-opaque, but stop the targeting ray
	for b in ([]BlockId{.Wheat1, .Wheat2, .Wheat3, .Torch}) {
		testing.expect(t, block_is_sprite(b), "sprite flag")
		testing.expect(t, !block_is_solid(b), "sprite is non-solid")
		testing.expect(t, !block_is_opaque(b), "sprite is non-opaque")
		testing.expect(t, block_stops_ray(b), "sprite stops the ray")
	}
	testing.expect(t, block_is_crop(.Wheat1) && block_is_crop(.Wheat3), "wheat is a crop")
	testing.expect(t, !block_is_crop(.Torch), "torch is not a crop")
	testing.expect(t, block_emission(.Torch) == 13, "torch emits light")
	// solid, opaque blocks
	testing.expect(t, block_is_solid(.Farmland) && block_is_opaque(.Farmland), "farmland is a normal cube")
	testing.expect(t, block_is_solid(.Bed) && block_is_opaque(.Bed), "bed is a normal cube")
}

@(test)
test_crop_growth_ripens :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	chunk_set(c, 4, 40, 4, .Wheat1)
	append(&w.crops, Crop{pos = Ivec3{4, 40, 4}})

	// one full interval: young -> growing
	crops_tick(&w, GROW_TIME + 0.1)
	testing.expect(t, world_block(&w, 4, 40, 4) == .Wheat2, "advances to stage 2")
	// second interval: growing -> ripe, then it stops being tracked
	crops_tick(&w, GROW_TIME + 0.1)
	testing.expect(t, world_block(&w, 4, 40, 4) == .Wheat3, "advances to ripe")
	testing.expect(t, len(w.crops) == 0, "ripe crop is no longer tracked")
	// a further tick does not regress or crash
	crops_tick(&w, GROW_TIME + 0.1)
	testing.expect(t, world_block(&w, 4, 40, 4) == .Wheat3, "stays ripe")
}

@(test)
test_crop_removed_when_broken :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	chunk_set(c, 2, 40, 2, .Wheat1)
	append(&w.crops, Crop{pos = Ivec3{2, 40, 2}})
	world_set_block(&w, 2, 40, 2, .Air) // harvested/broken
	crops_tick(&w, GROW_TIME + 0.1)
	testing.expect(t, len(w.crops) == 0, "broken crop drops out of the list")
}

@(test)
test_sprite_mesh_emits_geometry :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	chunk_set(c, 8, 40, 8, .Wheat3)
	md := mesh_chunk(&w, c)
	defer mesh_free(&md)
	// two crossed double-sided quads = 4 quads * 6 verts = 24 verts, in the opaque
	// (cutout) pass, none in the water pass.
	testing.expect(t, len(md.opaque) == 24, "sprite emits a double-sided cross")
	testing.expect(t, len(md.water) == 0, "sprite is not translucent")
}

@(test)
test_crop_forget_on_harvest :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	chunk_set(c, 3, 40, 3, .Wheat3)
	append(&w.crops, Crop{pos = Ivec3{3, 40, 3}})
	p: Player
	harvest_crop(&w, &p, 3, 40, 3)
	testing.expect(t, world_block(&w, 3, 40, 3) == .Air, "harvest clears the block")
	testing.expect(t, inv_count(&p, .Wheat) == 1, "harvest yields wheat")
	testing.expect(t, len(w.crops) == 0, "harvest forgets the crop immediately (no stale entry)")
	// replanting the same cell tracks exactly one crop (no duplicate double-growth)
	world_set_block(&w, 3, 40, 3, .Wheat1)
	append(&w.crops, Crop{pos = Ivec3{3, 40, 3}})
	testing.expect(t, len(w.crops) == 1, "one entry after replant")
}

@(test)
test_tool_mining_and_wear :: proc(t: ^testing.T) {
	p: Player
	// hand vs wood vs iron pickaxe on stone: better tier mines faster
	hand := mining_time(&p, .Stone)
	p.tool_tier[.Pickaxe] = 1
	wood := mining_time(&p, .Stone)
	p.tool_tier[.Pickaxe] = 3
	iron := mining_time(&p, .Stone)
	testing.expect(t, wood < hand && iron < wood, "better pickaxe mines stone faster")

	// obsidian needs an iron pickaxe
	p.tool_tier[.Pickaxe] = 2
	testing.expect(t, !can_mine(&p, .Obsidian), "stone pick can't mine obsidian")
	p.tool_tier[.Pickaxe] = 3
	testing.expect(t, can_mine(&p, .Obsidian), "iron pick can mine obsidian")

	// durability: wearing to zero breaks the tool
	p.tool_tier[.Sword] = 1
	p.tool_dur[.Sword] = 2
	tool_wear(&p, .Sword)
	testing.expect(t, p.tool_tier[.Sword] == 1 && p.tool_dur[.Sword] == 1, "one point spent")
	tool_wear(&p, .Sword)
	testing.expect(t, p.tool_tier[.Sword] == 0, "sword breaks at zero durability")
}

@(test)
test_tool_craft_upgrades :: proc(t: ^testing.T) {
	p: Player
	inv_add(&p, .Wood, 2)
	tool_craft(&p, .Axe)
	testing.expect(t, p.tool_tier[.Axe] == 1, "wood axe crafted")
	testing.expect(t, p.tool_dur[.Axe] == TOOL_DUR[1], "full durability")
	testing.expect(t, inv_count(&p, .Wood) == 0, "wood consumed")
	// can't afford stone tier
	tool_craft(&p, .Axe)
	testing.expect(t, p.tool_tier[.Axe] == 1, "no upgrade without stone")
	inv_add(&p, .Stone, 3)
	tool_craft(&p, .Axe)
	testing.expect(t, p.tool_tier[.Axe] == 2, "upgraded to stone axe")
	testing.expect(t, inv_count(&p, .Stone) == 0, "stone consumed")
}

@(test)
test_chest_drag_and_take :: proc(t: ^testing.T) {
	p: Player
	p.slots = {}
	p.slots[0] = {.Stone, 30}
	ch: Chest
	g_cursor_stack = {}

	// drag the stack out of the player slot and into a chest slot
	stack_click(&p.slots[0])
	testing.expect(t, g_cursor_stack == ItemStack{.Stone, 30} && p.slots[0].id == .Air, "picked the stack off the player slot")
	stack_click(&ch.slots[5])
	testing.expect(t, ch.slots[5] == ItemStack{.Stone, 30} && g_cursor_stack.id == .Air, "dropped it into the chest slot")
	g_cursor_stack = {}

	// R (take all) moves it back into the inventory
	w, _ := make_test_world()
	defer free_test_world(&w)
	chest_open(&w, Ivec3{1, 2, 3})
	w.chests[g_chest_pos] = ch
	chest_withdraw_all(&w, &p)
	testing.expect(t, inv_count(&p, .Stone) == 30, "take-all returned the stone")
	testing.expect(t, w.chests[g_chest_pos].slots[5].id == .Air, "chest slot emptied")
}

@(test)
test_chest_break_recovers_contents :: proc(t: ^testing.T) {
	w, _ := make_test_world()
	defer free_test_world(&w)
	p: Player
	pos := Ivec3{4, 5, 6}
	ch: Chest
	ch.slots[0] = {.Iron, 7}
	w.chests[pos] = ch
	chest_break(&w, &p, pos)
	testing.expect(t, inv_count(&p, .Iron) == 7, "broken chest returns its contents")
	_, ok := w.chests[pos]
	testing.expect(t, !ok, "chest entry removed")
}

@(test)
test_chest_save_roundtrip :: proc(t: ^testing.T) {
	w, _ := make_test_world() // overworld
	defer free_test_world(&w)
	pos := Ivec3{10, 20, -30}
	ch: Chest
	ch.slots[2] = {.Wood, 12}
	ch.slots[7] = {.Glowstone, 3}
	w.chests[pos] = ch
	save_chests(&w)

	w2, _ := make_test_world()
	defer free_test_world(&w2)
	load_chests(&w2)
	rc, ok := w2.chests[pos]
	testing.expect(t, ok, "chest loaded back")
	if ok {
		testing.expect(t, rc.slots[2] == ItemStack{.Wood, 12} && rc.slots[7] == ItemStack{.Glowstone, 3}, "slot stacks preserved in place")
	}
	// cleanup the on-disk file so the test is repeatable
	clear(&w.chests)
	save_chests(&w)
}

@(test)
test_settle_water_falls :: proc(t: ^testing.T) {
	c := chunk_make(Ivec2{0, 0})
	defer chunk_free(c)
	// a solid floor at y=40, a lone water block at y=50, air between (a "bridge")
	chunk_set(c, 5, 40, 5, .Stone)
	chunk_set(c, 5, 50, 5, .Water)
	settle_water(c)
	// water should have cascaded down to rest on the floor (y=41..50 water)
	for y in 41 ..= 50 {
		testing.expect(t, chunk_get(c, 5, y, 5) == .Water, "water filled the drop")
	}
	testing.expect(t, chunk_get(c, 5, 40, 5) == .Stone, "floor intact")
	testing.expect(t, chunk_get(c, 5, 39, 5) == .Air, "did not leak through the floor")
}

@(test)
test_fly_collides_with_floor :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	for x in 0 ..< CHUNK_W {
		for z in 0 ..< CHUNK_D {
			chunk_set(c, x, 30, z, .Stone)
		}
	}
	p: Player
	player_init(&p, Vec3{8.5, 34.0, 8.5})
	p.fly = true
	p.vel = Vec3{0, -18, 0} // dive straight down
	for _ in 0 ..< 120 {
		physics_update(&w, &p, 1.0 / 60.0)
	}
	testing.expect(t, p.pos.y >= 30.9, "flying does not sink through the floor")
}

@(test)
test_oxygen_drains_and_drowns :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	// water column around the player's head at y≈8+EYE_HEIGHT
	for y in 8 ..< 14 {
		chunk_set(c, 8, y, 8, .Water)
	}
	p: Player
	player_init(&p, Vec3{8.5, 8.0, 8.5})
	testing.expect(t, player_head_submerged(&w, p.pos), "head is underwater")
	// drain all the air
	for _ in 0 ..< int(OXYGEN_MAX) + 1 {
		player_oxygen_tick(&w, &p, 1.0)
	}
	testing.expect(t, p.oxygen == 0, "oxygen empties underwater")
	h := p.health
	p.hurt_timer = 0
	player_oxygen_tick(&w, &p, 1.0) // one more second past empty
	testing.expect(t, p.health < h, "drowning damages the player")

	// surfacing refills air
	p.pos.y = 40 // no water here
	for _ in 0 ..< 5 {
		player_oxygen_tick(&w, &p, 1.0)
	}
	testing.expect(t, p.oxygen == OXYGEN_MAX, "air refills at the surface")
}

@(test)
test_land_mob_avoids_water :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	// a floor at y=10 that turns to water at x>=9 (a lake bordering the shore)
	for x in 4 ..< 13 {
		for z in 6 ..< 11 {
			chunk_set(c, x, 10, z, x >= 9 ? .Water : .Stone)
		}
	}
	m: Mob
	m.kind = .Pig
	m.pos = Vec3{6.5, 11, 8.5}
	m.yaw = math.PI * 0.5 // fwd = (sin,0,-cos) = (+1,0,0): walks straight at the lake
	m.moving = true
	m.ai_timer = 999 // keep the forced heading; don't let ai_wander override it
	p: Player
	for _ in 0 ..< 300 {
		mob_update(&w, &p, &m, -1, 1.0 / 60.0)
	}
	testing.expect(t, m.pos.x < 9.0, "a land animal never crosses into the water tile")
}

@(test)
test_aquatic_mob_never_leaves_water :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	// a small water tank surrounded by stone walls/floor/ceiling
	for x in 3 ..< 9 {
		for y in 20 ..< 26 {
			for z in 3 ..< 9 {
				edge := x == 3 || x == 8 || y == 20 || y == 25 || z == 3 || z == 8
				chunk_set(c, x, y, z, edge ? .Stone : .Water)
			}
		}
	}
	m: Mob
	m.kind = .Fish
	m.pos = Vec3{5.5, 22, 5.5}
	m.yaw = 0
	p: Player
	for _ in 0 ..< 600 {
		mob_update(&w, &p, &m, -1, 1.0 / 30.0)
		b := world_block(&w, int(math.floor(m.pos.x)), int(math.floor(m.pos.y)), int(math.floor(m.pos.z)))
		testing.expect(t, b == .Water, "fish stays inside the water tank every frame")
	}
}

@(test)
test_spawn_never_in_water_or_air :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	for y in 1 ..< 20 {
		chunk_set(c, 8, y, 8, .Water) // flood the default (8,8) spawn column
	}
	chunk_set(c, 11, 10, 8, .Grass) // the only valid dry ground nearby

	pos := spawn_pos(&w)
	bx := int(pos.x)
	by := int(pos.y) - 1
	bz := int(pos.z)
	testing.expect(t, world_block(&w, bx, by, bz) == .Grass, "spawn rests on the dry grass column")
	testing.expect(t, world_block(&w, bx, by + 1, bz) == .Air, "clear headroom above the feet")
	testing.expect(t, world_block(&w, bx, by + 2, bz) == .Air, "clear headroom above the head")
}

@(test)
test_eat_triggers_animation_and_particles :: proc(t: ^testing.T) {
	w, _ := make_test_world()
	defer free_test_world(&w)
	p: Player
	player_init(&p, Vec3{8.5, 40.0, 8.5})
	inv_add(&p, .CookedFood, 1)
	p.hunger = 5
	g_input = {}
	g_input.eat = true
	player_tick(&w, &p, 1.0 / 60.0)
	g_input = {}
	testing.expect(t, p.eat_timer > 0, "eating starts the bob/crumbs animation timer")
	testing.expect(t, len(w.particles) > 0, "eating spawns crumb particles")

	// the timer counts back down to zero over time
	for _ in 0 ..< 120 {
		player_tick(&w, &p, 1.0 / 60.0)
	}
	testing.expect(t, p.eat_timer == 0, "eat animation timer settles back to zero")
}

@(test)
test_spawn_builds_platform_when_no_land_nearby :: proc(t: ^testing.T) {
	w: World
	world_init(&w, 1)
	defer {
		for _, c in w.chunks do chunk_free(c)
		delete(w.chunks)
		delete(w.mobs);delete(w.items);delete(w.arrows);delete(w.particles)
		delete(w.crops);delete(w.chests);delete(w.doors);delete(w.stairs)
		delete(w.villagers);delete(w.villages)
	}
	// Flood every chunk within the spawn search radius with deep water (an
	// all-ocean seed near the origin) — no natural dry land exists anywhere
	// nearby, forcing the guaranteed-safe synthetic-platform fallback.
	for cx in -4 ..= 4 {
		for cz in -4 ..= 4 {
			c := chunk_make(Ivec2{cx, cz})
			for x in 0 ..< CHUNK_W {
				for z in 0 ..< CHUNK_D {
					chunk_set(c, x, 0, z, .Bedrock)
					for y in 1 ..= SEA_LEVEL {
						chunk_set(c, x, y, z, .Water)
					}
				}
			}
			c.generated = true
			w.chunks[Ivec2{cx, cz}] = c
		}
	}
	pos := spawn_pos(&w)
	bx := int(pos.x)
	by := int(pos.y) - 1
	bz := int(pos.z)
	b := world_block(&w, bx, by, bz)
	testing.expect(t, b != .Water && b != .Air, "synthetic platform provides real ground when no land is nearby")
	testing.expect(t, world_block(&w, bx, by + 1, bz) == .Air, "clear headroom above the platform")
	testing.expect(t, pos.y > f32(SEA_LEVEL), "platform sits above the water line")
}

@(test)
test_toast_shows_and_fades :: proc(t: ^testing.T) {
	toast_show("TEST MESSAGE", 1.0)
	testing.expect(t, true, "toast_show does not crash") // fixed-buffer, no allocator races
	toast_tick(0.5)
	toast_tick(0.6) // past the 1.0s life
	// no observable getter is exposed (draw-only); this just exercises the
	// tick/show path without leaking or racing under the parallel test runner
}

@(test)
test_armor_reduces_damage_and_wears :: proc(t: ^testing.T) {
	p: Player
	player_init(&p, Vec3{8.5, 40, 8.5})
	p.hurt_timer = 0
	h0 := p.health
	player_damage(&p, 10, Vec3{0, 0, 0})
	unarmored_loss := h0 - p.health

	p2: Player
	player_init(&p2, Vec3{8.5, 40, 8.5})
	p2.hurt_timer = 0
	inv_add(&p2, .Iron, 20)
	for s in ArmorSlot {
		armor_craft(&p2, s) // wood
		armor_craft(&p2, s) // stone
		armor_craft(&p2, s) // iron
	}
	testing.expect(t, armor_points(&p2) == 16, "full iron set is 16 armor points")
	testing.expect(t, armor_reduction(&p2) == 0.8, "full iron set caps at 80% reduction")
	dur0 := p2.armor_dur[.Helmet]
	h1 := p2.health
	player_damage(&p2, 10, Vec3{0, 0, 0})
	armored_loss := h1 - p2.health
	testing.expect(t, armored_loss < unarmored_loss, "armor reduces incoming damage")
	testing.expect(t, armored_loss >= 1, "armor never fully negates a hit")
	testing.expect(t, p2.armor_dur[.Helmet] == dur0 - 1, "armor wears by one point per hit")
}

@(test)
test_weather_toggles_overworld_only :: proc(t: ^testing.T) {
	w: World
	world_init(&w, 1, .Nether)
	defer free_test_world(&w)
	w.weather_timer = 0
	weather_tick(&w, 0.016)
	testing.expect(t, !w.raining, "the nether never rains")

	w2: World
	world_init(&w2, 1, .Overworld)
	defer free_test_world(&w2)
	w2.raining = true
	w2.weather_timer = 0.001
	weather_tick(&w2, 0.01) // timer expires: a rainy spell always ends
	testing.expect(t, !w2.raining, "a rain spell ends when its timer expires")
	testing.expect(t, w2.weather_timer > 0, "a new timer is armed for the next state")
}

@(test)
test_biome_precip_follows_biome_and_level :: proc(t: ^testing.T) {
	// temperate country escalates drizzle -> rain -> thunder with the storm level
	testing.expect(t, biome_precip(.Forest, 1) == .Drizzle, "a light spell drizzles")
	testing.expect(t, biome_precip(.Forest, 2) == .Rain, "a normal spell rains")
	testing.expect(t, biome_precip(.Forest, 3) == .Thunder, "a heavy spell thunders")
	testing.expect(t, biome_precip(.Jungle, 2) == .Rain, "jungle gets rain")
	testing.expect(t, biome_precip(.Swamp, 1) == .Fog, "a light spell fogs the swamp")
	testing.expect(t, biome_precip(.Jungle, 1) == .Fog, "a light spell fogs the jungle")
	// cold biomes snow, and hail in a heavy storm
	testing.expect(t, biome_precip(.Snow, 2) == .Snow, "cold biomes get snow")
	testing.expect(t, biome_precip(.Taiga, 1) == .Snow, "taiga gets snow")
	testing.expect(t, biome_precip(.Mountains, 3) == .Hail, "a heavy cold storm hails")
	// deserts stay calm in light spells but kick up sandstorms in strong ones
	testing.expect(t, biome_precip(.Desert, 1) == .None, "deserts stay dry in a light spell")
	testing.expect(t, biome_precip(.Desert, 3) == .Sandstorm, "a strong spell is a desert sandstorm")
	testing.expect(t, biome_precip(.Badlands, 2) == .Sandstorm, "badlands get sandstorms too")
}

@(test)
test_breeding_makes_a_baby :: proc(t: ^testing.T) {
	w, _ := make_test_world()
	defer free_test_world(&w)
	p: Player
	inv_add(&p, .Wheat, 2)
	append(&w.mobs, Mob{kind = .Cow, pos = Vec3{8, 40, 8}, health = 6})
	append(&w.mobs, Mob{kind = .Cow, pos = Vec3{9, 40, 8}, health = 6})
	ok1 := try_feed(&w, &p, &w.mobs[0])
	ok2 := try_feed(&w, &p, &w.mobs[1])
	testing.expect(t, ok1 && ok2, "feeding wheat to a cow is accepted")
	testing.expect(t, inv_count(&p, .Wheat) == 0, "each feeding consumes one wheat")
	testing.expect(t, w.mobs[0].love_timer > 0 && w.mobs[1].love_timer > 0, "both cows enter love mode")

	before := len(w.mobs)
	pl: Player
	mobs_update(&w, &pl, &w.mobs, 0.016)
	testing.expect(t, len(w.mobs) == before + 1, "two nearby cows in love mode breed a baby")
	found_baby := false
	for m in w.mobs do if m.is_baby do found_baby = true
	testing.expect(t, found_baby, "the new mob is flagged as a baby")
}

@(test)
test_baby_grows_up :: proc(t: ^testing.T) {
	m: Mob
	m.kind = .Pig
	m.is_baby = true
	m.grow_timer = 1.0
	m.pos = Vec3{8, 40, 8}
	w, _ := make_test_world()
	defer free_test_world(&w)
	p: Player
	for _ in 0 ..< 5 {
		mob_update(&w, &p, &m, -1, 0.3) // 1.5s total, past the 1.0s grow_timer
	}
	testing.expect(t, !m.is_baby, "a baby grows into an adult once its timer elapses")
}

@(test)
test_hunger_drains_slowly :: proc(t: ^testing.T) {
	p: Player
	player_init(&p, Vec3{8.5, 40, 8.5})
	w, _ := make_test_world()
	defer free_test_world(&w)
	// standing still for 60 simulated seconds should lose only a small sliver
	// of hunger, not empty it (regression: it used to drain fully in under a
	// minute even standing still)
	for _ in 0 ..< 3600 {
		player_tick(&w, &p, 1.0 / 60.0)
	}
	testing.expect(t, p.hunger > f32(HUNGER_MAX) - 2, "hunger barely drains over 60s standing still")
}

@(test)
test_settings_real_time_toggle :: proc(t: ^testing.T) {
	saved := g_settings.real_time
	defer g_settings.real_time = saved
	saved_sel := g_settings_sel
	defer g_settings_sel = saved_sel

	g_settings_sel = 4 // the REAL TIME DAY/NIGHT row
	g_settings.real_time = true
	settings_adjust(1)
	testing.expect(t, !g_settings.real_time, "adjusting the real-time row toggles it off")
	settings_adjust(-1)
	testing.expect(t, g_settings.real_time, "adjusting it again toggles it back on")
}

@(test)
test_real_time_fraction_in_range :: proc(t: ^testing.T) {
	f := real_time_fraction()
	testing.expect(t, f >= 0 && f < 1, "real_time_fraction returns a [0,1) day fraction")
}

@(test)
test_mob_gives_up_on_tall_wall_instead_of_bouncing :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	// a 3-block-tall wall (too tall to hop) directly ahead at x=9
	for y in 10 ..< 13 {
		chunk_set(c, 9, y, 8, .Stone)
	}
	m: Mob
	m.kind = .Pig
	m.pos = Vec3{8.5, 11, 8.5} // resting on an implicit floor, feet at y=11
	m.on_ground = true
	m.yaw = math.PI * 0.5 // fwd = (+1,0,~0): facing straight at the wall
	m.moving = true
	m.ai_timer = 999
	p: Player
	mob_update(&w, &p, &m, -1, 1.0 / 60.0)
	testing.expect(t, !m.moving, "blocked by a too-tall wall, the mob gives up instead of hopping forever")
	testing.expect(t, m.vel.y <= 0.1, "no hop is triggered against an unclimbable wall")
}

@(test)
test_mob_hops_a_real_one_block_step :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	// a genuine 1-block step at x=9 (nothing above it)
	chunk_set(c, 9, 11, 8, .Stone)
	m: Mob
	m.kind = .Pig
	m.pos = Vec3{8.5, 11, 8.5}
	m.on_ground = true
	m.yaw = math.PI * 0.5
	m.moving = true
	m.ai_timer = 999
	p: Player
	mob_update(&w, &p, &m, -1, 1.0 / 60.0)
	testing.expect(t, m.vel.y > 1.0, "a genuine 1-block step is still hopped")
}

@(test)
test_mobs_seek_mate_across_distance_and_breed :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	for x in 0 ..< CHUNK_W {
		chunk_set(c, x, 10, 8, .Stone)
	}
	append(&w.mobs, Mob{kind = .Cow, pos = Vec3{2.5, 11, 8.5}, love_timer = BREED_LOVE_DURATION, health = 6})
	append(&w.mobs, Mob{kind = .Cow, pos = Vec3{10.5, 11, 8.5}, love_timer = BREED_LOVE_DURATION, health = 6})
	p: Player
	p.pos = Vec3{6, 11, 8} // near enough that despawn-distance never kicks in
	found_baby := false
	for _ in 0 ..< 600 {
		for i in 0 ..< len(w.mobs) {
			mob_update(&w, &p, &w.mobs[i], i, 1.0 / 60.0)
		}
		breed_pass(&w, &w.mobs, 1.0 / 60.0)
		for m in w.mobs do if m.is_baby do found_baby = true
		if found_baby do break
	}
	testing.expect(t, found_baby, "two same-kind mobs in love mode, started apart, seek each other out and breed")
}

@(test)
test_slots_are_per_player_and_assignable :: proc(t: ^testing.T) {
	p1: Player
	player_init(&p1, Vec3{8.5, 40, 8.5})
	p2: Player
	player_init(&p2, Vec3{8.5, 40, 8.5})
	testing.expect(t, p1.slots[0].id == STARTER_KIT[0].id, "a fresh player starts with the starter loadout")

	p1.slots[0] = {.Iron, 1}
	testing.expect(t, p1.slots[0].id == .Iron, "a slot can be reassigned")
	testing.expect(t, p2.slots[0].id == STARTER_KIT[0].id, "reassigning one player's slots doesn't affect another's")
}

@(test)
test_inventory_add_take_count :: proc(t: ^testing.T) {
	p: Player
	p.slots = {}
	inv_add(&p, .Stone, 5)
	inv_add(&p, .Stone, 3)
	testing.expect(t, inv_count(&p, .Stone) == 8, "adds accumulate")
	testing.expect(t, p.slots[0].id == .Stone && p.slots[0].count == 8, "same type stacks into one slot")
	testing.expect(t, inv_take(&p, .Stone, 6) && inv_count(&p, .Stone) == 2, "take removes items")
	testing.expect(t, !inv_take(&p, .Stone, 100), "over-take fails")
	testing.expect(t, inv_count(&p, .Stone) == 2, "a failed take leaves the stack intact")

	// overflow past STACK_MAX spills into a second slot
	p.slots = {}
	inv_add(&p, .Dirt, STACK_MAX + 10)
	testing.expect(t, inv_count(&p, .Dirt) == STACK_MAX + 10, "a big add spans multiple slots")
}

@(test)
test_peaceful_mode_clears_existing_hostiles :: proc(t: ^testing.T) {
	saved := g_settings.peaceful
	defer g_settings.peaceful = saved

	w, _ := make_test_world()
	defer free_test_world(&w)
	append(&w.mobs, Mob{kind = .Zombie, pos = Vec3{8, 40, 8}, health = 12})
	append(&w.mobs, Mob{kind = .Pig, pos = Vec3{9, 40, 8}, health = 6})
	p: Player
	p.pos = Vec3{8, 40, 8}

	g_settings.peaceful = false
	mobs_update(&w, &p, &w.mobs, 0.016)
	testing.expect(t, len(w.mobs) == 2, "hostiles are untouched outside peaceful mode")

	g_settings.peaceful = true
	mobs_update(&w, &p, &w.mobs, 0.016)
	testing.expect(t, len(w.mobs) == 1, "peaceful mode removes the existing zombie")
	testing.expect(t, w.mobs[0].kind == .Pig, "the passive pig is left alone")
}

@(test)
test_peaceful_mode_blocks_new_hostile_spawns :: proc(t: ^testing.T) {
	saved := g_settings.peaceful
	defer g_settings.peaceful = saved
	g_settings.peaceful = true

	w, _ := make_test_world()
	defer free_test_world(&w)
	w.time_of_day = 0.0 // midnight: hostile_try_spawn would otherwise be eligible
	p: Player
	for _ in 0 ..< 200 {
		mobs_update(&w, &p, &w.mobs, 0.05)
	}
	for m in w.mobs {
		testing.expect(t, !mob_is_hostile(m.kind), "no hostile ever spawns while peaceful is on")
	}
}

@(test)
test_wish_dir_follows_pitch_when_flying :: proc(t: ^testing.T) {
	// looking straight up (+pitch) while flying and holding W should give a
	// wish direction that's mostly vertical, not flat
	up_wish := compute_wish_dir(0, 1.5, true, false, true, false, false, false)
	testing.expect(t, up_wish.y > 0.9, "flying + looking up + W climbs steeply")

	down_wish := compute_wish_dir(0, -1.5, true, false, true, false, false, false)
	testing.expect(t, down_wish.y < -0.9, "flying + looking down + W dives steeply")
}

@(test)
test_wish_dir_stays_horizontal_when_walking :: proc(t: ^testing.T) {
	// the previous bug: pitch was ignored everywhere, which is actually the
	// desired behaviour for ground walking (fly=false, in_water=false)
	wish := compute_wish_dir(0, 1.5, false, false, true, false, false, false)
	testing.expect(t, wish.y == 0, "walking forward stays flat regardless of pitch")
	testing.expect(t, wish.z < -0.9, "still moves forward on the ground plane")
}

@(test)
test_wish_dir_follows_pitch_when_swimming :: proc(t: ^testing.T) {
	wish := compute_wish_dir(0, 1.0, false, true, true, false, false, false)
	testing.expect(t, wish.y > 0.5, "swimming + looking up + W rises")
}

@(test)
test_wish_dir_strafe_stays_level :: proc(t: ^testing.T) {
	// strafing should never be affected by pitch, even while flying
	wish := compute_wish_dir(0, 1.4, true, false, false, false, false, true)
	testing.expect(t, wish.y == 0, "strafing (D) stays level regardless of pitch")
	testing.expect(t, wish.x > 0.9, "strafes sideways")
}

@(test)
test_spawn_never_in_sealed_cave_under_ocean :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	// A sealed cave pocket at (8,8): a floor with two clear blocks above it
	// (the exact shape the old code accepted as "valid ground"), but sealed
	// under solid rock and then an ocean above that — never actually open to
	// the sky. This is the real bug: spawning inside a cave under the ocean.
	chunk_set(c, 8, 1, 8, .Stone) // cave floor; y=2,3 default to Air (cave interior)
	for y in 4 ..< 41 {
		chunk_set(c, 8, y, 8, .Stone) // rock separating the cave from the ocean
	}
	for y in 41 ..= int(SEA_LEVEL) {
		chunk_set(c, 8, y, 8, .Water) // ocean above the rock
	}
	chunk_set(c, 12, 10, 8, .Grass) // genuine dry land elsewhere

	pos := spawn_pos(&w)
	bx := int(pos.x)
	by := int(pos.y) - 1
	bz := int(pos.z)
	testing.expect(t, !(bx == 8 && bz == 8), "never spawns in the sealed cave pocket under the ocean")
	testing.expect(t, world_block(&w, bx, by, bz) == .Grass, "spawns on the real dry land instead")
}

@(test)
test_mob_old_age_kills_and_tags_death_cause :: proc(t: ^testing.T) {
	w, _ := make_test_world()
	defer free_test_world(&w)
	m := Mob{kind = .Pig, pos = Vec3{8, 40, 8}, health = 1, age = MOB_OLD_AGE + 1}

	mob_life_tick(&w, &m, 1.0)

	testing.expect(t, m.health <= 0, "an old mob takes old-age damage")
	testing.expect(t, m.death_cause == .OldAge, "the death is tagged as old age")
}

@(test)
test_mob_grazing_relieves_hunger_and_turns_grass_to_dirt :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	chunk_set(c, 8, 39, 8, .Grass)
	m := Mob{kind = .Cow, pos = Vec3{8.5, 40, 8.5}, health = 6, hunger_level = MOB_GRAZE_RELIEF}

	mob_life_tick(&w, &m, 0.5)

	testing.expect(t, m.hunger_level < MOB_GRAZE_RELIEF, "grazing lowers hunger_level")
	testing.expect(t, world_block(&w, 8, 39, 8) == .Dirt, "grazing converts the grass beneath the mob to dirt")
}

@(test)
test_mob_starves_without_grazing :: proc(t: ^testing.T) {
	w, _ := make_test_world()
	defer free_test_world(&w)
	// no grass anywhere nearby, so hunger only ever climbs
	m := Mob{kind = .Chicken, pos = Vec3{8, 40, 8}, health = 1, hunger_level = MOB_STARVE_THRESHOLD + 1}

	mob_life_tick(&w, &m, 1.0)

	testing.expect(t, m.health <= 0, "a hungry mob takes starvation damage")
	testing.expect(t, m.death_cause == .Starvation, "the death is tagged as starvation")
}

@(test)
test_predation_damages_nearby_passive_mob :: proc(t: ^testing.T) {
	w, _ := make_test_world()
	defer free_test_world(&w)
	p: Player
	// beyond ZOMBIE_DETECT, so ai_hostile falls back to predation instead of
	// chasing the player; mob_update is exercised directly (not mobs_update)
	// so this test doesn't race other tests' concurrent g_settings.peaceful
	// mutation under odin test's multithreaded runner.
	p.pos = Vec3{38, 40, 8}
	append(&w.mobs, Mob{kind = .Zombie, pos = Vec3{8, 40, 8}, health = 12})
	append(&w.mobs, Mob{kind = .Pig, pos = Vec3{9, 40, 8}, health = 6})

	prey_health_before := w.mobs[1].health
	mob_update(&w, &p, &w.mobs[0], 0, 1.0)

	prey_idx := -1
	for i in 0 ..< len(w.mobs) do if w.mobs[i].kind == .Pig do prey_idx = i
	testing.expect(t, prey_idx >= 0, "the prey mob still exists after one predation tick")
	if prey_idx >= 0 {
		testing.expect(
			t,
			w.mobs[prey_idx].health < prey_health_before,
			"a hostile within predation reach damages nearby passive prey",
		)
	}
}

@(test)
test_biome_supports_grazing_only_vegetated_biomes :: proc(t: ^testing.T) {
	testing.expect(t, biome_supports_grazing(.Plains), "plains supports grazing")
	testing.expect(t, biome_supports_grazing(.Forest), "forest supports grazing")
	testing.expect(t, !biome_supports_grazing(.Desert), "desert has nothing to graze")
	testing.expect(t, !biome_supports_grazing(.Ocean), "ocean has nothing to graze")
	testing.expect(t, !biome_supports_grazing(.Badlands), "badlands has nothing to graze")
	testing.expect(t, !biome_supports_grazing(.Mountains), "mountains has nothing to graze")
}

@(test)
test_food_or_water_nearby_requires_grass_or_water :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	testing.expect(
		t,
		!food_or_water_nearby(&w, 8, 8, 40),
		"an empty stone-and-air world has no food or water nearby",
	)
	// fill (nearly) the whole chunk with grass so the random radius-sample
	// reliably lands on it, instead of relying on hitting one exact column
	for lx in 0 ..< CHUNK_W do for lz in 0 ..< CHUNK_D do chunk_set(c, lx, 40, lz, .Grass)
	testing.expect(t, food_or_water_nearby(&w, 8, 8, 40), "grass placed nearby is found")
}

@(test)
test_mob_fall_damage_from_a_long_drop :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	// a full-chunk floor, not just one column: the mob can wander a bit
	// horizontally while falling (ai_wander may set it moving), and a
	// single-column platform would let it miss the ledge and fall through
	for lx in 0 ..< CHUNK_W do for lz in 0 ..< CHUNK_D do chunk_set(c, lx, 39, lz, .Stone)
	p: Player
	append(
		&w.mobs,
		Mob{kind = .Pig, pos = Vec3{8.5, 70, 8.5}, vel = Vec3{0, -40, 0}, health = 20},
	)

	mobs_update(&w, &p, &w.mobs, 1.0)

	testing.expect(t, len(w.mobs) == 1, "the mob survives a 40 fall-speed drop from 20 health")
	if len(w.mobs) == 1 {
		testing.expect(t, w.mobs[0].health < 20, "landing hard enough deals fall damage")
		testing.expect(t, w.mobs[0].death_cause == .Fall, "the damage is tagged as a fall")
	}
}

@(test)
test_door_extents_rotate_90_degrees_when_open :: proc(t: ^testing.T) {
	cx0, cx1, cz0, cz1 := door_extents(Door{facing = 0, open = false})
	testing.expect(t, cx1 - cx0 > cz1 - cz0, "facing-0 closed spans X (thin along Z)")

	ox0, ox1, oz0, oz1 := door_extents(Door{facing = 0, open = true})
	testing.expect(t, oz1 - oz0 > ox1 - ox0, "facing-0 open rotates to span Z (thin along X)")
}

@(test)
test_door_toggle_flips_open_state :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	chunk_set(c, 8, 39, 8, .Stone)
	chunk_set(c, 8, 40, 8, .Door)
	pos := Ivec3{8, 40, 8}

	testing.expect(t, !w.doors[pos].open, "a door not yet in w.doors defaults to closed")
	door_toggle(&w, pos)
	testing.expect(t, w.doors[pos].open, "toggling an unregistered door opens it")
	door_toggle(&w, pos)
	testing.expect(t, !w.doors[pos].open, "toggling again closes it")
}

@(test)
test_village_biome_ok_only_calm_biomes :: proc(t: ^testing.T) {
	testing.expect(t, village_biome_ok(.Plains), "plains is a fine village site")
	testing.expect(t, village_biome_ok(.Forest), "forest is a fine village site")
	testing.expect(t, !village_biome_ok(.Ocean), "no villages in the ocean")
	testing.expect(t, !village_biome_ok(.Mountains), "no villages on mountains")
	testing.expect(t, !village_biome_ok(.Badlands), "no villages in badlands")
}

@(test)
test_generate_house_places_walls_door_and_hollow_interior :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	for lx in 0 ..< CHUNK_W do for lz in 0 ..< CHUNK_D do chunk_set(c, lx, 39, lz, .Stone)

	generate_house(&w, c, 0, 0, 2, 2, 39, 0, biome_build_mats(.Plains))

	// a wall corner: stone foundation course, then wood above it
	testing.expect(t, chunk_get(c, 2, 40, 2) == .Stone, "wall corner starts with a stone foundation")
	testing.expect(t, chunk_get(c, 2, 41, 2) == .Wood, "wall corner continues in wood above the foundation")
	// interior is hollowed out, not solid wood
	testing.expect(t, chunk_get(c, 4, 39, 4) == .Planks, "the floor is planks, flush with outside ground")
	testing.expect(t, block_is_carpet(chunk_get(c, 4, 40, 4)), "a carpet rug sits at walk level")
	testing.expect(t, chunk_get(c, 4, 41, 4) == .Air, "the interior is hollow above the floor")
	// a door sits in the middle of the south wall, with headroom above it
	testing.expect(t, chunk_get(c, 4, 40, 2) == .Door, "a door opening exists in the south wall")
	testing.expect(t, chunk_get(c, 4, 41, 2) == .Air, "there's headroom above the door")
	testing.expect(t, chunk_get(c, 4, 42, 2) == .Air, "the doorway is two cells tall")
	_, ok := w.doors[Ivec3{4, 40, 2}]
	testing.expect(t, ok, "the placed door is registered in w.doors")
	// the tapering roof starts right above the walls, centred on the house
	// the roof's base course (the widest layer) is a real half-height eave
	// (Slab), not a full block; the layers above it taper in full Stone
	testing.expect(t, chunk_get(c, 4, 43, 4) == .Slab, "the roof's base course is a slab eave")
	testing.expect(t, chunk_get(c, 4, 44, 4) == .Stone, "the roof tapers to stone above the eave")
	// a fenced yard surrounds the house, with a gap left open for the door
	testing.expect(t, chunk_get(c, 1, 40, 1) == .Fence, "a fence yard surrounds the house")
	testing.expect(t, chunk_get(c, 4, 40, 1) != .Fence, "the fence leaves a gap aligned with the door")
}

@(test)
test_generate_church_has_spire_beacon_and_door :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	for lx in 0 ..< CHUNK_W do for lz in 0 ..< CHUNK_D do chunk_set(c, lx, 39, lz, .Stone)

	generate_church(&w, c, 0, 0, 10, 2, 39)

	testing.expect(t, chunk_get(c, 10, 40, 2) == .Stone, "the church walls are stone, not wood")
	testing.expect(t, chunk_get(c, 12, 40, 2) == .Door, "the church has a front door")
	testing.expect(t, chunk_get(c, 12, 51, 4) == .Glowstone, "the spire is capped with a lit beacon")
	testing.expect(t, chunk_get(c, 10, 45, 2) == .Stair, "a flared stair eave rings the roofline")
	testing.expect(t, chunk_get(c, 9, 40, 1) == .Fence, "the church has a churchyard fence")
}

@(test)
test_generate_farm_has_farmland_wheat_and_fence :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	for lx in 0 ..< CHUNK_W do for lz in 0 ..< CHUNK_D do chunk_set(c, lx, 39, lz, .Stone)

	generate_farm(&w, c, 0, 0, 10, 10, 39)

	testing.expect(t, chunk_get(c, 10, 39, 10) == .Farmland, "the farm plot is tilled")
	testing.expect(t, block_is_crop(chunk_get(c, 10, 40, 10)), "wheat grows on the tilled farmland")
	testing.expect(t, chunk_get(c, 9, 40, 9) == .Fence, "the farm plot is fenced")
}

@(test)
test_place_foundation_grounds_sloped_columns :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)

	// A 2-wide footprint over sloping ground. Plot-centre surface is y=45 (so
	// the building's base course sits at base_y = surf_y + 1 = 46, matching how
	// generate_village calls this); the far column is three blocks lower at
	// heights=42. Without a pedestal the building would float over that column.
	heights: [CHUNK_W * CHUNK_D]int
	for i in 0 ..< len(heights) do heights[i] = 45
	heights[5 + 6 * CHUNK_W] = 42 // the lower column

	base_y := 46
	place_foundation(c, heights[:], 5, 5, 6, 6, base_y)

	// The lower column is packed with stone from its own surface up to just
	// below the building base — no air gap left to float over.
	for y in 42 ..< base_y {
		testing.expect(t, chunk_get(c, 5, y, 6) == .Stone, "the pedestal fills the gap under a low column")
	}
	// The fill stops exactly at the foundation-course level, never above it.
	testing.expect(t, chunk_get(c, 5, base_y, 6) == .Air, "the pedestal never reaches into the building")
	// A column already at grade still gets the single course that closes the
	// natural one-block gap between the terrain top and the foundation course.
	testing.expect(t, chunk_get(c, 5, 45, 5) == .Stone, "a level column still gets grounded")
	testing.expect(t, chunk_get(c, 5, 46, 5) == .Air, "a level column isn't filled into the building")
}

@(test)
test_villages_and_materials_by_biome :: proc(t: ^testing.T) {
	// Villages now settle in cold and arid biomes too (so there are snow/desert
	// villages to dress for), but not in ocean/jungle/swamp.
	testing.expect(t, village_biome_ok(.Snow), "villages can settle in snow")
	testing.expect(t, village_biome_ok(.Desert), "villages can settle in desert")
	testing.expect(t, village_biome_ok(.Taiga), "villages can settle in taiga")
	testing.expect(t, !village_biome_ok(.Ocean), "no villages at sea")
	testing.expect(t, !village_biome_ok(.Jungle), "no villages in dense jungle")
	// Buildings take on the biome's materials.
	testing.expect(t, biome_build_mats(.Snow).roof == .Snow, "snow villages get white roofs")
	testing.expect(t, biome_build_mats(.Desert).wall == .Sand, "desert villages get sand walls")
	testing.expect(t, biome_build_mats(.Plains).roof == .Stone, "temperate villages keep stone roofs")
}

@(test)
test_player_save_roundtrip :: proc(t: ^testing.T) {
	p: Player
	player_init(&p, Vec3{10, 20, 30})
	p.health = 7
	p.selected_slot = 3
	p.slots = {}
	p.slots[0] = {.Stone, 42}
	p.slots[10] = {.Gold, 3}
	inv_add(&p, .RawFood, 4) // food is now just another slot item
	inv_add(&p, .Wheat, 9)
	p.tool_tier[.Pickaxe] = 3
	p.tool_dur[.Pickaxe] = 120
	p.armor_tier[.Helmet] = 2
	p.xp_level = 5
	p.xp_points = 8

	save_player(&p)
	defer os.remove("saves/player.dat")

	q: Player
	player_init(&q, Vec3{0, 0, 0})
	ok := load_player(&q)
	testing.expect(t, ok, "the saved player loads back")
	testing.expect(t, q.health == 7, "health restored")
	testing.expect(t, q.selected_slot == 3, "equipped hotbar slot restored")
	testing.expect(t, inv_count(&q, .RawFood) == 4 && inv_count(&q, .Wheat) == 9, "food counters restored")
	testing.expect(t, q.slots[0] == ItemStack{.Stone, 42} && q.slots[10] == ItemStack{.Gold, 3}, "slot stacks restored in place")
	testing.expect(t, q.tool_tier[.Pickaxe] == 3 && q.tool_dur[.Pickaxe] == 120, "tools restored")
	testing.expect(t, q.armor_tier[.Helmet] == 2, "armor restored")
	testing.expect(t, q.xp_level == 5 && q.xp_points == 8, "experience level and points restored")
	testing.expect(t, math.abs(q.pos.x - 10) < 0.01 && math.abs(q.pos.z - 30) < 0.01, "position restored")
}

@(test)
test_inventory_slot_clicks :: proc(t: ^testing.T) {
	p: Player
	p.slots = {}
	g_cursor_stack = {}
	p.slots[9] = {.Stone, 20}

	// left-click a full slot with an empty cursor: pick up the whole stack
	inv_click_slot(&p, 9)
	testing.expect(t, g_cursor_stack == ItemStack{.Stone, 20} && p.slots[9].id == .Air, "left-click picks up the stack")

	// left-click an empty slot: drop the whole cursor stack
	inv_click_slot(&p, 0)
	testing.expect(t, p.slots[0] == ItemStack{.Stone, 20} && g_cursor_stack.id == .Air, "left-click drops onto an empty slot")

	// right-click a slot with an empty cursor: split off half (ceil)
	inv_rclick_slot(&p, 0)
	testing.expect(t, g_cursor_stack == ItemStack{.Stone, 10} && p.slots[0].count == 10, "right-click splits half")

	// right-click a same-type slot with a held stack: drop one
	inv_rclick_slot(&p, 0)
	testing.expect(t, p.slots[0].count == 11 && g_cursor_stack.count == 9, "right-click drops one onto the same type")

	// left-click a different-type slot: swap
	p.slots[1] = {.Wood, 5}
	inv_click_slot(&p, 1) // cursor has Stone x9
	testing.expect(t, p.slots[1] == ItemStack{.Stone, 9} && g_cursor_stack == ItemStack{.Wood, 5}, "left-click swaps different types")
	g_cursor_stack = {}
}

@(test)
test_inventory_slot_hit_tests :: proc(t: ^testing.T) {
	aspect := f32(16.0) / 9.0
	// The centre of each slot must hit-test back to that slot.
	for slot in ([?]int{0, 4, 8, 9, 20, INV_SLOTS - 1}) {
		x0, y0, sw, sz := inv_slot_rect(aspect, slot)
		testing.expect(t, inv_hit_slot(aspect, x0 + sw * 0.5, y0 + sz * 0.5) == slot, "a slot's centre hits that slot")
	}
	// A point out in empty space hits nothing.
	testing.expect(t, inv_hit_slot(aspect, 0.95, 0.95) == -1, "empty space hits no slot")
}

@(test)
test_stairs_are_craftable :: proc(t: ^testing.T) {
	found := false
	for r in RECIPES do if r.out == .Stair {found = true}
	testing.expect(t, found, "there is a recipe that outputs stairs")
}

@(test)
test_stair_facing_from_look_direction :: proc(t: ^testing.T) {
	testing.expect(t, stair_facing_from_dir(Vec3{1, 0, 0}) == 2, "looking +X: tall half on +X")
	testing.expect(t, stair_facing_from_dir(Vec3{-1, 0, 0}) == 3, "looking -X: tall half on -X")
	testing.expect(t, stair_facing_from_dir(Vec3{0, 0, 1}) == 0, "looking +Z: tall half on +Z")
	testing.expect(t, stair_facing_from_dir(Vec3{-0.2, -0.5, -1}) == 1, "look dir picks the dominant horizontal axis")
}

@(test)
test_snowy_tree_caps_canopy_with_snow :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	for lx in 0 ..< CHUNK_W do for lz in 0 ..< CHUNK_D do chunk_set(c, lx, 39, lz, .Grass)

	place_snowy_tree(c, 8, 39, 8, 6, .Pine)

	leaves, snow := 0, 0
	for y in 40 ..< 60 {
		for dz in -2 ..= 2 {
			for dx in -2 ..= 2 {
				b := chunk_get(c, 8 + dx, y, 8 + dz)
				if b == .Leaves do leaves += 1
				// snow must rest directly on a leaf (the dusted canopy)
				if b == .Snow && chunk_get(c, 8 + dx, y - 1, 8 + dz) == .Leaves do snow += 1
			}
		}
	}
	testing.expect(t, leaves > 0, "the pine has a leafy canopy")
	testing.expect(t, snow > 0, "snow is dusted on top of the canopy")
}

@(test)
test_new_aquatic_mobs :: proc(t: ^testing.T) {
	for k in ([?]MobKind{.Dolphin, .Pufferfish, .Jellyfish}) {
		testing.expect(t, mob_is_aquatic(k), "new water mobs are aquatic (stay submerged)")
		testing.expect(t, !mob_is_hostile(k), "new water mobs are passive")
	}
}

@(test)
test_biome_specialist_animals :: proc(t: ^testing.T) {
	k, ok := biome_specialist(.Snow)
	testing.expect(t, ok && (k == .SnowLeopard || k == .Fox), "snow biomes get snow leopards or foxes")
	k, ok = biome_specialist(.Desert)
	testing.expect(t, ok && k == .Camel, "deserts get camels")
	k, ok = biome_specialist(.Savanna)
	testing.expect(t, ok && k == .Llama, "savanna gets llamas")
	k, ok = biome_specialist(.Mountains)
	testing.expect(t, ok && (k == .Goat || k == .Llama), "mountains get goats or llamas")
	_, ok = biome_specialist(.Plains)
	testing.expect(t, !ok, "ordinary biomes have no specialist (grazers spawn there)")
	// specialists must be passive land animals, not hostile or aquatic
	testing.expect(t, !mob_is_hostile(.SnowLeopard) && !mob_is_aquatic(.SnowLeopard), "leopard is a passive land animal")
	testing.expect(t, !mob_is_hostile(.Camel) && !mob_is_aquatic(.Camel), "camel is a passive land animal")
}

@(test)
test_plant_blocks_are_nonsolid_sprites :: proc(t: ^testing.T) {
	// New ground-cover plants must behave like the existing sprites: rendered
	// as cross-sprites, walkable, and not occluding neighbours.
	plants := [?]BlockId{.FlowerBlue, .FlowerPink, .FlowerWhite, .TallGrass, .Fern, .DeadBush}
	for b in plants {
		testing.expect(t, block_is_sprite(b), "a plant renders as a sprite")
		testing.expect(t, block_is_plant(b), "a plant is classified as a plant")
		testing.expect(t, !block_is_solid(b), "a plant is walkable, not solid")
		testing.expect(t, !block_is_opaque(b), "a plant doesn't occlude neighbours")
	}
}

@(test)
test_climate_spread_widens_and_keeps_sign :: proc(t: ^testing.T) {
	// zero stays put, sign is preserved, and a mid-range input is pushed
	// meaningfully further out toward the extremes (that widening is the whole
	// point — it's what makes cold/hot biomes common instead of rare tails).
	testing.expect(t, climate_spread(0) == 0, "zero maps to zero")
	testing.expect(t, climate_spread(-0.2) < 0, "sign is preserved (negative)")
	testing.expect(t, climate_spread(0.2) > 0.2, "a mid input is spread further out")
	testing.expect(t, climate_spread(0.2) <= 1.0 && climate_spread(1.0) <= 1.0, "output stays clamped to 1")
}

@(test)
test_biomes_are_varied_and_cold_never_borders_hot :: proc(t: ^testing.T) {
	// Deterministic for a fixed seed: over a broad grid the world must show a
	// good spread of biomes (the "more of the same" fix) AND never place a
	// frigid biome directly beside a torrid one (the "snow limiting a desert"
	// fix, guaranteed by the temp-monotonic classification grid).
	frigid :: proc(b: Biome) -> bool {return b == .Snow || b == .Taiga}
	torrid :: proc(b: Biome) -> bool {
		return b == .Desert || b == .Badlands || b == .Savanna || b == .Jungle
	}
	seed := u64(4242)
	seen: map[Biome]bool
	defer delete(seen)
	violations := 0
	STEP :: 8
	for wz := -600; wz < 600; wz += STEP {
		for wx := -600; wx < 600; wx += STEP {
			_, b, _ := world_height_and_biome(seed, wx, wz)
			seen[b] = true
			_, bx, _ := world_height_and_biome(seed, wx + STEP, wz)
			_, bz, _ := world_height_and_biome(seed, wx, wz + STEP)
			if (frigid(b) && torrid(bx)) || (torrid(b) && frigid(bx)) do violations += 1
			if (frigid(b) && torrid(bz)) || (torrid(b) && frigid(bz)) do violations += 1
		}
	}
	testing.expect(t, violations == 0, "a frigid biome never borders a torrid one")
	testing.expect(t, len(seen) >= 8, "a broad area shows a rich spread of biomes, not more of the same")
}

@(test)
test_mob_faces_have_expected_styles :: proc(t: ^testing.T) {
	testing.expect(t, face_def_for_mob(.Cow).style == .Animal, "animals get an eyes-only face")
	testing.expect(t, face_def_for_mob(.Zombie).style == .Humanoid, "humanoid mobs get a full face")
	testing.expect(t, face_def_for_mob(.Fish).style == .None, "tiny aquatic mobs get no face")
}

@(test)
test_villager_avoids_water :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	// a floor at y=10 that turns to water at x>=9 (a lake bordering the shore)
	for x in 4 ..< 13 {
		for z in 6 ..< 11 {
			chunk_set(c, x, 10, z, x >= 9 ? .Water : .Stone)
		}
	}
	v: Villager
	v.pos = Vec3{6.5, 11, 8.5}
	v.yaw = math.PI * 0.5 // fwd = (sin,0,-cos) = (+1,0,0): walks straight at the lake
	v.moving = true
	v.ai_timer = 999 // keep the forced heading; don't let villager_wander override it
	for _ in 0 ..< 300 {
		villager_update(&w, &v, 1.0 / 60.0)
	}
	testing.expect(t, v.pos.x < 9.0, "a villager never crosses into the water tile")
}

@(test)
test_farmer_drives_off_predator :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	for x in 0 ..< CHUNK_W do for z in 0 ..< CHUNK_D do chunk_set(c, x, 10, z, .Stone)
	// a farmer with a wolf right beside it (within a swing)
	v := Villager {
		pos        = Vec3{5.5, 11, 5.5},
		profession = .Farmer,
		health     = 10,
	}
	append(&w.mobs, Mob{kind = .Wolf, pos = Vec3{6.6, 11, 5.5}, health = 12})
	for _ in 0 ..< 30 {
		villager_update(&w, &v, 1.0 / 60.0)
	}
	testing.expect(t, w.mobs[0].health < 12, "a farmer strikes a wolf that comes near")
	testing.expect(t, w.mobs[0].flee_timer > 0, "the struck predator is sent fleeing")
}

@(test)
test_villager_pick_finds_nearest_under_the_ray :: proc(t: ^testing.T) {
	villagers := make([dynamic]Villager, 0, 2)
	defer delete(villagers)
	append(&villagers, Villager{pos = Vec3{5, 40, 5}, name = "MARA"})
	append(&villagers, Villager{pos = Vec3{50, 40, 50}, name = "OTIS"})

	idx, _ := villager_pick(&villagers, Vec3{5, 40.5, 0}, Vec3{0, 0, 1}, 20)
	testing.expect(t, idx == 0, "the ray finds the nearby villager, not the distant one")
}

@(test)
test_mobs_crowded_caps_local_density_only :: proc(t: ^testing.T) {
	mobs := make([dynamic]Mob, 0, MOB_LOCAL_CAP + 1)
	defer delete(mobs)
	for i in 0 ..< MOB_LOCAL_CAP {
		append(&mobs, Mob{kind = .Chicken, pos = Vec3{f32(i), 40, 0}, health = 4})
	}
	testing.expect(
		t,
		mobs_crowded(&mobs, 0, 0),
		"a spot with MOB_LOCAL_CAP mobs already nearby counts as crowded",
	)
	testing.expect(
		t,
		!mobs_crowded(&mobs, 5000, 5000),
		"a spot far from every existing mob is never crowded",
	)
}

@(test)
test_spawn_rolls_gated_by_density_but_breeding_is_not :: proc(t: ^testing.T) {
	w, _ := make_test_world()
	defer free_test_world(&w)
	player_pos := Vec3{8, 40, 8}

	// hostile_try_spawn's candidate is a random point 24-46 blocks from
	// player_pos, at any angle - a small mob cluster wouldn't reliably be
	// "nearby" the actual roll every run. A dense grid spanning the whole
	// possible candidate square (half-extent 46, well past the max roll
	// distance) with MOB_LOCAL_RADIUS-overlapping spacing guarantees at
	// least MOB_LOCAL_CAP mobs are within range of *any* candidate the roll
	// could produce, so the gate blocking is deterministic, not a fluke of
	// this run's RNG draw.
	for gx := -48; gx <= 48; gx += 12 {
		for gz := -48; gz <= 48; gz += 12 {
			append(
				&w.mobs,
				Mob{kind = .Chicken, pos = Vec3{8 + f32(gx), 40, 8 + f32(gz)}, health = 4},
			)
		}
	}
	before := len(w.mobs)

	for _ in 0 ..< 20 do hostile_try_spawn(&w, &w.mobs, player_pos)
	testing.expect(t, len(w.mobs) == before, "random spawn rolls are blocked anywhere in an already-crowded area")

	// breeding is a completely different code path and must ignore the cap
	append(
		&w.mobs,
		Mob{kind = .Cow, pos = Vec3{8, 40, 8}, love_timer = BREED_LOVE_DURATION, health = 6},
	)
	append(
		&w.mobs,
		Mob{kind = .Cow, pos = Vec3{9, 40, 8}, love_timer = BREED_LOVE_DURATION, health = 6},
	)
	breed_pass(&w, &w.mobs, 0.016)
	found_baby := false
	for m in w.mobs do if m.is_baby do found_baby = true
	testing.expect(t, found_baby, "breeding still produces a baby even while the area is at the spawn cap")
}
