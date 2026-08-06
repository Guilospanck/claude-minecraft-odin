package main

import "core:fmt"
import "core:math"

MobKind :: enum {
	Pig,
	Sheep,
	Cow,
	Chicken,
	Rabbit,
	Horse,
	Zombie,
	Skeleton,
	Piglin, // nether melee hostile
	Ghast, // nether floating ranged hostile
	Fish, // aquatic: never leaves water
	Squid, // aquatic: never leaves water
	Dolphin, // aquatic: fast swimmer
	Pufferfish, // aquatic: small and round
	Jellyfish, // aquatic: drifts
	SnowLeopard, // biome specialist: snow/taiga
	Camel, // biome specialist: desert/badlands
	Llama, // biome specialist: savanna/mountains
}

MOB_KIND_COUNT :: len(MobKind)
PASSIVE_COUNT :: 6 // Pig..Horse; hostiles/aquatic spawn separately

ZOMBIE_DETECT :: f32(18.0)
ZOMBIE_REACH :: f32(1.5)
ZOMBIE_DMG :: 3
PIGLIN_DMG :: 4
GHAST_DETECT :: f32(30.0)

mob_is_hostile :: proc(k: MobKind) -> bool {
	return k == .Zombie || k == .Skeleton || k == .Piglin || k == .Ghast
}

// Nether mobs don't burn in daylight (the overworld undead do).
mob_burns_in_day :: proc(k: MobKind) -> bool {
	return k == .Zombie || k == .Skeleton
}

// Aquatic mobs swim freely but must always stay fully submerged; land mobs
// (everything else) treat water as an obstacle and never wade into it.
mob_is_aquatic :: proc(k: MobKind) -> bool {
	return(
		k == .Fish ||
		k == .Squid ||
		k == .Dolphin ||
		k == .Pufferfish ||
		k == .Jellyfish \
	)
}

// Why a mob's health last reached zero — tags the generic despawn-on-death
// path so the right particle colour / toast can be shown (see
// mob_death_feedback). Player-attack kills go through mob_hit instead, which
// has its own immediate handling, so this only covers the natural-causes
// deaths added here.
MobDeathCause :: enum {
	None,
	OldAge,
	Starvation,
	Predator,
	Burned,
	Fall,
}

Mob :: struct {
	kind:         MobKind,
	pos:          Vec3, // feet centre
	vel:          Vec3,
	yaw:          f32,
	on_ground:    bool,
	moving:       bool,
	walk_phase:   f32, // drives leg animation
	ai_timer:     f32,
	attack_timer: f32, // hostile melee cooldown
	burn_accum:   f32, // fractional daylight-burn damage
	health:       int,
	love_timer:   f32, // >0 while "in love" (fed Wheat), looking for a same-kind mate
	is_baby:      bool, // renders smaller, has a shrunk hitbox, can't breed
	grow_timer:   f32, // seconds until a baby becomes an adult
	age:            f32, // seconds since spawn; old-age damage begins past MOB_OLD_AGE
	hunger_level:   f32, // rises over time; grazing lowers it (0 = well fed, the spawn default)
	graze_cd:       f32, // cooldown between grazing bites
	old_age_accum:  f32, // fractional old-age damage
	starve_accum:   f32, // fractional starvation damage
	death_cause:    MobDeathCause, // why health last reached zero (see above)
	fall_speed:     f32, // peak downward speed since last on_ground, for fall damage
}

BREED_LOVE_DURATION :: f32(30.0) // how long a fed mob stays in love mode
BREED_RADIUS :: f32(3.0) // mates must be within this many blocks
BABY_GROW_TIME :: f32(60.0) // seconds for a baby to grow into an adult

// Natural population bounds, replacing a hard mob-count cap: old age catches
// up with every mob eventually; passive animals must graze on grass or they
// starve; hostiles hunt down nearby passive mobs when the player isn't in
// range. Together these let population settle on its own (more animals ->
// more grazing -> less grass -> starvation) instead of a hard ceiling.
MOB_OLD_AGE :: f32(600.0) // ~10 minutes: old-age damage begins
MOB_OLD_AGE_DPS :: f32(2.0)
MOB_HUNGER_RATE :: f32(1.0) // hunger_level units/sec
MOB_STARVE_THRESHOLD :: f32(240.0) // ~4 minutes ungrazed before it starts hurting
MOB_STARVE_DPS :: f32(1.0)
MOB_GRAZE_RELIEF :: f32(80.0)
MOB_GRAZE_COOLDOWN :: f32(6.0)
PREDATION_RANGE :: f32(14.0) // how far a hostile senses passive prey
PREDATION_REACH :: f32(1.6)
PREDATION_DMG :: 3
MOB_DEATH_FEEDBACK_RANGE :: f32(28.0) // only show toast/particles if plausibly visible

MobDims :: struct {
	hw:    f32, // half width/depth
	h:     f32, // height
	speed: f32,
}

MOB_DIMS := [MobKind]MobDims {
	.Pig      = {0.45, 0.9, 2.2},
	.Sheep    = {0.45, 1.2, 2.0},
	.Cow      = {0.5, 1.4, 1.9},
	.Chicken  = {0.3, 0.7, 2.6},
	.Rabbit   = {0.25, 0.5, 2.8},
	.Horse    = {0.55, 1.6, 3.0},
	.Zombie   = {0.35, 1.9, 3.2},
	.Skeleton = {0.33, 1.85, 3.8},
	.Piglin   = {0.35, 1.9, 3.4},
	.Ghast    = {0.7, 1.4, 2.0},
	.Fish     = {0.18, 0.22, 1.8},
	.Squid    = {0.28, 0.55, 1.3},
	.Dolphin    = {0.3, 0.5, 2.6}, // fast
	.Pufferfish = {0.22, 0.28, 1.3},
	.Jellyfish  = {0.25, 0.5, 0.9}, // slow drift
	.SnowLeopard = {0.4, 0.85, 2.9}, // lithe and quick
	.Camel       = {0.55, 2.1, 1.7}, // tall and slow
	.Llama       = {0.45, 1.6, 2.2},
}

