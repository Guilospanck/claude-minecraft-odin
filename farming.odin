package main

import "core:fmt"

// Farming: till dirt/grass into Farmland, plant seeds, watch wheat grow through
// three stages, then harvest for wheat (bake into bread) and more seeds.

GROW_TIME :: f32(8.0) // seconds a crop spends in each of its first two stages

Crop :: struct {
	pos:   Ivec3,
	timer: f32,
}

// Advance tracked crops. A crop leaves the list once it ripens (Wheat3) or its
// block disappears (harvested, broken, or its chunk unloaded).
crops_tick :: proc(w: ^World, dt: f32) {
	i := 0
	for i < len(w.crops) {
		cr := &w.crops[i]
		b := world_block(w, cr.pos.x, cr.pos.y, cr.pos.z)
		// drop crops that are gone (harvested/broken/unloaded) or already ripe
		if !block_is_crop(b) || block_is_ripe(b) {
			w.crops[i] = w.crops[len(w.crops) - 1]
			pop(&w.crops)
			continue
		}
		cr.timer += dt
		if cr.timer >= GROW_TIME {
			cr.timer = 0
			next := crop_next_stage(b)
			world_set_block(w, cr.pos.x, cr.pos.y, cr.pos.z, next)
			if block_is_ripe(next) { 	// ripened this tick — stop tracking it
				w.crops[i] = w.crops[len(w.crops) - 1]
				pop(&w.crops)
				continue
			}
		}
		i += 1
	}
}

// Drop a position from the growth list (called whenever a crop block is cleared)
// so a break+replant in the same spot can't leave a stale double-counted entry.
crop_forget :: proc(w: ^World, pos: Ivec3) {
	for i in 0 ..< len(w.crops) {
		if w.crops[i].pos == pos {
			w.crops[i] = w.crops[len(w.crops) - 1]
			pop(&w.crops)
			return
		}
	}
}

// Harvest a ripe crop. Wheat yields wheat + a seed or two; carrots yield a few
// carrots (which double as the replant "seed"). Either way the block clears and
// higher Farming levels sometimes add a bonus.
harvest_crop :: proc(w: ^World, p: ^Player, x, y, z: int) {
	ripe := world_block(w, x, y, z)
	world_set_block(w, x, y, z, .Air)
	crop_forget(w, Ivec3{x, y, z})
	net_send_edit(x, y, z, .Air, w.dimension)
	skill_gain(p, .Farming, 5)
	bonus := rng_int(100) < p.skill_level[.Farming] * 6
	msg: string
	if ripe == .CarrotCrop3 {
		n := 2 + rng_int(2) + (bonus ? 1 : 0)
		inv_add(p, .Carrot, n)
		msg = fmt.tprintf("HARVESTED CARROTS (%d CARROTS)", inv_count(p, .Carrot))
	} else {
		inv_add(p, .Wheat, 1 + (bonus ? 1 : 0))
		inv_add(p, .Seeds, 1 + rng_int(2))
		msg = fmt.tprintf("HARVESTED WHEAT (%d WHEAT, %d SEEDS)", inv_count(p, .Wheat), inv_count(p, .Seeds))
	}
	audio_play(.Break, 0.6)
	fmt.println(msg)
	toast_show(msg)
}

