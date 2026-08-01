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
	fly:        bool,
	selected:   BlockId,
	step_accum: f32, // distance walked since the last footstep sound
	health:     int,
	hurt_timer: f32, // brief invulnerability after taking damage
	fall_speed: f32, // tracked while airborne for fall damage
	respawn:    Vec3,
	inventory:  [BlockId]int,
}

HOTBAR := [9]BlockId {
	.Grass,
	.Dirt,
	.Stone,
	.Sand,
	.Wood,
	.Leaves,
	.Snow,
	.Water,
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
	p.respawn = pos

	// starting kit so you can build right away; gather more by mining
	p.inventory[.Grass] = 32
	p.inventory[.Dirt] = 32
	p.inventory[.Stone] = 32
	p.inventory[.Wood] = 16
	p.inventory[.Sand] = 16
	p.inventory[.Glowstone] = 8
}

// Apply damage with brief invulnerability + optional horizontal knockback.
player_damage :: proc(p: ^Player, amount: int, dir: Vec3) {
	if p.hurt_timer > 0 do return
	p.health -= amount
	p.hurt_timer = 0.5
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
	p.hurt_timer = 1.0
	p.fall_speed = 0
}

@(private = "file")
key_down :: proc(k: i32) -> bool {
	return glfw.GetKey(g_win, k) == glfw.PRESS
}

// Mouse-look, block selection, fly toggle, and desired horizontal velocity.
process_input :: proc(p: ^Player, dt: f32) {
	sens: f32 = 0.0022
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

	speed := p.fly ? f32(FLY_SPEED) : f32(WALK_SPEED)
	p.vel.x = wish.x * speed
	p.vel.z = wish.z * speed

	if p.fly {
		vy: f32 = 0
		if key_down(glfw.KEY_SPACE) do vy += 1
		if key_down(glfw.KEY_LEFT_SHIFT) do vy -= 1
		p.vel.y = vy * f32(FLY_SPEED)
	} else if key_down(glfw.KEY_SPACE) && p.on_ground {
		p.vel.y = JUMP_SPEED
		audio_play(.Jump, 0.5)
	}
}

// Per-frame player upkeep: invulnerability timer + footstep sounds.
player_tick :: proc(p: ^Player, dt: f32) {
	if p.hurt_timer > 0 do p.hurt_timer -= dt

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
				mob_hit(&w.mobs, mob_idx, dir)
			} else if hit.hit {
				broken := world_block(w, hit.bx, hit.by, hit.bz)
				if broken != .Bedrock { // bedrock is unbreakable
					world_set_block(w, hit.bx, hit.by, hit.bz, .Air)
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
				p.inventory[p.selected] -= 1
				audio_play(.Place)
			}
		}
	}

	if g_input.craft {
		try_craft(p)
		g_input.craft = false
	}

	g_input.break_req = false
	g_input.place_req = false
}

// Minimal crafting: press C to turn 4 Sand + 1 Ore into 1 Glowstone.
try_craft :: proc(p: ^Player) {
	if p.inventory[.Sand] >= 4 && p.inventory[.Ore] >= 1 {
		p.inventory[.Sand] -= 4
		p.inventory[.Ore] -= 1
		p.inventory[.Glowstone] += 1
		fmt.println("crafted Glowstone (4 Sand + 1 Ore) — now have", p.inventory[.Glowstone])
	} else {
		fmt.println("craft needs 4 Sand + 1 Ore; have", p.inventory[.Sand], "Sand,", p.inventory[.Ore], "Ore")
	}
}