MOB_DESPAWN_DIST :: f32(60)

// --- AI + physics for one mob ---
@(private = "file")
ai_wander :: proc(m: ^Mob, dt: f32, move_chance: f32) {
	m.ai_timer -= dt
	if m.ai_timer <= 0 {
		m.ai_timer = rng_range(1.5, 4.0)
		m.moving = rng_f32() < move_chance
		if m.moving {
			m.yaw = rng_range(0, 2 * math.PI)
		}
	}
}

// Aquatic mobs just pick a new heading periodically; the actual movement (in
// mob_update) refuses any step that would leave water, so they can wander
// forever without ever surfacing or beaching.
@(private = "file")
ai_swim :: proc(m: ^Mob, dt: f32) {
	m.ai_timer -= dt
	if m.ai_timer <= 0 {
		m.ai_timer = rng_range(1.0, 3.0)
		m.yaw = rng_range(0, 2 * math.PI)
	}
}

@(private = "file")
skeleton_shoot :: proc(w: ^World, m: ^Mob, p: ^Player) {
	from := m.pos + Vec3{0, MOB_DIMS[.Skeleton].h * 0.85, 0}
	to := p.pos + Vec3{0, EYE_HEIGHT * 0.6, 0}
	dir := to - from
	dist := math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z) + 1e-4
	dir = dir / dist
	dir.y += clamp(dist * 0.02, 0, 0.35) // lead for gravity drop
	dl := math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
	dir = dir / dl
	append(&w.arrows, Arrow{pos = from, vel = dir * 22.0, from_player = false})
	audio_play(.Jump, 0.25)
}

@(private = "file")
ghast_shoot :: proc(w: ^World, m: ^Mob, p: ^Player) {
	from := m.pos + Vec3{0, MOB_DIMS[.Ghast].h * 0.5, 0}
	to := p.pos + Vec3{0, EYE_HEIGHT * 0.6, 0}
	dir := to - from
	dl := math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z) + 1e-4
	dir = dir / dl
	append(&w.arrows, Arrow{pos = from, vel = dir * 14.0, from_player = false, fire = true})
	audio_play(.Hurt, 0.3)
}

// Ghast: drifts in the air a few blocks above the floor and lobs fireballs.
@(private = "file")
ai_ghast :: proc(w: ^World, p: ^Player, m: ^Mob, dt: f32) {
	m.ai_timer -= dt
	if m.ai_timer <= 0 {
		m.ai_timer = rng_range(2.0, 5.0)
		m.yaw = rng_range(0, 2 * math.PI)
	}
	fwd := Vec3{math.sin(m.yaw), 0, -math.cos(m.yaw)}
	m.vel.x = fwd.x * 1.6
	m.vel.z = fwd.z * 1.6
	fy := nether_surface(w, int(m.pos.x), int(m.pos.z))
	target := f32(fy < 0 ? SEA_LEVEL : fy) + 9
	m.vel.y = clamp((target - m.pos.y) * 0.8, -2.5, 2.5)
	m.walk_phase += dt * 4

	dx := p.pos.x - m.pos.x
	dz := p.pos.z - m.pos.z
	m.attack_timer -= dt
	if dx * dx + dz * dz < GHAST_DETECT * GHAST_DETECT && m.attack_timer <= 0 {
		m.yaw = math.atan2(dx, -dz)
		ghast_shoot(w, m, p)
		m.attack_timer = 2.8
	}
}

// Scans a short window below `feet_y` for the first non-air block and reports
// whether it's water. A land mob's resting feet sit one cell ABOVE its floor
// block, and shorelines vary in depth, so a single fixed-height probe misses
// most real water tiles — this walks down through a few cells instead.
// Not file-private: villager.odin's villager_update reuses it too.
water_ahead :: proc(w: ^World, x, z, feet_y: int) -> bool {
	for dy in 0 ..< 5 {
		b := world_block(w, x, feet_y - dy, z)
		if b == .Air do continue
		return b == .Water
	}
	return false
}

// Hunts the nearest passive, non-baby mob within PREDATION_RANGE — the
// "predation" population bound. Called when a hostile can't see the player;
// mirrors ai_seek_mate's approach-and-attack shape. Damage is applied
// directly to the prey's health rather than via mob_hit, since mob_hit's
// immediate swap-remove-on-death would be unsafe to call mid-iteration from
// inside mobs_update's own loop over this same mobs array (killing an
// earlier-indexed mob would move a not-yet-updated one into this slot).
// The prey's death is instead picked up by mobs_update's own health<=0
// check, same as old age/starvation/burning.
@(private = "file")
ai_predation :: proc(w: ^World, m: ^Mob, self_idx: int, dt: f32) -> bool {
	best_idx := -1
	best_d2 := PREDATION_RANGE * PREDATION_RANGE
	best_dx, best_dz: f32
	for i in 0 ..< len(w.mobs) {
		if i == self_idx do continue
		other := w.mobs[i]
		if mob_is_hostile(other.kind) || mob_is_aquatic(other.kind) do continue
		dx := other.pos.x - m.pos.x
		dz := other.pos.z - m.pos.z
		d2 := dx * dx + dz * dz
		if d2 < best_d2 {
			best_d2 = d2
			best_dx, best_dz = dx, dz
			best_idx = i
		}
	}
	if best_idx < 0 do return false
	m.yaw = math.atan2(best_dx, -best_dz)
	m.moving = true
	m.attack_timer -= dt
	if best_d2 < PREDATION_REACH * PREDATION_REACH && m.attack_timer <= 0 {
		w.mobs[best_idx].health -= PREDATION_DMG
		w.mobs[best_idx].death_cause = .Predator
		m.attack_timer = 1.2
	}
	return true
}

