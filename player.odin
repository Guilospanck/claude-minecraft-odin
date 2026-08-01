package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "vendor:glfw"

Player :: struct {
	pos:       Vec3, // feet position (AABB min-y)
	vel:       Vec3,
	yaw:       f32,
	pitch:     f32,
	on_ground:  bool,
	in_water:   bool,
	fly:        bool,
	selected:   BlockId,
	step_accum: f32, // distance walked since the last footstep sound
	health:      int,
	hurt_timer:  f32, // brief invulnerability after taking damage
	safe_timer:  f32, // time since last damage (gates regen)
	regen_timer: f32, // accumulates toward the next regen tick
	fall_speed:  f32, // tracked while airborne for fall damage
	respawn:     Vec3,
	inventory:   [BlockId]int,
	hunger:      f32, // 0..HUNGER_MAX
	raw_food:     int, // raw meat dropped by mobs (weak)
	cooked_food:  int, // cooked in a furnace (restores more hunger)
	portal_timer: f32, // time stood in a portal (triggers dimension travel)
	lava_timer:   f32, // lava-damage tick
	starve:      f32, // starvation damage timer
}

HOTBAR := [9]BlockId {
	.Grass,
	.Dirt,
	.Stone,
	.Wood,
	.Sand,
	.Glass,
	.Furnace,
	.Iron,
	.Glowstone,
}

player_init :: proc(p: ^Player, pos: Vec3) {
	p.pos = pos
	p.vel = Vec3{0, 0, 0}
	p.yaw = 0
	p.pitch = -0.15
	p.on_ground = false
	p.fly = false
	p.selected = .Grass
	p.health = MAX_HEALTH
	p.hunger = HUNGER_MAX
	p.respawn = pos

	// starting kit so you can build right away; gather more by mining
	p.inventory[.Grass] = 32
	p.inventory[.Dirt] = 32
	p.inventory[.Stone] = 32
	p.inventory[.Wood] = 16
	p.inventory[.Sand] = 16
	p.inventory[.Glowstone] = 8
	p.inventory[.Furnace] = 2
	p.inventory[.Ore] = 6
	p.inventory[.Glass] = 8 // so every hotbar slot starts placeable
	p.inventory[.Iron] = 8
	p.inventory[.Obsidian] = 30 // enough to build a nether portal (press P)
}

// Apply damage with brief invulnerability + optional horizontal knockback.
player_damage :: proc(p: ^Player, amount: int, dir: Vec3) {
	if p.hurt_timer > 0 do return
	p.health -= amount
	p.hurt_timer = 0.5
	p.safe_timer = 0 // pause regen after taking a hit
	if dir.x != 0 || dir.z != 0 {
		p.vel.x += dir.x * 5
		p.vel.z += dir.z * 5
		if !p.fly do p.vel.y = 5
	}
	audio_play(.Hurt, 0.8)
	if p.health <= 0 {
		player_respawn(p)
	}
}

player_respawn :: proc(p: ^Player) {
	fmt.println("you died - respawning")
	p.pos = p.respawn
	p.vel = Vec3{0, 0, 0}
	p.health = MAX_HEALTH
	p.hunger = HUNGER_MAX
	p.starve = 0
	p.hurt_timer = 1.0
	p.fall_speed = 0
}

@(private = "file")
key_down :: proc(k: i32) -> bool {
	return glfw.GetKey(g_win, k) == glfw.PRESS
}

