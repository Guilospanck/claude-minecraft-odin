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
	seeds:        int, // plant on farmland
	wheat:        int, // harvested crop; bake into bread
	bread:        int, // baked food (restores a good chunk of hunger)
	portal_timer: f32, // time stood in a portal (triggers dimension travel)
	lava_timer:   f32, // lava-damage tick
	starve:      f32, // starvation damage timer
	oxygen:      f32, // air remaining while underwater (OXYGEN_MAX..0)
	drown_timer: f32, // drowning-damage tick once oxygen is empty
	tool_tier:   [ToolKind]int, // 0 = not owned, 1=Wood 2=Stone 3=Iron
	tool_dur:    [ToolKind]int, // remaining durability for each tool
	mine_active: bool, // currently mining a block (LMB held)
	mine_x, mine_y, mine_z: int, // the block being mined
	mine_progress: f32, // seconds accumulated toward breaking it
	mine_frac:   f32, // 0..1 progress, for the HUD bar
	place_cd:    f32, // throttle for held-right-button drag-placing
	eat_timer:   f32, // counts down from EAT_ANIM_DURATION; drives the eat bob/crumbs
}

HOTBAR := [9]BlockId {
	.Grass,
	.Dirt,
	.Stone,
	.Wood,
	.Sand,
	.Torch,
	.Bed,
	.Chest,
	.Furnace,
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
	p.oxygen = OXYGEN_MAX
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
	p.inventory[.Torch] = 16
	p.inventory[.Bed] = 1
	p.inventory[.Chest] = 2
	p.seeds = 8 // enough to start a small farm (R to till/plant)

	// starting tools: a wooden pickaxe and sword (upgrade in the tools menu, X)
	p.tool_tier[.Pickaxe] = 1
	p.tool_dur[.Pickaxe] = TOOL_DUR[1]
	p.tool_tier[.Sword] = 1
	p.tool_dur[.Sword] = TOOL_DUR[1]
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
	toast_show("YOU DIED - RESPAWNING", 3.0)
	p.pos = p.respawn
	p.vel = Vec3{0, 0, 0}
	p.health = MAX_HEALTH
	p.hunger = HUNGER_MAX
	p.oxygen = OXYGEN_MAX
	p.drown_timer = 0
	p.starve = 0
	p.hurt_timer = 1.0
	p.fall_speed = 0
}

// Is the player's head (eye level) inside a water block?
player_head_submerged :: proc(w: ^World, pos: Vec3) -> bool {
	x := int(math.floor(pos.x))
	z := int(math.floor(pos.z))
	return world_block(w, x, int(math.floor(pos.y + EYE_HEIGHT)), z) == .Water
}