@(private = "file")
ai_hostile :: proc(w: ^World, p: ^Player, m: ^Mob, self_idx: int, dt: f32) {
	dx := p.pos.x - m.pos.x
	dz := p.pos.z - m.pos.z
	d2 := dx * dx + dz * dz
	if d2 >= ZOMBIE_DETECT * ZOMBIE_DETECT {
		if !ai_predation(w, m, self_idx, dt) {
			ai_wander(m, dt, 0.4)
		}
		return
	}
	toward := math.atan2(dx, -dz)
	m.attack_timer -= dt

	if m.kind == .Skeleton {
		d := math.sqrt(d2)
		if d < 6 {
			m.moving = true
			m.yaw = math.atan2(-dx, dz) // kite away
		} else if d > 11 {
			m.moving = true
			m.yaw = toward // close the gap
		} else {
			m.moving = false
			m.yaw = toward // hold and shoot
		}
		if m.attack_timer <= 0 {
			skeleton_shoot(w, m, p)
			m.attack_timer = 1.6
		}
		return
	}

	// zombie / piglin melee
	m.moving = true
	m.yaw = toward
	if d2 < ZOMBIE_REACH * ZOMBIE_REACH && math.abs(p.pos.y - m.pos.y) < 2.0 && m.attack_timer <= 0 {
		inv := 1.0 / math.sqrt(d2 + 1e-4)
		dmg := m.kind == .Piglin ? PIGLIN_DMG : ZOMBIE_DMG
		player_damage(p, dmg, Vec3{dx * inv, 0, dz * inv})
		m.attack_timer = 1.0
	}
}

MATE_SEEK_RANGE :: f32(16.0) // how far a love-mode mob can sense a same-kind mate

// A mob in love mode beelines for the nearest eligible same-kind mate instead
// of wandering randomly — without this, two fed animals only breed if they
// happen to wander within BREED_RADIUS of each other by chance, which in
// practice almost never happens. Returns false (so the caller falls back to
// normal wandering) if no mate is in range.
@(private = "file")
ai_seek_mate :: proc(w: ^World, m: ^Mob, self_idx: int) -> bool {
	best_d2 := MATE_SEEK_RANGE * MATE_SEEK_RANGE
	found := false
	best_dx, best_dz: f32
	for i in 0 ..< len(w.mobs) {
		if i == self_idx do continue
		other := w.mobs[i]
		if other.kind != m.kind || other.love_timer <= 0 || other.is_baby do continue
		dx := other.pos.x - m.pos.x
		dz := other.pos.z - m.pos.z
		d2 := dx * dx + dz * dz
		if d2 < best_d2 {
			best_d2 = d2
			best_dx, best_dz = dx, dz
			found = true
		}
	}
	if found {
		m.yaw = math.atan2(best_dx, -best_dz)
		m.moving = true
	}
	return found
}

mob_update :: proc(w: ^World, p: ^Player, m: ^Mob, self_idx: int, dt: f32) {
	dims := MOB_DIMS[m.kind]
	if m.is_baby {
		dims.hw *= 0.6
		dims.h *= 0.6
		m.grow_timer -= dt
		if m.grow_timer <= 0 do m.is_baby = false
	}
	if m.love_timer > 0 do m.love_timer -= dt

	// Ghast flies freely (no gravity / terrain collision).
	if m.kind == .Ghast {
		ai_ghast(w, p, m, dt)
		m.pos += m.vel * dt
		m.on_ground = false
		return
	}

	// Aquatic mobs swim under their own free-flight-style movement, but every
	// step is validated: it only commits if the destination (feet AND head)
	// is still water, so they can never surface onto land or into open air.
	if mob_is_aquatic(m.kind) {
		ai_swim(m, dt)
		m.walk_phase += dt * 3.0
		fwd := Vec3{math.sin(m.yaw), 0, -math.cos(m.yaw)}
		vert := math.sin(m.walk_phase) * 0.4
		new_pos := m.pos + Vec3{fwd.x * dims.speed, vert, fwd.z * dims.speed} * dt
		nx := int(math.floor(new_pos.x))
		ny := int(math.floor(new_pos.y))
		nz := int(math.floor(new_pos.z))
		still_water :=
			world_block(w, nx, ny, nz) == .Water &&
			world_block(w, nx, int(math.floor(new_pos.y + dims.h)), nz) == .Water
		if still_water {
			m.pos = new_pos
		} else {
			m.ai_timer = 0 // hit the water's edge/surface/floor: redirect now
		}
		m.on_ground = false
		return
	}

	if mob_is_hostile(m.kind) {
		ai_hostile(w, p, m, self_idx, dt)
	} else if m.love_timer <= 0 || !ai_seek_mate(w, m, self_idx) {
		ai_wander(m, dt, 0.6)
	}

	if m.moving {
		fwd := Vec3{math.sin(m.yaw), 0, -math.cos(m.yaw)}

		// Land mobs never wade into water — treat it like a wall and turn away.
		ax := int(math.floor(m.pos.x + fwd.x * (dims.hw + 0.4)))
		az := int(math.floor(m.pos.z + fwd.z * (dims.hw + 0.4)))
		ay := int(math.floor(m.pos.y))
		if water_ahead(w, ax, az, ay) {
			m.moving = false
			m.ai_timer = 0 // pick a new direction next tick
			m.vel.x = 0
			m.vel.z = 0
		} else {
			m.vel.x = fwd.x * dims.speed
			m.vel.z = fwd.z * dims.speed
			m.walk_phase += dt * 9.0

			// Hop over a one-block step, but only if it's genuinely climbable
			// (the space above the obstruction is clear). Without this check,
			// a mob walking into a wall 2+ blocks tall would hop every single
			// frame forever — bouncing in place instead of giving up and
			// picking a new direction.
			if m.on_ground {
				ahead := m.pos + Vec3{fwd.x * (dims.hw + 0.25), 0, fwd.z * (dims.hw + 0.25)}
				if body_collides(w, ahead, dims.hw, 0.5) {
					if !body_collides(w, ahead + Vec3{0, 1, 0}, dims.hw, dims.h) {
						m.vel.y = 7.5 // a real 1-block step: hop it
					} else {
						// Too tall to climb: stop before it turns into an
						// endless bounce, and turn away. Mate-seeking has no
						// obstacle avoidance of its own (it always recomputes
						// the same heading toward its target), so without this
						// deflection it would walk into the same wall forever;
						// wandering already re-randomizes on its own via
						// ai_timer, so the turn is harmless there too.
						m.moving = false
						m.ai_timer = 0
						m.vel.x = 0
						m.vel.z = 0
						m.yaw += rng_range(1.5, 3.0) * (rng_f32() < 0.5 ? 1 : -1)
					}
				}
			}
		}
	} else {
		m.vel.x = 0
		m.vel.z = 0
	}

	m.on_ground = body_physics(w, &m.pos, &m.vel, dims.hw, dims.h, dt)
}

