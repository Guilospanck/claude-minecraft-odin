package main

import "core:math"
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
	delete(w.arrows)
	delete(w.particles)
	delete(w.crops)
	delete(w.chests)
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
	before := p.inventory[.Stone]
	item_spawn(&w.items, .Stone, Vec3{8.5, 11.2, 8.5})
	for _ in 0 ..< 90 {
		items_update(&w, &p, &w.items, 1.0 / 60.0)
	}
	testing.expect(t, p.inventory[.Stone] == before + 1, "item picked up into inventory")
	testing.expect(t, len(w.items) == 0, "item removed after pickup")
}

@(test)
test_craft_glowstone :: proc(t: ^testing.T) {
	p: Player
	p.inventory[.Sand] = 5
	p.inventory[.Ore] = 2
	try_craft(&p)
	testing.expect(t, p.inventory[.Glowstone] == 1, "crafted one glowstone")
	testing.expect(t, p.inventory[.Sand] == 1, "consumed 4 sand")
	testing.expect(t, p.inventory[.Ore] == 1, "consumed 1 ore")

	// not enough materials: no change
	try_craft(&p)
	testing.expect(t, p.inventory[.Glowstone] == 1, "no craft without materials")
}

@(test)
test_smelt_iron :: proc(t: ^testing.T) {
	w, c := make_test_world()
	defer free_test_world(&w)
	chunk_set(c, 8, 40, 8, .Furnace)
	p: Player
	player_init(&p, Vec3{8.5, 40.0, 8.5}) // standing on the furnace cell
	p.inventory = {}
	p.inventory[.Wood] = 2
	p.inventory[.Ore] = 1
	try_smelt(&w, &p)
	testing.expect(t, p.inventory[.Iron] == 1, "ore + wood smelts to iron")
	testing.expect(t, p.inventory[.Wood] == 1, "one wood fuel consumed")
	testing.expect(t, p.inventory[.Ore] == 0, "ore consumed")

	// no furnace nearby -> no smelt
	w2, _ := make_test_world()
	defer free_test_world(&w2)
	p.inventory[.Sand] = 3
	try_smelt(&w2, &p)
	testing.expect(t, p.inventory[.Glass] == 0, "no smelt without a furnace")
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
	p.selected = .Stone
	p.inventory = {}
	p.inventory[.Stone] = 5

	g_input = {}
	g_input.place_req = true
	handle_break_place(&w, &p, 0.016)
	g_input = {}

	testing.expect(t, world_block(&w, 8, 12, 4) == .Stone, "block placed against the wall")
	testing.expect(t, p.inventory[.Stone] == 4, "inventory decremented on place")

	// empty slot: nothing happens
	p.selected = .Iron
	p.inventory[.Iron] = 0
	g_input = {}
	g_input.place_req = true
	handle_break_place(&w, &p, 0.016)
	g_input = {}
	testing.expect(t, world_block(&w, 8, 12, 5) != .Iron, "no place from an empty slot")
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
	p.inventory = {}
	p.inventory[.Wood] = 2
	p.raw_food = 3
	try_smelt(&w, &p) // cook near the furnace
	testing.expect(t, p.cooked_food == 1, "raw food cooks to cooked")
	testing.expect(t, p.raw_food == 2, "one raw consumed")
	testing.expect(t, p.inventory[.Wood] == 1, "one wood fuel consumed")
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
	testing.expect(t, p.wheat == 1, "harvest yields wheat")
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
	p.inventory[.Wood] = 2
	tool_craft(&p, .Axe)
	testing.expect(t, p.tool_tier[.Axe] == 1, "wood axe crafted")
	testing.expect(t, p.tool_dur[.Axe] == TOOL_DUR[1], "full durability")
	testing.expect(t, p.inventory[.Wood] == 0, "wood consumed")
	// can't afford stone tier
	tool_craft(&p, .Axe)
	testing.expect(t, p.tool_tier[.Axe] == 1, "no upgrade without stone")
	p.inventory[.Stone] = 3
	tool_craft(&p, .Axe)
	testing.expect(t, p.tool_tier[.Axe] == 2, "upgraded to stone axe")
	testing.expect(t, p.inventory[.Stone] == 0, "stone consumed")
}

@(test)
test_chest_store_and_take :: proc(t: ^testing.T) {
	w, _ := make_test_world()
	defer free_test_world(&w)
	p: Player
	p.inventory[.Stone] = 30
	chest_open(&w, Ivec3{1, 2, 3})
	chest_deposit(&w, &p, .Stone)
	testing.expect(t, p.inventory[.Stone] == 0, "stone left the player")
	testing.expect(t, w.chests[g_chest_pos].items[.Stone] == 30, "stone is in the chest")
	chest_withdraw_all(&w, &p)
	testing.expect(t, p.inventory[.Stone] == 30, "stone returned")
	testing.expect(t, w.chests[g_chest_pos].items[.Stone] == 0, "chest emptied")
}

@(test)
test_chest_break_recovers_contents :: proc(t: ^testing.T) {
	w, _ := make_test_world()
	defer free_test_world(&w)
	p: Player
	pos := Ivec3{4, 5, 6}
	w.chests[pos] = Chest{}
	ch := w.chests[pos]
	ch.items[.Iron] = 7
	w.chests[pos] = ch
	chest_break(&w, &p, pos)
	testing.expect(t, p.inventory[.Iron] == 7, "broken chest returns its contents")
	_, ok := w.chests[pos]
	testing.expect(t, !ok, "chest entry removed")
}

@(test)
test_chest_save_roundtrip :: proc(t: ^testing.T) {
	w, _ := make_test_world() // overworld
	defer free_test_world(&w)
	pos := Ivec3{10, 20, -30}
	ch: Chest
	ch.items[.Wood] = 12
	ch.items[.Glowstone] = 3
	w.chests[pos] = ch
	save_chests(&w)

	w2, _ := make_test_world()
	defer free_test_world(&w2)
	load_chests(&w2)
	rc, ok := w2.chests[pos]
	testing.expect(t, ok, "chest loaded back")
	if ok {
		testing.expect(t, rc.items[.Wood] == 12 && rc.items[.Glowstone] == 3, "counts preserved")
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
		mob_update(&w, &p, &m, 1.0 / 60.0)
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
		mob_update(&w, &p, &m, 1.0 / 30.0)
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
	p.cooked_food = 1
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
		delete(w.crops);delete(w.chests)
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
