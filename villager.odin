package main

import "core:fmt"
import "core:math"

// Villagers: a named, interactable NPC layer separate from Mob (not a new
// MobKind — matches this codebase's existing pattern of one array per
// entity kind: w.mobs, w.items, w.crops are already siblings, not one
// mega-type). Two flavors: settled villagers wander near a home village and
// nomads roam freely with no home. Both are ephemeral (not persisted),
// consistent with mobs, which already aren't saved either.

// Profession drives look (profession_color), dialogue (profession_greetings)
// and where a settled villager actually lives (home is their building's own
// position, not a shared village centre) — so a Farmer stays near the farm,
// a Priest near the church, and so on, instead of every villager in a
// village being an interchangeable copy.
Profession :: enum {
	None, // nomads
	Farmer,
	Priest,
	Blacksmith,
	Merchant,
	Guard,
}

Villager :: struct {
	pos, vel:   Vec3,
	yaw:        f32,
	on_ground:  bool,
	moving:     bool,
	walk_phase: f32,
	ai_timer:   f32,
	health:     int,
	name:       string,
	home:       Ivec3, // own building's position; ignored (is_nomad) for nomads
	is_nomad:   bool,
	profession: Profession,
	home_biome: Biome, // biome they live in; drives their clothing (see entity_render)
	air:        f32, // breath left while submerged; refills on the surface
	drown_accum: f32, // fractional drowning damage once air runs out
}

VILLAGER_HW :: f32(0.3)
VILLAGER_H :: f32(1.8)
VILLAGER_SPEED :: f32(1.8)
VILLAGER_HOME_RADIUS :: f32(14.0) // how far a settled villager wanders from home
VILLAGER_DESPAWN_DIST :: f32(80) // nomads only; settled villagers never despawn

VILLAGER_NAMES := []string {
	"MARA", "OTIS", "PIP", "HAL", "RUNA", "TOBI", "ELIA", "GUS",
	"NELL", "BRAM", "ISLA", "FINN", "ODA", "REN", "TESS", "WYN",
	"AGNES", "COLM", "DELIA", "ERNO", "FAY", "GRIM", "HOLLA", "IVO",
}

// Deterministic-ish name pick so the same spawn index/position tends to
// read the same name within a session; not persisted, so no need for
// true world-seed determinism across restarts (villagers aren't saved).
villager_pick_name :: proc(salt: u64) -> string {
	return VILLAGER_NAMES[hash_u64(salt) % u64(len(VILLAGER_NAMES))]
}

// Shared by nomads (Profession.None) and as a fallback.
GENERIC_GREETINGS := []string {
	"LOVELY DAY, ISN'T IT?",
	"MIND THE WOLVES AT NIGHT.",
	"SAFE TRAVELS, STRANGER.",
	"HAVEN'T SEEN YOU AROUND HERE.",
}

FARMER_GREETINGS := []string {
	"THE FARM KEEPS US FED.",
	"WHEAT'S COMING IN NICELY THIS SEASON.",
	"MIND THE CROPS ON YOUR WAY THROUGH.",
}

PRIEST_GREETINGS := []string {
	"WELCOME TO OUR CHURCH.",
	"MAY YOUR TRAVELS BE BLESSED.",
	"THE BEACON KEEPS THE DARK AT BAY.",
}

BLACKSMITH_GREETINGS := []string {
	"NEED SOMETHING FORGED?",
	"STONE AND WOOD - GOOD STURDY MATERIALS.",
	"MIND THE SPARKS.",
}

MERCHANT_GREETINGS := []string {
	"WELCOME TO OUR VILLAGE.",
	"BUSINESS HAS BEEN SLOW LATELY.",
	"ALWAYS LOOKING FOR NEW TRADE.",
}

GUARD_GREETINGS := []string {
	"QUIET NIGHT SO FAR.",
	"KEEP YOUR WEAPON READY AFTER DARK.",
	"I WATCH THIS TOWER DAY AND NIGHT.",
}