// --- spawning ---
// Not file-private: villager.odin's nomad_try_spawn reuses it too.
surface_y :: proc(w: ^World, wx, wz: int) -> (int, BlockId) {
	for y := CHUNK_H - 2; y >= 1; y -= 1 {
		b := world_block(w, wx, y, wz)
		if b != .Air && b != .Water do return y, b
	}
	return -1, .Air
}

// Nether floor: scan below the bedrock roof for a solid block with 2 air above.
@(private = "file")
nether_surface :: proc(w: ^World, wx, wz: int) -> int {
	for y := CHUNK_H - 8; y >= 2; y -= 1 {
		if block_is_solid(world_block(w, wx, y, wz)) &&
		   world_block(w, wx, y + 1, wz) == .Air &&
		   world_block(w, wx, y + 2, wz) == .Air {
			return y
		}
	}
	return -1
}

// Random spawn rolls (the 4 *_try_spawn functions below) fire every frame
// independently, each with no idea what else has already spawned nearby —
// left unchecked, that stacks up a crowd well before old age/starvation/
// predation or simply wandering off can thin it back out. This local
// density cap throttles the ROLLS specifically; breed_pass (feeding +
// babies) is deliberately not gated by it, so a well-fed pair can still
// grow a herd past the cap — this only stops random passersby from also
// piling into an already-busy spot.
MOB_LOCAL_RADIUS :: f32(28)
MOB_LOCAL_CAP :: 10

// Not file-private: tests exercise it directly.
mobs_crowded :: proc(mobs: ^[dynamic]Mob, wx, wz: int) -> bool {
	fx, fz := f32(wx), f32(wz)
	count := 0
	for m in mobs^ {
		dx := m.pos.x - fx
		dz := m.pos.z - fz
		if dx * dx + dz * dz < MOB_LOCAL_RADIUS * MOB_LOCAL_RADIUS {
			count += 1
			if count >= MOB_LOCAL_CAP do return true
		}
	}
	return false
}

// Nether spawn: piglins on netherrack, ghasts drifting in the caverns.
nether_try_spawn :: proc(w: ^World, mobs: ^[dynamic]Mob, player_pos: Vec3) {
	ang := rng_range(0, 2 * math.PI)
	dist := rng_range(16, 40)
	wx := int(player_pos.x + math.cos(ang) * dist)
	wz := int(player_pos.z + math.sin(ang) * dist)
	if mobs_crowded(mobs, wx, wz) do return
	fy := nether_surface(w, wx, wz)
	if fy < 0 do return

	if rng_f32() < 0.35 {
		append(
			mobs,
			Mob {
				kind = .Ghast,
				pos = Vec3{f32(wx) + 0.5, f32(fy) + 6, f32(wz) + 0.5},
				yaw = rng_range(0, 2 * math.PI),
				ai_timer = rng_range(0, 2),
				health = 10,
			},
		)
		return
	}
	append(
		mobs,
		Mob {
			kind = .Piglin,
			pos = Vec3{f32(wx) + 0.5, f32(fy + 1), f32(wz) + 0.5},
			yaw = rng_range(0, 2 * math.PI),
			ai_timer = rng_range(0, 2),
			health = 10,
		},
	)
}

// Biomes with real vegetation for a grazing animal to live on. Deserts,
// badlands, mountains, snow, ocean and beaches have nothing to eat, so
// passive mobs never spawn there regardless of what's directly underfoot.
// Not file-private: tests exercise it directly.
biome_supports_grazing :: proc(b: Biome) -> bool {
	#partial switch b {
	case .Plains, .Forest, .Savanna, .Swamp, .Taiga, .Jungle, .Meadow:
		return true
	}
	return false
}

