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
	selected_slot: int, // which hotbar slot (0..8) is equipped
	step_accum: f32, // distance walked since the last footstep sound
	health:      int,
	hurt_timer:  f32, // brief invulnerability after taking damage
	safe_timer:  f32, // time since last damage (gates regen)
	regen_timer: f32, // accumulates toward the next regen tick
	fall_speed:  f32, // tracked while airborne for fall damage
	respawn:     Vec3,
	hunger:      f32, // 0..HUNGER_MAX
	portal_timer: f32, // time stood in a portal (triggers dimension travel)
	lava_timer:   f32, // lava-damage tick
	starve:      f32, // starvation damage timer
	oxygen:      f32, // air remaining while underwater (OXYGEN_MAX..0)
	drown_timer: f32, // drowning-damage tick once oxygen is empty
	tool_tier:   [ToolKind]int, // 0 = not owned, 1=Wood 2=Stone 3=Iron
	tool_dur:    [ToolKind]int, // remaining durability for each tool
	held_tool:   ToolKind, // which tool is in hand (cycle with H): drives mining + melee
	tool_mode:   bool, // true = brandishing the tool (shown in hand, no block placing); false = holding the hotbar block
	armor_tier:  [ArmorSlot]int, // 0 = not owned, 1=Wood 2=Stone 3=Iron
	armor_dur:   [ArmorSlot]int, // remaining durability for each armor piece
	mine_active: bool, // currently mining a block (LMB held)
	mine_x, mine_y, mine_z: int, // the block being mined
	mine_progress: f32, // seconds accumulated toward breaking it
	mine_frac:   f32, // 0..1 progress, for the HUD bar
	place_cd:    f32, // throttle for held-right-button drag-placing
	eat_timer:   f32, // counts down from EAT_ANIM_DURATION; drives the eat bob/crumbs
	swing_timer: f32, // counts down from SWING_DURATION; drives the held-item swing
	attack_cd:   f32, // counts down from ATTACK_CD_MAX; a fresh swing hits weak until it recharges
	sprinting:   bool, // running (Ctrl or double-tap W); faster + widens FOV
	fov_kick:    f32, // 0..1 eased sprint FOV widen, for a smooth zoom in/out
	bob_phase:   f32, // advances while walking; drives the camera head-bob
	bob_amp:     f32, // 0..1 eased bob strength (fades in/out as you start/stop)
	sneaking:    bool, // crouching (hold Shift on ground): slow, low, won't walk off ledges
	crouch:      f32, // 0..1 eased crouch amount, for a smooth camera dip
	xp_level:    int, // current experience level (from absorbed XP orbs)
	xp_points:   int, // experience banked toward the next level (see xp_need)
	w_was_down:  bool, // previous-frame W state, for double-tap detection
	w_tap_timer: f32, // >0 during the window a second W press counts as a double-tap
	slots:       [INV_SLOTS]ItemStack, // fixed-slot inventory (0..8 hotbar, 9.. storage)
}

// The starting loadout, laid out into fixed slots: a ready-to-build hotbar row
// (slots 0..8) plus some materials in storage (slots 9..).
STARTER_KIT := [?]ItemStack {
	{.Grass, 32},
	{.Dirt, 32},
	{.Stone, 32},
	{.Wood, 16},
	{.Sand, 16},
	{.Torch, 16},
	{.Glass, 8},
	{.Bed, 1},
	{.Chest, 2},
	// storage row
	{.Glowstone, 8},
	{.Furnace, 2},
	{.Ore, 6},
	{.Iron, 8},
	{.Obsidian, 30}, // enough to build a nether portal (press P)
	{.Seeds, 8}, // enough to start a small farm (R to till/plant)
}