// Mouse-look, block selection, fly toggle, and desired horizontal velocity.
process_input :: proc(p: ^Player, dt: f32) {
	sens := g_settings.mouse_sens
	p.yaw += f32(g_input.dx) * sens
	p.pitch -= f32(g_input.dy) * sens
	LIMIT: f32 = 1.55
	p.pitch = clamp(p.pitch, -LIMIT, LIMIT)
	g_input.dx = 0
	g_input.dy = 0

	if g_input.fly_toggle {
		p.fly = !p.fly
		p.vel = Vec3{0, 0, 0}
		g_input.fly_toggle = false
	}
	if g_input.select > 0 {
		p.selected = HOTBAR[g_input.select - 1]
		fmt.println("selected:", block_name(p.selected), "x", p.inventory[p.selected])
		g_input.select = 0
	}

	fwd := Vec3{math.sin(p.yaw), 0, -math.cos(p.yaw)}
	right := Vec3{math.cos(p.yaw), 0, math.sin(p.yaw)}
	wish := Vec3{0, 0, 0}
	if key_down(glfw.KEY_W) do wish += fwd
	if key_down(glfw.KEY_S) do wish -= fwd
	if key_down(glfw.KEY_D) do wish += right
	if key_down(glfw.KEY_A) do wish -= right
	if wish.x != 0 || wish.z != 0 {
		wish = linalg.normalize(wish)
	}

	speed := p.fly ? f32(FLY_SPEED) : (p.in_water ? f32(WALK_SPEED) * 0.6 : f32(WALK_SPEED))
	p.vel.x = wish.x * speed
	p.vel.z = wish.z * speed

	if p.fly {
		vy: f32 = 0
		if key_down(glfw.KEY_SPACE) do vy += 1
		if key_down(glfw.KEY_LEFT_SHIFT) do vy -= 1
		p.vel.y = vy * f32(FLY_SPEED)
	} else if p.in_water {
		// swim: space rises, shift dives, otherwise gently sink (physics)
		if key_down(glfw.KEY_SPACE) do p.vel.y = 4.0
		if key_down(glfw.KEY_LEFT_SHIFT) do p.vel.y = -4.0
	} else if key_down(glfw.KEY_SPACE) && p.on_ground {
		p.vel.y = JUMP_SPEED
		audio_play(.Jump, 0.5)
	}
}

// Per-frame player upkeep: timers, health regen, footstep sounds.
player_tick :: proc(p: ^Player, dt: f32) {
	if p.hurt_timer > 0 do p.hurt_timer -= dt

	// hunger drains over time, faster while walking
	drain: f32 = 0.25
	if p.on_ground && !p.fly && (abs(p.vel.x) + abs(p.vel.z)) > 0.1 do drain += 0.30
	p.hunger -= drain * dt
	if p.hunger < 0 do p.hunger = 0

	// starve for damage when empty
	if p.hunger <= 0 {
		p.starve += dt
		if p.starve > 2.0 {
			player_damage(p, 1, Vec3{0, 0, 0})
			p.starve = 0
		}
	} else {
		p.starve = 0
	}

	// eat: prefer cooked (heals more) over raw
	if g_input.eat {
		if p.hunger < f32(HUNGER_MAX) {
			if p.cooked_food > 0 {
				p.cooked_food -= 1
				p.hunger = min(p.hunger + 8, f32(HUNGER_MAX))
				audio_play(.Place, 0.4)
				fmt.println("ate cooked food — hunger", int(p.hunger))
			} else if p.raw_food > 0 {
				p.raw_food -= 1
				p.hunger = min(p.hunger + 3, f32(HUNGER_MAX))
				audio_play(.Place, 0.4)
				fmt.println("ate raw food (cook it for more!) — hunger", int(p.hunger))
			}
		}
		g_input.eat = false
	}

	// regenerate 1 HP every 1.5s when unharmed for 4s and not too hungry
	p.safe_timer += dt
	if p.safe_timer > 4.0 && p.health < MAX_HEALTH && p.hunger > 6 {
		p.regen_timer += dt
		if p.regen_timer > 1.5 {
			p.health += 1
			p.hunger -= 0.5 // regen costs a little hunger
			p.regen_timer = 0
		}
	} else {
		p.regen_timer = 0
	}

	if p.on_ground && !p.fly {
		sp := math.sqrt(p.vel.x * p.vel.x + p.vel.z * p.vel.z)
		p.step_accum += sp * dt
		if p.step_accum > 2.2 {
			audio_play(.Step, 0.6)
			p.step_accum = 0
		}
	} else {
		p.step_accum = 0
	}
}

@(private = "file")
block_hits_player :: proc(p: ^Player, tx, ty, tz: int) -> bool {
	return(
		p.pos.x + PLAYER_HW > f32(tx) &&
		p.pos.x - PLAYER_HW < f32(tx + 1) &&
		p.pos.y + PLAYER_H > f32(ty) &&
		p.pos.y < f32(ty + 1) &&
		p.pos.z + PLAYER_HW > f32(tz) &&
		p.pos.z - PLAYER_HW < f32(tz + 1) \
	)
}