// Weighted pick of which passive kind fits a biome, instead of a flat
// uniform roll over all 5 kinds everywhere: sheep/cows favour open
// grassland, rabbits favour forest/taiga cover, pigs/chickens are
// generalists that show up a bit everywhere vegetated.
@(private = "file")
passive_kind_for_biome :: proc(b: Biome) -> MobKind {
	r := rng_int(100)
	#partial switch b {
	case .Plains, .Savanna:
		if r < 25 do return .Cow
		if r < 45 do return .Sheep
		if r < 65 do return .Horse // open grassland grazer
		if r < 85 do return .Chicken
		if r < 95 do return .Pig
		return .Rabbit
	case .Forest, .Taiga, .Jungle:
		if r < 35 do return .Rabbit
		if r < 60 do return .Pig
		if r < 80 do return .Chicken
		if r < 92 do return .Sheep
		return .Cow
	case .Meadow:
		if r < 35 do return .Sheep
		if r < 60 do return .Horse
		if r < 80 do return .Cow
		if r < 92 do return .Rabbit
		return .Chicken
	case .Swamp:
		if r < 45 do return .Pig
		if r < 75 do return .Chicken
		if r < 90 do return .Rabbit
		return .Sheep
	}
	return MobKind(rng_int(PASSIVE_COUNT))
}

// The animal that belongs to an otherwise-barren extreme biome (where nothing
// grazes): snow leopards in the cold, camels in the deserts, llamas out on the
// savanna and high ground. These spawn without the grass requirement the
// grazers have, so the harsh biomes aren't lifeless. Returns (kind, true) when
// the biome has a specialist.
biome_specialist :: proc(b: Biome) -> (MobKind, bool) {
	#partial switch b {
	case .Snow, .Taiga:
		return .SnowLeopard, true
	case .Desert, .Badlands:
		return .Camel, true
	case .Savanna, .Mountains:
		return .Llama, true
	}
	return .Pig, false
}

// Resource gate: needs grass to graze or water to drink somewhere nearby,
// not just under the exact spawn point - samples random columns in a
// radius (with a little vertical slop for mild slopes) instead of an
// exhaustive scan, since this only runs on the rare frames a spawn roll
// succeeds. Not file-private: tests exercise it directly.
food_or_water_nearby :: proc(w: ^World, wx, wz, sy: int) -> bool {
	for _ in 0 ..< 8 {
		dx := rng_int(21) - 10
		dz := rng_int(21) - 10
		for dy in -1 ..= 1 {
			b := world_block(w, wx + dx, sy + dy, wz + dz)
			if b == .Grass || b == .Water do return true
		}
	}
	return false
}

mob_try_spawn :: proc(w: ^World, mobs: ^[dynamic]Mob, player_pos: Vec3) {
	ang := rng_range(0, 2 * math.PI)
	dist := rng_range(20, 44)
	wx := int(player_pos.x + math.cos(ang) * dist)
	wz := int(player_pos.z + math.sin(ang) * dist)
	if mobs_crowded(mobs, wx, wz) do return

	sy, surf := surface_y(w, wx, wz)
	if sy < 0 do return
	if surf != .Grass && surf != .Sand && surf != .Snow do return
	if world_block(w, wx, sy + 1, wz) == .Water do return // don't spawn on seabed
	if block_is_solid(world_block(w, wx, sy + 1, wz)) do return // needs headroom

	_, biome, _ := world_height_and_biome(w.seed, wx, wz)

	// A biome's specialist (snow leopard/camel/llama) can spawn on its harsh,
	// grass-free ground; otherwise fall back to a grazer, which does need grass
	// or water nearby. This is what puts life in the deserts and snowfields.
	kind: MobKind
	hp := 6
	if spec, ok := biome_specialist(biome); ok && rng_f32() < 0.45 {
		kind = spec
		if kind == .Camel do hp = 10 // camels are tough
	} else {
		if !biome_supports_grazing(biome) do return
		if !food_or_water_nearby(w, wx, wz, sy) do return
		kind = passive_kind_for_biome(biome)
	}

	append(
		mobs,
		Mob {
			kind = kind,
			pos = Vec3{f32(wx) + 0.5, f32(sy + 1), f32(wz) + 0.5},
			yaw = rng_range(0, 2 * math.PI),
			ai_timer = rng_range(0, 2),
			health = hp,
		},
	)
}

// Water spawn: fish/squid appear in open water away from the player. Requires
// two blocks of water depth at sea level so the mob spawns fully submerged.
water_try_spawn :: proc(w: ^World, mobs: ^[dynamic]Mob, player_pos: Vec3) {
	ang := rng_range(0, 2 * math.PI)
	dist := rng_range(14, 36)
	wx := int(player_pos.x + math.cos(ang) * dist)
	wz := int(player_pos.z + math.sin(ang) * dist)
	if mobs_crowded(mobs, wx, wz) do return
	if world_block(w, wx, SEA_LEVEL, wz) != .Water do return
	if world_block(w, wx, SEA_LEVEL - 1, wz) != .Water do return

	// Weighted so the common little fish/squid still dominate, with the newer
	// dolphin/pufferfish/jellyfish showing up as rarer finds.
	kinds := [?]MobKind{.Fish, .Fish, .Squid, .Squid, .Dolphin, .Pufferfish, .Jellyfish}
	kind := kinds[rng_int(len(kinds))]
	append(
		mobs,
		Mob {
			kind = kind,
			pos = Vec3{f32(wx) + 0.5, f32(SEA_LEVEL - 1), f32(wz) + 0.5},
			yaw = rng_range(0, 2 * math.PI),
			ai_timer = rng_range(0, 2),
			health = kind == .Dolphin ? 6 : 4,
		},
	)
}

