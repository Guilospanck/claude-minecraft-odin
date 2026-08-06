package main

import "core:fmt"
import "core:math"

// Villagers: a named, interactable NPC layer separate from Mob (not a new
// MobKind — matches this codebase's existing pattern of one array per
// entity kind: w.mobs, w.items, w.crops are already siblings, not one
// mega-type). Two flavors: settled villagers wander near a home village and
// nomads roam freely with no home. Both are ephemeral (not persisted),
// consistent with mobs, which already aren't saved either.

Villager :: struct {
	pos, vel:  Vec3,
	yaw:       f32,
	on_ground: bool,
	moving:    bool,
	walk_phase: f32,
	ai_timer:  f32,
	health:    int,
	name:      string,
	home:      Ivec3, // village center; ignored (is_nomad) for nomads
	is_nomad:  bool,
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

VILLAGER_GREETINGS := []string {
	"LOVELY DAY, ISN'T IT?",
	"MIND THE WOLVES AT NIGHT.",
	"WELCOME TO OUR VILLAGE.",
	"THE FARM KEEPS US FED.",
	"SAFE TRAVELS, STRANGER.",
	"HAVEN'T SEEN YOU AROUND HERE.",
}

// Wander AI: settled villagers drift near home (heading back once past
// VILLAGER_HOME_RADIUS), nomads pick a fully random heading. Deliberately
// simpler than ai_wander's mob AI (no water-avoidance/step-hop) — villagers
// stay inside/near generated villages on flat ground, so that polish isn't
// needed here.
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
	villager_wander(v, dt)
	if v.moving {
		fwd := Vec3{math.sin(v.yaw), 0, -math.cos(v.yaw)}
		v.vel.x = fwd.x * VILLAGER_SPEED
		v.vel.z = fwd.z * VILLAGER_SPEED
		v.walk_phase += dt * 8.0
	} else {
		v.vel.x = 0
		v.vel.z = 0
	}
	v.on_ground = body_physics(w, &v.pos, &v.vel, VILLAGER_HW, VILLAGER_H, dt)
}

// Rare wandering nomad(s) with no home village — an order of magnitude
// rarer than hostile_try_spawn's 0.05 roll (entity.odin), spawning 1-3
// individuals together instead of building a whole settlement.
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

	group := 1 + rng_int(3) // 1..3
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
			},
		)
	}
}

villagers_update :: proc(w: ^World, p: ^Player, villagers: ^[dynamic]Villager, dt: f32) {
	if w.dimension == .Overworld && rng_f32() < 0.003 do nomad_try_spawn(w, villagers, p.pos)

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
	line := VILLAGER_GREETINGS[rng_int(len(VILLAGER_GREETINGS))]
	toast_show(fmt.tprintf("%s: %s", v.name, line))
	audio_play(.Place, 0.3)
}