// R "use" key: context action on the block (or feedable mob) under the
// crosshair. A targetable mob always takes priority over the block behind it.
try_interact :: proc(w: ^World, p: ^Player) {
	eye := p.pos + Vec3{0, EYE_HEIGHT, 0}
	dir := camera_front(p.yaw, p.pitch)

	mob_idx, _ := mob_pick(&w.mobs, eye, dir, REACH)
	if mob_idx >= 0 {
		m := &w.mobs[mob_idx]
		if try_feed(w, p, m) do return
		toast_show(mob_kind_label(m.kind)) // hostile/aquatic: at least say what it is
		return
	}

	v_idx, _ := villager_pick(&w.villagers, eye, dir, REACH)
	if v_idx >= 0 {
		v := &w.villagers[v_idx]
		if v.is_trader {
			trader_interact(p, v)
		} else {
			try_talk_to_villager(v)
		}
		return
	}

	hit := raycast(w, eye, dir, REACH)
	if !hit.hit do return
	tb := world_block(w, hit.bx, hit.by, hit.bz)

	#partial switch tb {
	case .Chest:
		chest_open(w, Ivec3{hit.bx, hit.by, hit.bz})
	case .Bed:
		try_sleep(w, p)
	case .Door:
		door_toggle(w, Ivec3{hit.bx, hit.by, hit.bz})
	case .Stair:
		// rotate the stair's facing (0->1->2->3->0) and remesh the chunk
		key := Ivec3{hit.bx, hit.by, hit.bz}
		w.stairs[key] = (w.stairs[key] + 1) % 4
		world_set_block(w, hit.bx, hit.by, hit.bz, .Stair) // re-set to mark dirty
		audio_play(.Place, 0.4)
		toast_show("ROTATED STAIR")
	case .Campfire:
		n := inv_count(p, .RawFood)
		if n > 0 {
			inv_take(p, .RawFood, n)
			inv_add(p, .CookedFood, n)
			audio_play(.Eat, 0.5)
			toast_show(fmt.tprintf("COOKED %d RAW FOOD ON THE CAMPFIRE", n))
		} else {
			toast_show("CAMPFIRE - HOLD RAW FOOD (R) TO COOK IT")
		}
	case .Wheat3, .CarrotCrop3:
		harvest_crop(w, p, hit.bx, hit.by, hit.bz)
	case .Farmland:
		ax, ay, az := hit.bx, hit.by + 1, hit.bz
		if ay >= CHUNK_H || world_block(w, ax, ay, az) != .Air {
			return
		}
		// Hold a carrot to plant carrots; otherwise plant wheat from seeds.
		if inv_selected(p) == .Carrot && inv_has(p, .Carrot, 1) {
			world_set_block(w, ax, ay, az, .CarrotCrop1)
			net_send_edit(ax, ay, az, .CarrotCrop1, w.dimension)
			append(&w.crops, Crop{pos = Ivec3{ax, ay, az}})
			inv_take(p, .Carrot, 1)
			audio_play(.Place, 0.4)
			toast_show(fmt.tprintf("PLANTED CARROTS (%d CARROTS LEFT)", inv_count(p, .Carrot)))
			return
		}
		if !inv_has(p, .Seeds, 1) {
			toast_show("NO SEEDS - BREAK GRASS TO FIND SOME")
			return
		}
		world_set_block(w, ax, ay, az, .Wheat1)
		net_send_edit(ax, ay, az, .Wheat1, w.dimension)
		append(&w.crops, Crop{pos = Ivec3{ax, ay, az}})
		inv_take(p, .Seeds, 1)
		audio_play(.Place, 0.4)
		toast_show(fmt.tprintf("PLANTED WHEAT (%d SEEDS LEFT)", inv_count(p, .Seeds)))
	case .Grass, .Dirt:
		if world_block(w, hit.bx, hit.by + 1, hit.bz) != .Air do return
		world_set_block(w, hit.bx, hit.by, hit.bz, .Farmland)
		net_send_edit(hit.bx, hit.by, hit.bz, .Farmland, w.dimension)
		audio_play(.Place, 0.4)
		toast_show("TILLED FARMLAND - PRESS R TO PLANT")
	}
}

// Sleep in a bed (overworld only): set spawn point and, at night, skip to dawn.
try_sleep :: proc(w: ^World, p: ^Player) {
	if w.dimension != .Overworld {
		toast_show("YOU CANT SLEEP HERE")
		return
	}
	p.respawn = p.pos
	if is_night(w.time_of_day) {
		w.time_of_day = 0.28 // early morning
		p.safe_timer = 10 // let health regen resume after resting
		toast_show("GOOD MORNING - SPAWN POINT SET")
	} else {
		toast_show("SPAWN POINT SET")
	}
	audio_play(.Place, 0.5)
}