// Hostile spawn: zombies/skeletons appear at night on solid ground.
hostile_try_spawn :: proc(w: ^World, mobs: ^[dynamic]Mob, player_pos: Vec3) {
	ang := rng_range(0, 2 * math.PI)
	dist := rng_range(24, 46)
	wx := int(player_pos.x + math.cos(ang) * dist)
	wz := int(player_pos.z + math.sin(ang) * dist)
	if mobs_crowded(mobs, wx, wz) do return

	sy, surf := surface_y(w, wx, wz)
	if sy < 0 do return
	if surf == .Water do return
	if world_block(w, wx, sy + 1, wz) == .Water do return
	if block_is_solid(world_block(w, wx, sy + 1, wz)) do return

	kind: MobKind = rng_f32() < 0.5 ? .Zombie : .Skeleton
	hp := kind == .Zombie ? 12 : 8
	append(
		mobs,
		Mob {
			kind = kind,
			pos = Vec3{f32(wx) + 0.5, f32(sy + 1), f32(wz) + 0.5},
			yaw = rng_range(0, 2 * math.PI),
			ai_timer = rng_range(0, 2),
			health = hp,
		},
	)
}

// Debug: force-spawn n mobs (cycling kinds) on surfaces around `center`.
mob_debug_populate :: proc(w: ^World, mobs: ^[dynamic]Mob, center: Vec3, n: int) {
	for k in 0 ..< n {
		wx := int(center.x) + (rng_int(20) - 10)
		wz := int(center.z) + (rng_int(20) - 10)
		world_ensure_chunk(w, Ivec2{floor_div(wx, CHUNK_W), floor_div(wz, CHUNK_D)})
		sy, _ := surface_y(w, wx, wz)
		if sy < 0 do continue
		if world_block(w, wx, sy + 1, wz) == .Water do continue
		if block_is_solid(world_block(w, wx, sy + 1, wz)) do continue
		append(
			mobs,
			Mob {
				kind = MobKind(k % MOB_KIND_COUNT),
				pos = Vec3{f32(wx) + 0.5, f32(sy + 1), f32(wz) + 0.5},
				yaw = rng_range(0, 2 * math.PI),
				ai_timer = rng_range(0, 2),
				health = 6,
			},
		)
	}
}

// Ages a mob, and — for grazing-eligible mobs (not hostile, not aquatic,
// not Ghast, not a baby) — accumulates hunger and either relieves it by
// grazing nearby grass (converting it to dirt) or, once hunger crosses
// MOB_STARVE_THRESHOLD, applies starvation damage. Uses the same
// fractional-accumulator pattern as the existing daylight-burn code so
// sub-1-hp/frame rates still deal whole-point damage over time. Not
// file-private: tests call it directly to exercise grazing/starvation
// without mobs_update's random spawn rolls.
mob_life_tick :: proc(w: ^World, m: ^Mob, dt: f32) {
	m.age += dt
	if m.age > MOB_OLD_AGE {
		m.old_age_accum += MOB_OLD_AGE_DPS * dt
		if m.old_age_accum >= 1.0 {
			d := int(m.old_age_accum)
			m.health -= d
			m.old_age_accum -= f32(d)
			if m.death_cause == .None do m.death_cause = .OldAge
		}
	}

	if mob_is_hostile(m.kind) || mob_is_aquatic(m.kind) || m.kind == .Ghast || m.is_baby {
		return
	}

	if m.graze_cd > 0 do m.graze_cd -= dt
	m.hunger_level += MOB_HUNGER_RATE * dt

	if m.graze_cd <= 0 {
		fx := int(math.floor(m.pos.x))
		fy := int(math.floor(m.pos.y)) - 1
		fz := int(math.floor(m.pos.z))
		if world_block(w, fx, fy, fz) == .Grass {
			world_set_block(w, fx, fy, fz, .Dirt)
			net_send_edit(fx, fy, fz, .Dirt, w.dimension)
			m.hunger_level = max(0, m.hunger_level - MOB_GRAZE_RELIEF)
			m.graze_cd = MOB_GRAZE_COOLDOWN
		}
	}

	if m.hunger_level > MOB_STARVE_THRESHOLD {
		m.starve_accum += MOB_STARVE_DPS * dt
		if m.starve_accum >= 1.0 {
			d := int(m.starve_accum)
			m.health -= d
			m.starve_accum -= f32(d)
			if m.death_cause == .None do m.death_cause = .Starvation
		}
	}
}

@(private = "file")
mob_death_color :: proc(cause: MobDeathCause) -> Vec3 {
	#partial switch cause {
	case .OldAge:
		return Vec3{0.75, 0.75, 0.7}
	case .Starvation:
		return Vec3{0.55, 0.5, 0.35}
	case .Predator:
		return Vec3{0.65, 0.12, 0.12}
	case .Burned:
		return Vec3{0.9, 0.5, 0.15}
	case .Fall:
		return Vec3{0.6, 0.6, 0.65}
	}
	return Vec3{}
}

