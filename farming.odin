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
		if !block_is_crop(b) || b == .Wheat3 {
			w.crops[i] = w.crops[len(w.crops) - 1]
			pop(&w.crops)
			continue
		}
		cr.timer += dt
		if cr.timer >= GROW_TIME {
			cr.timer = 0
			next: BlockId = b == .Wheat1 ? .Wheat2 : .Wheat3
			world_set_block(w, cr.pos.x, cr.pos.y, cr.pos.z, next)
			if next == .Wheat3 { 	// ripened this tick — stop tracking it
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

// Harvest a ripe crop: wheat + a seed or two back, and the block clears.
harvest_crop :: proc(w: ^World, p: ^Player, x, y, z: int) {
	world_set_block(w, x, y, z, .Air)
	crop_forget(w, Ivec3{x, y, z})
	net_send_edit(x, y, z, .Air, w.dimension)
	p.wheat += 1
	p.seeds += 1 + rng_int(2)
	audio_play(.Break, 0.6)
	fmt.println("harvested wheat —", p.wheat, "wheat,", p.seeds, "seeds")
}

// R "use" key: context action on the block under the crosshair.
try_interact :: proc(w: ^World, p: ^Player) {
	eye := p.pos + Vec3{0, EYE_HEIGHT, 0}
	dir := camera_front(p.yaw, p.pitch)
	hit := raycast(w, eye, dir, REACH)
	if !hit.hit do return
	tb := world_block(w, hit.bx, hit.by, hit.bz)

	#partial switch tb {
	case .Chest:
		chest_open(w, Ivec3{hit.bx, hit.by, hit.bz})
	case .Bed:
		try_sleep(w, p)
	case .Wheat3:
		harvest_crop(w, p, hit.bx, hit.by, hit.bz)
	case .Farmland:
		ax, ay, az := hit.bx, hit.by + 1, hit.bz
		if ay >= CHUNK_H || world_block(w, ax, ay, az) != .Air {
			return
		}
		if p.seeds <= 0 {
			fmt.println("no seeds — break grass to find some")
			return
		}
		world_set_block(w, ax, ay, az, .Wheat1)
		net_send_edit(ax, ay, az, .Wheat1, w.dimension)
		append(&w.crops, Crop{pos = Ivec3{ax, ay, az}})
		p.seeds -= 1
		audio_play(.Place, 0.4)
		fmt.println("planted wheat —", p.seeds, "seeds left")
	case .Grass, .Dirt:
		if world_block(w, hit.bx, hit.by + 1, hit.bz) != .Air do return
		world_set_block(w, hit.bx, hit.by, hit.bz, .Farmland)
		net_send_edit(hit.bx, hit.by, hit.bz, .Farmland, w.dimension)
		audio_play(.Place, 0.4)
		fmt.println("tilled farmland — plant seeds with R")
	}
}

// Sleep in a bed (overworld only): set spawn point and, at night, skip to dawn.
try_sleep :: proc(w: ^World, p: ^Player) {
	if w.dimension != .Overworld {
		fmt.println("you can't sleep here")
		return
	}
	p.respawn = p.pos
	if is_night(w.time_of_day) {
		w.time_of_day = 0.28 // early morning
		p.safe_timer = 10 // let health regen resume after resting
		fmt.println("*yawn* good morning — spawn point set")
	} else {
		fmt.println("spawn point set (sleep at night to skip to morning)")
	}
}