player_init :: proc(p: ^Player, pos: Vec3) {
	p.pos = pos
	p.vel = Vec3{0, 0, 0}
	p.yaw = 0
	p.pitch = -0.15
	p.on_ground = false
	p.fly = false
	p.selected_slot = 0
	p.health = MAX_HEALTH
	p.hunger = HUNGER_MAX
	p.oxygen = OXYGEN_MAX
	p.respawn = pos

	// starting kit so you can build right away; gather more by mining
	p.slots = {}
	for s, i in STARTER_KIT do p.slots[i] = s

	// starting tools: a wooden pickaxe and sword (upgrade in the tools menu, X)
	p.tool_tier[.Pickaxe] = 1
	p.tool_dur[.Pickaxe] = TOOL_DUR[1]
	p.tool_tier[.Sword] = 1
	p.tool_dur[.Sword] = TOOL_DUR[1]
}

// Apply damage with brief invulnerability + optional horizontal knockback.
// Worn armor reduces the amount (see armor_reduction) and wears by one point.
player_damage :: proc(p: ^Player, amount: int, dir: Vec3) {
	if p.hurt_timer > 0 do return
	reduced := int(f32(amount) * (1.0 - armor_reduction(p)) + 0.5)
	if reduced < 1 && amount > 0 do reduced = 1 // armor can soften a hit, never fully negate it
	if armor_points(p) > 0 do armor_wear(p)
	p.health -= reduced
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

// Desired unit movement direction from orientation + which movement keys are
// held. Forward follows the full look direction (pitch included) while
// flying or swimming, so looking up/down and pressing W actually climbs or
// dives; strafing (A/D) always stays level, and ground-walking forward stays
// horizontal too (looking down while walking shouldn't dig you into the
// floor). Pulled out as pure math (no GLFW dependency) so the fix is
// directly unit-testable without a live window.
compute_wish_dir :: proc(yaw, pitch: f32, fly, in_water, w, s, a, d: bool) -> Vec3 {
	right := Vec3{math.cos(yaw), 0, math.sin(yaw)}
	fwd := Vec3{math.sin(yaw), 0, -math.cos(yaw)}
	if fly || in_water {
		fwd = camera_front(yaw, pitch)
	}
	wish := Vec3{0, 0, 0}
	if w do wish += fwd
	if s do wish -= fwd
	if d do wish += right
	if a do wish -= right
	if wish.x != 0 || wish.y != 0 || wish.z != 0 {
		wish = linalg.normalize(wish)
	}
	return wish
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
		p.selected_slot = g_input.select - 1 // 1-9 equips that hotbar slot
		p.tool_mode = false // picking a hotbar block puts the tool away
		if b := inv_selected(p); b != .Air {
			label := block_is_item(b) ? fmt.tprintf("%s (ITEM)", block_name(b)) : block_name(b)
			toast_show(label, 0.9)
		}
		g_input.select = 0
	}

	wish := compute_wish_dir(
		p.yaw,
		p.pitch,
		p.fly,
		p.in_water,
		key_down(glfw.KEY_W),
		key_down(glfw.KEY_S),
		key_down(glfw.KEY_A),
		key_down(glfw.KEY_D),
	)

	// Sprint: start on a double-tap of W or while holding Ctrl+forward; hold it
	// as long as W stays down and there's stamina, exactly like Minecraft.
	w_down := key_down(glfw.KEY_W)
	if p.w_tap_timer > 0 do p.w_tap_timer -= dt
	if w_down && !p.w_was_down {
		if p.w_tap_timer > 0 do p.sprinting = true // second tap inside the window
		p.w_tap_timer = 0.28
	}
	if w_down && key_down(glfw.KEY_LEFT_CONTROL) do p.sprinting = true
	p.w_was_down = w_down
	if !w_down || p.hunger <= 6 do p.sprinting = false // can't sprint stopped or starving

	// Sneak: crouch-walk while holding Shift on solid ground. Overrides sprint and
	// caps the speed; the physics step below keeps you from stepping off ledges.
	p.sneaking = key_down(glfw.KEY_LEFT_SHIFT) && !p.fly && !p.in_water && p.on_ground
	crouch_target: f32 = p.sneaking ? 1 : 0
	p.crouch += (crouch_target - p.crouch) * min(dt * 12, 1)

	sprint_active := p.sprinting && !p.fly && !p.in_water && !p.sneaking
	speed := p.fly ? f32(FLY_SPEED) : (p.in_water ? f32(WALK_SPEED) * 0.6 : f32(WALK_SPEED))
	if sprint_active do speed *= SPRINT_MULT
	if p.sneaking {
		p.sprinting = false
		speed = f32(WALK_SPEED) * SNEAK_MULT
	}

	// Ease the FOV toward its sprint target so the zoom is smooth, not a snap.
	target: f32 = sprint_active ? 1 : 0
	p.fov_kick += (target - p.fov_kick) * min(dt * 10, 1)

	p.vel.x = wish.x * speed
	p.vel.z = wish.z * speed

	// Head-bob: advance the phase with walking speed while on the ground, and ease
	// its amplitude in/out so it fades up as you start moving and settles when you
	// stop — the gentle camera sway Minecraft uses on foot.
	hs := math.sqrt(p.vel.x * p.vel.x + p.vel.z * p.vel.z)
	moving_ground := p.on_ground && !p.fly && hs > 0.3
	if moving_ground do p.bob_phase += dt * (hs * 0.9 + 3.5)
	bob_target: f32 = moving_ground ? 1 : 0
	p.bob_amp += (bob_target - p.bob_amp) * min(dt * 8, 1)

	if p.fly {
		vy := wish.y * f32(FLY_SPEED) // from looking up/down while holding W/S
		if key_down(glfw.KEY_SPACE) do vy += f32(FLY_SPEED)
		if key_down(glfw.KEY_LEFT_SHIFT) do vy -= f32(FLY_SPEED)
		p.vel.y = vy
	} else if p.in_water {
		if key_down(glfw.KEY_SPACE) {
			p.vel.y = 4.0
		} else if key_down(glfw.KEY_LEFT_SHIFT) {
			p.vel.y = -4.0
		} else if wish.y != 0 {
			p.vel.y = wish.y * speed
		}
		// else: leave vel.y alone — physics_update's reduced gravity handles
		// the gentle sink when there's no vertical input at all.
	} else if key_down(glfw.KEY_SPACE) && p.on_ground {
		p.vel.y = JUMP_SPEED
		audio_play(.Jump, 0.5)
	}
}

