package main

import "core:fmt"

// Dropped block items: spawned when a block breaks, they fall with physics,
// bob/spin, and are collected when the player walks near.

Item :: struct {
	block:     BlockId,
	food:      bool, // dropped meat (goes to the food counter, not inventory)
	pos:       Vec3, // feet centre of a small AABB
	vel:       Vec3,
	spin:      f32,
	age:       f32,
	on_ground: bool,
}

ITEM_HW :: f32(0.15)
ITEM_H :: f32(0.3)
ITEM_PICKUP :: f32(1.3)
ITEM_LIFETIME :: f32(120.0)

item_spawn :: proc(items: ^[dynamic]Item, block: BlockId, pos: Vec3) {
	append(
		items,
		Item {
			block = block,
			pos = pos,
			vel = Vec3{rng_range(-1.5, 1.5), 3.0, rng_range(-1.5, 1.5)},
			spin = rng_range(0, 2 * 3.14159265),
		},
	)
}

item_spawn_food :: proc(items: ^[dynamic]Item, pos: Vec3) {
	append(
		items,
		Item {
			food = true,
			pos = pos + Vec3{0, 0.5, 0},
			vel = Vec3{rng_range(-1.5, 1.5), 2.5, rng_range(-1.5, 1.5)},
			spin = rng_range(0, 2 * 3.14159265),
		},
	)
}

// Physics + pickup for all items.
items_update :: proc(w: ^World, p: ^Player, items: ^[dynamic]Item, dt: f32) {
	i := 0
	for i < len(items^) {
		it := &items^[i]
		it.age += dt
		it.spin += dt * 2.0
		it.on_ground = body_physics(w, &it.pos, &it.vel, ITEM_HW, ITEM_H, dt)

		dx := it.pos.x - p.pos.x
		dy := it.pos.y - (p.pos.y + 0.9)
		dz := it.pos.z - p.pos.z
		if it.age > 0.4 && dx * dx + dy * dy + dz * dz < ITEM_PICKUP * ITEM_PICKUP {
			col: Vec3
			if it.food {
				inv_add(p, .RawFood, 1)
				col = Vec3{0.72, 0.28, 0.22}
				toast_show(fmt.tprintf("+1 RAW FOOD (%d)", inv_count(p, .RawFood)))
			} else {
				inv_add(p, it.block, 1)
				col = block_color(it.block)
				toast_show(fmt.tprintf("+1 %s (%d)", block_name(it.block), inv_count(p, it.block)), 1.2)
			}
			audio_play(.Pickup, 0.5)
			particle_spawn_eat(&w.particles, it.pos + Vec3{0, 0.2, 0}, col)
			items^[i] = items^[len(items^) - 1]
			pop(items)
			continue
		}
		if it.age > ITEM_LIFETIME {
			items^[i] = items^[len(items^) - 1]
			pop(items)
			continue
		}
		i += 1
	}
}