// The bitmap font only has uppercase letters, so fmt's default %v (which
// would print mixed-case enum names like "Zombie") can't be used directly
// in toasts.
@(private = "file")
mob_kind_label :: proc(k: MobKind) -> string {
	switch k {
	case .Pig:
		return "PIG"
	case .Sheep:
		return "SHEEP"
	case .Cow:
		return "COW"
	case .Chicken:
		return "CHICKEN"
	case .Rabbit:
		return "RABBIT"
	case .Horse:
		return "HORSE"
	case .Zombie:
		return "ZOMBIE"
	case .Skeleton:
		return "SKELETON"
	case .Piglin:
		return "PIGLIN"
	case .Ghast:
		return "GHAST"
	case .Fish:
		return "FISH"
	case .Squid:
		return "SQUID"
	case .Dolphin:
		return "DOLPHIN"
	case .Pufferfish:
		return "PUFFERFISH"
	case .Jellyfish:
		return "JELLYFISH"
	case .SnowLeopard:
		return "SNOW LEOPARD"
	case .Camel:
		return "CAMEL"
	case .Llama:
		return "LLAMA"
	}
	return ""
}

@(private = "file")
mob_death_label :: proc(cause: MobDeathCause) -> string {
	#partial switch cause {
	case .OldAge:
		return "DIED OF OLD AGE"
	case .Starvation:
		return "STARVED"
	case .Predator:
		return "WAS EATEN"
	case .Burned:
		return "BURNED UP"
	case .Fall:
		return "FELL TO ITS DEATH"
	}
	return ""
}

// Toast + particle burst for a natural-causes death, shown only when the
// player is plausibly close enough to have noticed. Player-attack kills are
// handled separately by mob_hit, which has its own immediate feedback.
@(private = "file")
mob_death_feedback :: proc(w: ^World, m: Mob, player_pos: Vec3) {
	if m.death_cause == .None do return
	dx := m.pos.x - player_pos.x
	dz := m.pos.z - player_pos.z
	if dx * dx + dz * dz > MOB_DEATH_FEEDBACK_RANGE * MOB_DEATH_FEEDBACK_RANGE do return
	col := mob_death_color(m.death_cause)
	particle_spawn_eat(&w.particles, m.pos + Vec3{0, MOB_DIMS[m.kind].h * 0.5, 0}, col)
	toast_show(fmt.tprintf("%s %s", mob_kind_label(m.kind), mob_death_label(m.death_cause)))
}

// Update all mobs: spawning (passive anytime, zombies at night), per-mob AI,
// daylight burn for zombies, and far-away / dead despawn.
mobs_update :: proc(w: ^World, p: ^Player, mobs: ^[dynamic]Mob, dt: f32) {
	player_pos := p.pos
	if w.dimension == .Nether {
		// nether_try_spawn only ever produces Piglins/Ghasts, both hostile
		if !g_settings.peaceful && rng_f32() < 0.04 do nether_try_spawn(w, mobs, player_pos)
	} else {
		if rng_f32() < 0.03 do mob_try_spawn(w, mobs, player_pos)
		if rng_f32() < 0.02 do water_try_spawn(w, mobs, player_pos)
		if !g_settings.peaceful && is_night(w.time_of_day) && rng_f32() < 0.05 {
			hostile_try_spawn(w, mobs, player_pos)
		}
	}

	i := 0
	for i < len(mobs^) {
		m := &mobs^[i]
		// Peaceful mode: clear out any hostiles that already existed the
		// moment it's turned on, not just block future spawns.
		if g_settings.peaceful && mob_is_hostile(m.kind) {
			mobs^[i] = mobs^[len(mobs^) - 1]
			pop(mobs)
			continue
		}
		// Safety net: if an aquatic mob's cell is ever no longer water (e.g. the
		// world changed under it), remove it instead of letting it sit on land.
		if mob_is_aquatic(m.kind) &&
		   world_block(w, int(math.floor(m.pos.x)), int(math.floor(m.pos.y)), int(math.floor(m.pos.z))) !=
			   .Water {
			mobs^[i] = mobs^[len(mobs^) - 1]
			pop(mobs)
			continue
		}
		if mob_burns_in_day(m.kind) && is_day(w.time_of_day) {
			// dt-scaled burn: ~6 hp/s, so a 12-hp zombie lasts ~2s in daylight
			m.burn_accum += 6.0 * dt
			if m.burn_accum >= 1.0 {
				d := int(m.burn_accum)
				m.health -= d
				m.burn_accum -= f32(d)
				if m.death_cause == .None do m.death_cause = .Burned
			}
		}
		mob_life_tick(w, m, dt)
		dx := m.pos.x - player_pos.x
		dz := m.pos.z - player_pos.z
		if dx * dx + dz * dz > MOB_DESPAWN_DIST * MOB_DESPAWN_DIST || m.pos.y < -8 || m.health <= 0 {
			if m.health <= 0 do mob_death_feedback(w, m^, player_pos)
			mobs^[i] = mobs^[len(mobs^) - 1]
			pop(mobs)
			continue
		}
		// Fall damage, mirroring the player's physics.odin logic: track the
		// peak downward speed while airborne, then damage past FALL_SAFE the
		// instant it lands. mob_update is what actually runs body_physics
		// and sets m.on_ground, so the "was airborne" check must happen
		// before it and the landing check after.
		if !m.on_ground && m.vel.y < 0 {
			fs := -m.vel.y
			if fs > m.fall_speed do m.fall_speed = fs
		}
		was_air := !m.on_ground
		mob_update(w, p, m, i, dt)
		if m.on_ground {
			if was_air && m.fall_speed > FALL_SAFE {
				dmg := int((m.fall_speed - FALL_SAFE) * 0.5)
				m.health -= dmg
				if dmg > 0 && m.death_cause == .None do m.death_cause = .Fall
			}
			m.fall_speed = 0
		}
		i += 1
	}

	breed_pass(w, mobs, dt)
}