// Hunger restored by eating one of a food item (0 = not edible).
food_value :: proc(b: BlockId) -> int {
	#partial switch b {
	case .CookedFood:
		return 8
	case .Bread:
		return 6
	case .RawFood:
		return 3
	}
	return 0
}

// Per-frame player upkeep: timers, health regen, footstep sounds.
player_tick :: proc(w: ^World, p: ^Player, dt: f32) {
	if p.hurt_timer > 0 do p.hurt_timer -= dt
	if p.eat_timer > 0 {
		p.eat_timer -= dt
		if p.eat_timer < 0 do p.eat_timer = 0
	}
	if p.swing_timer > 0 do p.swing_timer -= dt
	if p.attack_cd > 0 do p.attack_cd -= dt

	// Hunger drains slowly over a play session (~20min idle, ~7min walking
	// nonstop), faster while walking. Previously drained fully in under a
	// minute, which felt punishing rather than a long-session survival timer.
	drain: f32 = 0.015
	if p.on_ground && !p.fly && (abs(p.vel.x) + abs(p.vel.z)) > 0.1 do drain += 0.035
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

	// eat (G): eat the held item if it's food, otherwise fall back to the best
	// food in the inventory (cooked +8, bread +6, raw +3).
	if g_input.eat {
		if p.hunger < f32(HUNGER_MAX) {
			held := inv_selected(p)
			eaten := BlockId.Air
			if food_value(held) > 0 && inv_has(p, held, 1) {
				eaten = held // eat what you're holding
			} else if inv_has(p, .CookedFood, 1) {
				eaten = .CookedFood
			} else if inv_has(p, .Bread, 1) {
				eaten = .Bread
			} else if inv_has(p, .RawFood, 1) {
				eaten = .RawFood
			}
			if eaten != .Air {
				inv_take(p, eaten, 1)
				p.hunger = min(p.hunger + f32(food_value(eaten)), f32(HUNGER_MAX))
				toast_show(fmt.tprintf("ATE %s (HUNGER %d)", block_name(eaten), int(p.hunger)))
				audio_play(.Eat, 0.6)
				p.eat_timer = EAT_ANIM_DURATION
				mouth := p.pos + Vec3{0, EYE_HEIGHT * 0.85, 0} + camera_front(p.yaw, 0) * 0.4
				particle_spawn_eat(&w.particles, mouth, block_color(eaten))
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
		inv_add(p, .Seeds, 1)
		if broken == .Wheat3 do inv_add(p, .Wheat, 1)
		return
	}
	if broken == .Chest do chest_break(w, p, Ivec3{bx, by, bz}) // recover contents first
	if broken == .Stair do delete_key(&w.stairs, Ivec3{bx, by, bz}) // drop its stored facing
	world_set_block(w, bx, by, bz, .Air)
	net_send_edit(bx, by, bz, .Air, w.dimension)
	if broken == .Obsidian do portal_collapse(w, bx, by, bz) // frame gone -> interior winks out
	particle_spawn_break(&w.particles, broken, bx, by, bz)
	audio_play(.Break)
	item_spawn(&w.items, broken, Vec3{f32(bx) + 0.5, f32(by) + 0.3, f32(bz) + 0.5})
	if broken == .Grass && rng_int(4) == 0 do inv_add(p, .Seeds, 1) // seeds hide in grass
	if kind, applies := mine_tool(broken); applies && p.held_tool == kind do tool_wear(p, kind)
	falling_check_above(w, bx, by, bz) // gravel/sand resting on the broken block drops
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
			// Charged attacks: swinging before the cooldown refills lands a weak hit.
			// Charge ramps the damage up on a curve (0.2..1.0 of the full value), so
			// spamming clicks is worse than timing full-strength blows, as in MC 1.9+.
			charge := clamp(1 - p.attack_cd / ATTACK_CD_MAX, 0, 1)
			base := f32(3 + held_attack_bonus(p))
			dmg := max(1, int(base * (0.2 + 0.8 * charge * charge) + 0.5))
			mob_hit(w, mob_idx, dir, dmg)
			p.attack_cd = ATTACK_CD_MAX
			tool_wear(p, p.held_tool)
			mine_reset(p)
			p.swing_timer = SWING_DURATION
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
				// Tell the player why nothing's happening (the toast dedupes, so
				// holding the button doesn't spam it).
				kind, tier := block_min_tier(broken)
				toast_show(fmt.tprintf("NEED %s %s TO MINE %s", TIER_NAMES[tier], tool_name(kind), block_name(broken)))
			} else {
				p.mine_progress += dt
				need := mining_time(p, broken)
				p.mine_frac = clamp(p.mine_progress / max(need, 0.0001), 0, 1)
				if p.swing_timer <= 0 do p.swing_timer = SWING_DURATION // keep swinging while mining
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

	// Firing a bow: with a Bow selected, a place-request looses an Arrow downrange
	// (no target block needed). Costs one Arrow item.
	if want_place && inv_selected(p) == .Bow {
		if inv_has(p, .Arrow, 1) {
			inv_take(p, .Arrow, 1)
			from := p.pos + Vec3{0, EYE_HEIGHT, 0} + dir * 0.6
			append(&w.arrows, Arrow{pos = from, vel = dir * 30.0, from_player = true})
			p.swing_timer = SWING_DURATION
			audio_play(.Jump, 0.4)
		} else {
			toast_show("OUT OF ARROWS - CRAFT SOME (FEATHER + STONE)")
		}
		p.place_cd = 0.45
		want_place = false // consumed the click; don't also try to place
	}

	if want_place && hit.hit && !p.tool_mode { 	// no block-placing while a tool is drawn
		tx := hit.bx + hit.nx
		ty := hit.by + hit.ny
		tz := hit.bz + hit.nz
		sel := inv_selected(p)
		if ty >= 0 &&
		   ty < CHUNK_H &&
		   world_block(w, tx, ty, tz) == .Air &&
		   !block_hits_player(p, tx, ty, tz) &&
		   sel != .Air &&
		   !block_is_item(sel) && // food/seeds are held, not placed
		   inv_has(p, sel, 1) {
			world_set_block(w, tx, ty, tz, sel)
			// Stairs are oriented by the player's horizontal facing (yaw only,
			// so looking up/down while placing doesn't scramble the direction).
			// Press R while aiming at a stair to rotate it (see try_interact).
			if sel == .Stair {
				w.stairs[Ivec3{tx, ty, tz}] = stair_facing_from_dir(camera_front(p.yaw, 0))
			}
			net_send_edit(tx, ty, tz, sel, w.dimension)
			inv_take(p, sel, 1)
			p.swing_timer = SWING_DURATION
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

// Smelting near a placed furnace: Wood or Coal Ore is fuel (Wood preferred
// when both are on hand); Ore -> Iron, Gold Ore -> Gold, Sand -> Glass.
// Diamond Ore deliberately doesn't smelt — it's used raw for crafting, same
// as breaking it works in real Minecraft.
try_smelt :: proc(w: ^World, p: ^Player) {
	if !near_furnace(w, p) {
		toast_show("SMELT: STAND NEXT TO A FURNACE")
		return
	}
	fuel: BlockId
	if inv_has(p, .Wood, 1) {
		fuel = .Wood
	} else if inv_has(p, .CoalOre, 1) {
		fuel = .CoalOre
	} else {
		toast_show("SMELT: NEED WOOD OR COAL AS FUEL")
		return
	}
	if inv_has(p, .RawFood, 1) {
		inv_take(p, fuel, 1)
		inv_take(p, .RawFood, 1)
		inv_add(p, .CookedFood, 1)
		toast_show(fmt.tprintf("COOKED FOOD (HAVE %d)", inv_count(p, .CookedFood)))
		return
	}
	if inv_has(p, .Ore, 1) {
		inv_take(p, fuel, 1)
		inv_take(p, .Ore, 1)
		inv_add(p, .Iron, 1)
		toast_show(fmt.tprintf("SMELTED IRON (HAVE %d)", inv_count(p, .Iron)))
	} else if inv_has(p, .GoldOre, 1) {
		inv_take(p, fuel, 1)
		inv_take(p, .GoldOre, 1)
		inv_add(p, .Gold, 1)
		toast_show(fmt.tprintf("SMELTED GOLD (HAVE %d)", inv_count(p, .Gold)))
	} else if inv_has(p, .Sand, 1) {
		inv_take(p, fuel, 1)
		inv_take(p, .Sand, 1)
		inv_add(p, .Glass, 1)
		toast_show(fmt.tprintf("SMELTED GLASS (HAVE %d)", inv_count(p, .Glass)))
	} else {
		toast_show("SMELT: NEED ORE, GOLD ORE, OR SAND")
	}
}

// Crafting (press C). Tries recipes in order and makes the first you can afford:
//   8 Stone            -> 1 Furnace
//   4 Sand + 1 Ore     -> 1 Glowstone
try_craft :: proc(p: ^Player) {
	if inv_has(p, .Stone, 8) {
		inv_take(p, .Stone, 8)
		inv_add(p, .Furnace, 1)
		toast_show(fmt.tprintf("CRAFTED FURNACE (HAVE %d)", inv_count(p, .Furnace)))
		return
	}
	if inv_has(p, .Sand, 4) && inv_has(p, .Ore, 1) {
		inv_take(p, .Sand, 4)
		inv_take(p, .Ore, 1)
		inv_add(p, .Glowstone, 1)
		toast_show(fmt.tprintf("CRAFTED GLOWSTONE (HAVE %d)", inv_count(p, .Glowstone)))
		return
	}
	if inv_has(p, .Wheat, 3) {
		inv_take(p, .Wheat, 3)
		inv_add(p, .Bread, 1)
		toast_show(fmt.tprintf("BAKED BREAD (HAVE %d)", inv_count(p, .Bread)))
		return
	}
	toast_show("CRAFT: 8 STONE, 4 SAND+1 ORE, OR 3 WHEAT")
}