// Drain air while the head is underwater; once empty, take drowning damage.
// Air refills quickly at the surface.
player_oxygen_tick :: proc(w: ^World, p: ^Player, dt: f32) {
	if player_head_submerged(w, p.pos) {
		p.oxygen -= dt
		if p.oxygen <= 0 {
			p.oxygen = 0
			p.drown_timer += dt
			if p.drown_timer >= 1.0 {
				player_damage(p, 2, Vec3{0, 0, 0})
				p.drown_timer = 0
			}
		}
	} else {
		p.oxygen = min(p.oxygen + dt * 4, OXYGEN_MAX)
		p.drown_timer = 0
	}
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
player_tick :: proc(w: ^World, p: ^Player, dt: f32) {
	if p.hurt_timer > 0 do p.hurt_timer -= dt
	if p.eat_timer > 0 {
		p.eat_timer -= dt
		if p.eat_timer < 0 do p.eat_timer = 0
	}

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

	// eat: prefer cooked meat (+8), then bread (+6), then raw meat (+3)
	if g_input.eat {
		if p.hunger < f32(HUNGER_MAX) {
			ate := true
			food_col := Vec3{0.72, 0.28, 0.22}
			if p.cooked_food > 0 {
				p.cooked_food -= 1
				p.hunger = min(p.hunger + 8, f32(HUNGER_MAX))
				food_col = Vec3{0.55, 0.35, 0.2}
				toast_show(fmt.tprintf("ATE COOKED FOOD (HUNGER %d)", int(p.hunger)))
			} else if p.bread > 0 {
				p.bread -= 1
				p.hunger = min(p.hunger + 6, f32(HUNGER_MAX))
				food_col = Vec3{0.78, 0.58, 0.30}
				toast_show(fmt.tprintf("ATE BREAD (HUNGER %d)", int(p.hunger)))
			} else if p.raw_food > 0 {
				p.raw_food -= 1
				p.hunger = min(p.hunger + 3, f32(HUNGER_MAX))
				toast_show(fmt.tprintf("ATE RAW FOOD - COOK IT FOR MORE (HUNGER %d)", int(p.hunger)))
			} else {
				ate = false
			}
			if ate {
				audio_play(.Eat, 0.6)
				p.eat_timer = EAT_ANIM_DURATION
				mouth := p.pos + Vec3{0, EYE_HEIGHT * 0.85, 0} + camera_front(p.yaw, 0) * 0.4
				particle_spawn_eat(&w.particles, mouth, food_col)
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

@(private = "file")
mine_reset :: proc(p: ^Player) {
	p.mine_active = false
	p.mine_progress = 0
	p.mine_frac = 0
}

// Actually break a block: harvest crops, else drop it, spend tool durability.
@(private = "file")
break_block :: proc(w: ^World, p: ^Player, bx, by, bz: int, broken: BlockId) {
	if block_is_crop(broken) {
		world_set_block(w, bx, by, bz, .Air)
		crop_forget(w, Ivec3{bx, by, bz})
		net_send_edit(bx, by, bz, .Air, w.dimension)
		audio_play(.Break)
		p.seeds += 1
		if broken == .Wheat3 do p.wheat += 1
		return
	}
	if broken == .Chest do chest_break(w, p, Ivec3{bx, by, bz}) // recover contents first
	world_set_block(w, bx, by, bz, .Air)
	net_send_edit(bx, by, bz, .Air, w.dimension)
	particle_spawn_break(&w.particles, broken, bx, by, bz)
	audio_play(.Break)
	item_spawn(&w.items, broken, Vec3{f32(bx) + 0.5, f32(by) + 0.3, f32(bz) + 0.5})
	if broken == .Grass && rng_int(4) == 0 do p.seeds += 1 // seeds hide in grass
	if kind, applies := mine_tool(broken); applies do tool_wear(p, kind)
}

// Mine (hold left) / punch mobs (left click) / place (right click) against the
// block under the crosshair.
handle_break_place :: proc(w: ^World, p: ^Player, dt: f32) {
	eye := p.pos + Vec3{0, EYE_HEIGHT, 0}
	dir := camera_front(p.yaw, p.pitch)
	hit := raycast(w, eye, dir, REACH)
	block_dist := hit.hit ? hit.t : REACH // along-ray t, matches mob_pick

	// A left click punches a mob under the crosshair (nearer than any block).
	if g_input.break_req {
		mob_idx, mob_t := mob_pick(&w.mobs, eye, dir, REACH)
		if mob_idx >= 0 && mob_t <= block_dist {
			mob_hit(w, mob_idx, dir, 3 + sword_bonus(p))
			tool_wear(p, .Sword)
			mine_reset(p)
		}
	}

	// Hold the left button to mine the targeted block over time.
	mining :=
		g_win != nil &&
		glfw.GetMouseButton(g_win, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS &&
		hit.hit
	if mining {
		broken := world_block(w, hit.bx, hit.by, hit.bz)
		if broken == .Bedrock || broken == .Portal || broken == .Air {
			mine_reset(p) // unbreakable / nothing there
		} else {
			if !(p.mine_active && p.mine_x == hit.bx && p.mine_y == hit.by && p.mine_z == hit.bz) {
				p.mine_active = true
				p.mine_x, p.mine_y, p.mine_z = hit.bx, hit.by, hit.bz
				p.mine_progress = 0
			}
			if !can_mine(p, broken) {
				p.mine_progress = 0 // e.g. obsidian needs an iron pickaxe
				p.mine_frac = 0
			} else {
				p.mine_progress += dt
				need := mining_time(p, broken)
				p.mine_frac = clamp(p.mine_progress / max(need, 0.0001), 0, 1)
				if p.mine_progress >= need {
					break_block(w, p, hit.bx, hit.by, hit.bz, broken)
					mine_reset(p)
				}
			}
		}
	} else {
		mine_reset(p)
	}

	// Place: the one-shot request (right-click / Q / ctrl-click) fires immediately;
	// holding the right button drag-places on a short cooldown. Polling the button
	// directly is more robust than relying only on the press callback.
	if p.place_cd > 0 do p.place_cd -= dt
	right_held :=
		g_win != nil && glfw.GetMouseButton(g_win, glfw.MOUSE_BUTTON_RIGHT) == glfw.PRESS
	want_place := g_input.place_req || (right_held && p.place_cd <= 0)
	if want_place && hit.hit {
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
			p.place_cd = 0.22
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
		toast_show("SMELT: STAND NEXT TO A FURNACE")
		return
	}
	if p.inventory[.Wood] < 1 {
		toast_show("SMELT: NEED WOOD AS FUEL")
		return
	}
	if p.raw_food >= 1 {
		p.inventory[.Wood] -= 1
		p.raw_food -= 1
		p.cooked_food += 1
		toast_show(fmt.tprintf("COOKED FOOD (HAVE %d)", p.cooked_food))
		return
	}
	if p.inventory[.Ore] >= 1 {
		p.inventory[.Wood] -= 1
		p.inventory[.Ore] -= 1
		p.inventory[.Iron] += 1
		toast_show(fmt.tprintf("SMELTED IRON (HAVE %d)", p.inventory[.Iron]))
	} else if p.inventory[.Sand] >= 1 {
		p.inventory[.Wood] -= 1
		p.inventory[.Sand] -= 1
		p.inventory[.Glass] += 1
		toast_show(fmt.tprintf("SMELTED GLASS (HAVE %d)", p.inventory[.Glass]))
	} else {
		toast_show("SMELT: NEED ORE OR SAND")
	}
}

// Crafting (press C). Tries recipes in order and makes the first you can afford:
//   8 Stone            -> 1 Furnace
//   4 Sand + 1 Ore     -> 1 Glowstone
try_craft :: proc(p: ^Player) {
	if p.inventory[.Stone] >= 8 {
		p.inventory[.Stone] -= 8
		p.inventory[.Furnace] += 1
		toast_show(fmt.tprintf("CRAFTED FURNACE (HAVE %d)", p.inventory[.Furnace]))
		return
	}
	if p.inventory[.Sand] >= 4 && p.inventory[.Ore] >= 1 {
		p.inventory[.Sand] -= 4
		p.inventory[.Ore] -= 1
		p.inventory[.Glowstone] += 1
		toast_show(fmt.tprintf("CRAFTED GLOWSTONE (HAVE %d)", p.inventory[.Glowstone]))
		return
	}
	if p.wheat >= 3 {
		p.wheat -= 3
		p.bread += 1
		toast_show(fmt.tprintf("BAKED BREAD (HAVE %d)", p.bread))
		return
	}
	toast_show("CRAFT: 8 STONE, 4 SAND+1 ORE, OR 3 WHEAT")
}