@(private = "file")
contains_int :: proc(arr: []int, v: int) -> bool {
	for x in arr do if x == v do return true
	return false
}

// Same-kind adult mobs both in love mode (fed Wheat via try_feed) within
// BREED_RADIUS make a baby. Indices (not pointers) are collected while
// scanning, and every append happens in a separate pass afterward — append
// can reallocate the backing array, so holding a &mobs^[i] pointer across it
// would risk a stale/use-after-free read. Not file-private: tests call it
// directly to exercise breeding without mobs_update's random spawn rolls.
breed_pass :: proc(w: ^World, mobs: ^[dynamic]Mob, dt: f32) {
	paired := make([dynamic]int, 0, 4, context.temp_allocator)
	births := make([dynamic]Mob, 0, 4, context.temp_allocator)
	for i in 0 ..< len(mobs^) {
		if contains_int(paired[:], i) do continue
		a := mobs^[i]
		if a.love_timer <= 0 || a.is_baby do continue
		for j in i + 1 ..< len(mobs^) {
			if contains_int(paired[:], j) do continue
			b := mobs^[j]
			if b.love_timer <= 0 || b.is_baby || b.kind != a.kind do continue
			dx := a.pos.x - b.pos.x
			dz := a.pos.z - b.pos.z
			if dx * dx + dz * dz > BREED_RADIUS * BREED_RADIUS do continue
			mobs^[i].love_timer = 0
			mobs^[j].love_timer = 0
			append(&paired, i, j)
			append(
				&births,
				Mob {
					kind = a.kind,
					pos = (a.pos + b.pos) * 0.5,
					yaw = a.yaw,
					is_baby = true,
					grow_timer = BABY_GROW_TIME,
					health = 6,
				},
			)
			break
		}
	}
	for baby in births {
		append(mobs, baby)
		audio_play(.Place, 0.4)
		particle_spawn_eat(&w.particles, baby.pos + Vec3{0, 0.4, 0}, LOVE_HEART_COLOR)
	}
}

// --- interaction ---
// Slab test: distance along a (normalised) ray to an AABB, if hit.
ray_aabb :: proc(orig, dir, bmin, bmax: Vec3) -> (bool, f32) {
	tmin: f32 = 0
	tmax: f32 = 1e30
	for a in 0 ..< 3 {
		if math.abs(dir[a]) < 1e-8 {
			if orig[a] < bmin[a] || orig[a] > bmax[a] do return false, 0
		} else {
			inv := 1.0 / dir[a]
			t1 := (bmin[a] - orig[a]) * inv
			t2 := (bmax[a] - orig[a]) * inv
			if t1 > t2 do t1, t2 = t2, t1
			if t1 > tmin do tmin = t1
			if t2 < tmax do tmax = t2
			if tmin > tmax do return false, 0
		}
	}
	return true, tmin
}

// Nearest mob under the ray within `reach`; returns index or -1.
mob_pick :: proc(mobs: ^[dynamic]Mob, eye, dir: Vec3, reach: f32) -> (int, f32) {
	best := -1
	best_t: f32 = reach
	for i in 0 ..< len(mobs^) {
		m := &mobs^[i]
		dims := MOB_DIMS[m.kind]
		bmin := Vec3{m.pos.x - dims.hw, m.pos.y, m.pos.z - dims.hw}
		bmax := Vec3{m.pos.x + dims.hw, m.pos.y + dims.h, m.pos.z + dims.hw}
		ok, t := ray_aabb(eye, dir, bmin, bmax)
		if ok && t < best_t {
			best = i
			best_t = t
		}
	}
	return best, best_t
}

LOVE_HEART_COLOR :: Vec3{0.95, 0.25, 0.45}

// Feed Wheat to a passive adult mob (R while aiming at it): puts it in love
// mode for BREED_LOVE_DURATION and bursts pink heart-colored particles above
// its head. If another same-kind mob is also in love mode nearby, breed_pass
// (run every mobs_update) pairs them off into a baby.
try_feed :: proc(w: ^World, p: ^Player, m: ^Mob) -> bool {
	if mob_is_hostile(m.kind) || mob_is_aquatic(m.kind) || m.kind == .Ghast || m.is_baby {
		return false
	}
	if p.wheat <= 0 {
		toast_show("FEED: NEED WHEAT")
		return true
	}
	if m.love_timer > 0 {
		toast_show("ALREADY IN LOVE MODE")
		return true
	}
	p.wheat -= 1
	m.love_timer = BREED_LOVE_DURATION
	audio_play(.Place, 0.4)
	toast_show("FED - LOOKING FOR A MATE")
	particle_spawn_eat(&w.particles, m.pos + Vec3{0, MOB_DIMS[m.kind].h + 0.2, 0}, LOVE_HEART_COLOR)
	return true
}

// Hit a mob: knockback + damage; on death drop food (passive) and remove.
mob_hit :: proc(w: ^World, idx: int, dir: Vec3, dmg: int) {
	m := &w.mobs[idx]
	m.health -= dmg
	m.vel.x += dir.x * 6.0
	m.vel.z += dir.z * 6.0
	m.vel.y = 6.0
	audio_play(.Hurt, 0.7)
	if m.health <= 0 {
		if !mob_is_hostile(m.kind) {
			item_spawn_food(&w.items, m.pos)
			item_spawn_food(&w.items, m.pos)
		}
		w.mobs[idx] = w.mobs[len(w.mobs) - 1]
		pop(&w.mobs)
	}
}