// Break (left click) / place (right click) against the block under the crosshair.
handle_break_place :: proc(w: ^World, p: ^Player) {
	if g_input.break_req || g_input.place_req {
		eye := p.pos + Vec3{0, EYE_HEIGHT, 0}
		dir := camera_front(p.yaw, p.pitch)
		hit := raycast(w, eye, dir, REACH)
		// Along-ray entry distance, consistent with mob_pick's ray_aabb t.
		block_dist := hit.hit ? hit.t : REACH

		if g_input.break_req {
			// A left click punches a mob if one is under the crosshair and
			// nearer than the targeted block; otherwise it breaks the block.
			mob_idx, mob_t := mob_pick(&w.mobs, eye, dir, REACH)
			if mob_idx >= 0 && mob_t <= block_dist {
				mob_hit(w, mob_idx, dir)
			} else if hit.hit {
				broken := world_block(w, hit.bx, hit.by, hit.bz)
				if broken != .Bedrock { // bedrock is unbreakable
					world_set_block(w, hit.bx, hit.by, hit.bz, .Air)
					net_send_edit(hit.bx, hit.by, hit.bz, .Air, w.dimension)
					particle_spawn_break(&w.particles, broken, hit.bx, hit.by, hit.bz)
					audio_play(.Break)
					item_spawn(
						&w.items,
						broken,
						Vec3{f32(hit.bx) + 0.5, f32(hit.by) + 0.3, f32(hit.bz) + 0.5},
					)
				}
			}
		}

		if g_input.place_req && hit.hit {
			tx := hit.bx + hit.nx
			ty := hit.by + hit.ny
			tz := hit.bz + hit.nz
			if ty >= 0 &&
			   ty < CHUNK_H &&
			   world_block(w, tx, ty, tz) == .Air &&
			   !block_hits_player(p, tx, ty, tz) &&
			   p.inventory[p.selected] > 0 {
				world_set_block(w, tx, ty, tz, p.selected)
				net_send_edit(tx, ty, tz, p.selected, w.dimension)
				p.inventory[p.selected] -= 1
				audio_play(.Place)
			}
		}
	}

	if g_input.craft {
		try_craft(p)
		g_input.craft = false
	}
	if g_input.smelt {
		try_smelt(w, p)
		g_input.smelt = false
	}

	g_input.break_req = false
	g_input.place_req = false
}

near_furnace :: proc(w: ^World, p: ^Player) -> bool {
	px := int(math.floor(p.pos.x))
	py := int(math.floor(p.pos.y))
	pz := int(math.floor(p.pos.z))
	for dy in -2 ..= 2 {
		for dz in -3 ..= 3 {
			for dx in -3 ..= 3 {
				if world_block(w, px + dx, py + dy, pz + dz) == .Furnace do return true
			}
		}
	}
	return false
}

// Smelting near a placed furnace: Wood is fuel; Ore -> Iron, Sand -> Glass.
try_smelt :: proc(w: ^World, p: ^Player) {
	if !near_furnace(w, p) {
		fmt.println("smelt: stand next to a placed Furnace")
		return
	}
	if p.inventory[.Wood] < 1 {
		fmt.println("smelt: need Wood as fuel")
		return
	}
	if p.raw_food >= 1 {
		p.inventory[.Wood] -= 1
		p.raw_food -= 1
		p.cooked_food += 1
		fmt.println("cooked food (1 Raw + 1 Wood) — cooked:", p.cooked_food)
		return
	}
	if p.inventory[.Ore] >= 1 {
		p.inventory[.Wood] -= 1
		p.inventory[.Ore] -= 1
		p.inventory[.Iron] += 1
		fmt.println("smelted Iron (1 Ore + 1 Wood) — now have", p.inventory[.Iron])
	} else if p.inventory[.Sand] >= 1 {
		p.inventory[.Wood] -= 1
		p.inventory[.Sand] -= 1
		p.inventory[.Glass] += 1
		fmt.println("smelted Glass (1 Sand + 1 Wood) — now have", p.inventory[.Glass])
	} else {
		fmt.println("smelt: need Ore or Sand")
	}
}

// Crafting (press C). Tries recipes in order and makes the first you can afford:
//   8 Stone            -> 1 Furnace
//   4 Sand + 1 Ore     -> 1 Glowstone
try_craft :: proc(p: ^Player) {
	if p.inventory[.Stone] >= 8 {
		p.inventory[.Stone] -= 8
		p.inventory[.Furnace] += 1
		fmt.println("crafted Furnace (8 Stone) — now have", p.inventory[.Furnace])
		return
	}
	if p.inventory[.Sand] >= 4 && p.inventory[.Ore] >= 1 {
		p.inventory[.Sand] -= 4
		p.inventory[.Ore] -= 1
		p.inventory[.Glowstone] += 1
		fmt.println("crafted Glowstone (4 Sand + 1 Ore) — now have", p.inventory[.Glowstone])
		return
	}
	fmt.println("craft: 8 Stone -> Furnace, or 4 Sand + 1 Ore -> Glowstone")
}