profession_greetings :: proc(p: Profession) -> []string {
	switch p {
	case .Farmer:
		return FARMER_GREETINGS
	case .Priest:
		return PRIEST_GREETINGS
	case .Blacksmith:
		return BLACKSMITH_GREETINGS
	case .Merchant:
		return MERCHANT_GREETINGS
	case .Guard:
		return GUARD_GREETINGS
	case .None:
		return GENERIC_GREETINGS
	}
	return GENERIC_GREETINGS
}

// Wander AI: settled villagers drift near home (heading back once past
// VILLAGER_HOME_RADIUS), nomads pick a fully random heading.
@(private = "file")
villager_wander :: proc(v: ^Villager, dt: f32) {
	v.ai_timer -= dt
	if v.ai_timer <= 0 {
		v.ai_timer = rng_range(2.0, 5.0)
		v.moving = rng_f32() < 0.5
		if v.moving {
			if v.is_nomad {
				v.yaw = rng_range(0, 2 * math.PI)
			} else {
				dx := f32(v.home.x) - v.pos.x
				dz := f32(v.home.z) - v.pos.z
				if dx * dx + dz * dz > VILLAGER_HOME_RADIUS * VILLAGER_HOME_RADIUS {
					v.yaw = math.atan2(dx, -dz) // wandered too far: head home
				} else {
					v.yaw = rng_range(0, 2 * math.PI)
				}
			}
		}
	}
}

villager_update :: proc(w: ^World, v: ^Villager, dt: f32) {
	// Villagers can't breathe underwater any more than mobs can: a submerged
	// villager swims for the nearest shore and drowns if it can't reach it.
	if body_submerged(w, v.pos, VILLAGER_H) {
		v.air -= dt
		dir := body_land_dir(w, v.pos)
		v.vel.x = dir.x * VILLAGER_SPEED * 1.3
		v.vel.z = dir.z * VILLAGER_SPEED * 1.3
		v.vel.y = 2.2
		if dir.x != 0 || dir.z != 0 do v.yaw = math.atan2(dir.x, -dir.z)
		v.walk_phase += dt * 12
		v.on_ground = body_physics(w, &v.pos, &v.vel, VILLAGER_HW, VILLAGER_H, dt, 3.0)
		if v.air < 0 {
			v.drown_accum += dt
			if v.drown_accum >= 1.0 {
				v.drown_accum = 0
				v.health -= 2
			}
		}
		return
	}
	v.air = CREATURE_AIR_MAX

	villager_wander(v, dt)
	if v.moving {
		fwd := Vec3{math.sin(v.yaw), 0, -math.cos(v.yaw)}

		// Villagers never wade into water — same treatment land mobs get in
		// mob_update (entity.odin): treat the water ahead like a wall and
		// turn away instead of stepping in.
		ax := int(math.floor(v.pos.x + fwd.x * (VILLAGER_HW + 0.4)))
		az := int(math.floor(v.pos.z + fwd.z * (VILLAGER_HW + 0.4)))
		ay := int(math.floor(v.pos.y))
		if water_ahead(w, ax, az, ay) {
			// turn away from the water and keep walking (deterministic — no RNG
			// re-roll, which could randomly send them straight back in).
			v.yaw += math.PI
			v.vel.x = 0
			v.vel.z = 0
		} else {
			v.vel.x = fwd.x * VILLAGER_SPEED
			v.vel.z = fwd.z * VILLAGER_SPEED
			v.walk_phase += dt * 8.0
			// hop a one-block step (but not fences/walls); turn away if blocked
			if v.on_ground {
				hop, blocked := step_or_block(w, v.pos, fwd, VILLAGER_HW, VILLAGER_H)
				if blocked {
					v.moving = false
					v.ai_timer = 0
					v.vel.x = 0
					v.vel.z = 0
					v.yaw += rng_range(1.5, 3.0) * (rng_f32() < 0.5 ? 1 : -1)
				} else if hop > 0 {
					v.vel.y = hop
				}
			}
		}
	} else {
		v.vel.x = 0
		v.vel.z = 0
	}
	v.on_ground = body_physics(w, &v.pos, &v.vel, VILLAGER_HW, VILLAGER_H, dt)
}

