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
	on_ground: bool,
	fly:       bool,
	selected:  BlockId,
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
	.Ore,
}

player_init :: proc(p: ^Player, pos: Vec3) {
	p.pos = pos
	p.vel = Vec3{0, 0, 0}
	p.yaw = 0
	p.pitch = -0.15
	p.on_ground = false
	p.fly = false
	p.selected = .Grass
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
		fmt.println("selected:", block_name(p.selected))
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
		block_dist :=
			hit.hit \
			? linalg.length(Vec3{f32(hit.bx) + 0.5, f32(hit.by) + 0.5, f32(hit.bz) + 0.5} - eye) \
			: REACH

		if g_input.break_req {
			// A left click punches a mob if one is under the crosshair and
			// nearer than the targeted block; otherwise it breaks the block.
			mob_idx, mob_t := mob_pick(&w.mobs, eye, dir, REACH)
			if mob_idx >= 0 && mob_t <= block_dist {
				mob_hit(&w.mobs, mob_idx, dir)
			} else if hit.hit {
				world_set_block(w, hit.bx, hit.by, hit.bz, .Air)
			}
		}

		if g_input.place_req && hit.hit {
			tx := hit.bx + hit.nx
			ty := hit.by + hit.ny
			tz := hit.bz + hit.nz
			if ty >= 0 &&
			   ty < CHUNK_H &&
			   world_block(w, tx, ty, tz) == .Air &&
			   !block_hits_player(p, tx, ty, tz) {
				world_set_block(w, tx, ty, tz, p.selected)
			}
		}
	}
	g_input.break_req = false
	g_input.place_req = false
}