// Rare wandering nomad(s) with no home village — meeting a named villager
// should normally mean finding an actual village, so this is deliberately a
// novelty encounter (~6x rarer than the first pass) rather than a common
// way to run into people, spawning 1-2 individuals together at most.
nomad_try_spawn :: proc(w: ^World, villagers: ^[dynamic]Villager, player_pos: Vec3) {
	ang := rng_range(0, 2 * math.PI)
	dist := rng_range(24, 46)
	wx := int(player_pos.x + math.cos(ang) * dist)
	wz := int(player_pos.z + math.sin(ang) * dist)

	sy, surf := surface_y(w, wx, wz)
	if sy < 0 do return
	if surf != .Grass && surf != .Sand && surf != .Snow do return
	if world_block(w, wx, sy + 1, wz) == .Water do return
	if block_is_solid(world_block(w, wx, sy + 1, wz)) do return

	_, nbiome, _ := world_height_and_biome(w.seed, wx, wz)
	group := 1 + rng_int(2) // 1..2
	salt := hash_u64(u64(i64(wx)) ~ (u64(i64(wz)) << 32) ~ u64(len(villagers^)))
	for k in 0 ..< group {
		append(
			villagers,
			Villager {
				pos = Vec3{f32(wx) + 0.5 + f32(k) * 0.7, f32(sy + 1), f32(wz) + 0.5},
				yaw = rng_range(0, 2 * math.PI),
				health = 10,
				name = villager_pick_name(salt + u64(k)),
				is_nomad = true,
				home_biome = nbiome,
			},
		)
	}
}

villagers_update :: proc(w: ^World, p: ^Player, villagers: ^[dynamic]Villager, dt: f32) {
	if w.dimension == .Overworld && rng_f32() < 0.0005 do nomad_try_spawn(w, villagers, p.pos)

	i := 0
	for i < len(villagers^) {
		v := &villagers^[i]
		if v.is_nomad {
			dx := v.pos.x - p.pos.x
			dz := v.pos.z - p.pos.z
			if dx * dx + dz * dz > VILLAGER_DESPAWN_DIST * VILLAGER_DESPAWN_DIST {
				villagers^[i] = villagers^[len(villagers^) - 1]
				pop(villagers)
				continue
			}
		}
		villager_update(w, v, dt)
		i += 1
	}
}

// Nearest villager under the ray within `reach`; returns index or -1.
// Mirrors mob_pick (entity.odin) with a fixed humanoid-ish AABB instead of
// per-kind MOB_DIMS.
villager_pick :: proc(villagers: ^[dynamic]Villager, eye, dir: Vec3, reach: f32) -> (int, f32) {
	best := -1
	best_t: f32 = reach
	for i in 0 ..< len(villagers^) {
		v := &villagers^[i]
		bmin := Vec3{v.pos.x - VILLAGER_HW, v.pos.y, v.pos.z - VILLAGER_HW}
		bmax := Vec3{v.pos.x + VILLAGER_HW, v.pos.y + VILLAGER_H, v.pos.z + VILLAGER_HW}
		ok, t := ray_aabb(eye, dir, bmin, bmax)
		if ok && t < best_t {
			best = i
			best_t = t
		}
	}
	return best, best_t
}

// R "use" key on a villager: a name + one of a handful of flavor lines, the
// same scope as the existing feed/breed toasts — not a trading/dialogue
// system, which would be its own feature.
try_talk_to_villager :: proc(v: ^Villager) {
	lines := profession_greetings(v.profession)
	line := lines[rng_int(len(lines))]
	toast_show(fmt.tprintf("%s: %s", v.name, line))
	audio_play(.Place, 0.3)
}
