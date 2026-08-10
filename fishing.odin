package main

import "core:fmt"
import "core:math"

// Fishing: hold a rod and cast at water. After a random wait a fish bites (a
// splash + prompt); reel in during the bite window to land it. Higher Fishing
// skill shortens the wait and adds bonus catches.

FISH_REACH :: f32(7.0) // how far ahead the bobber can land on water

// Find the water surface the player is aiming at (the first Water cell along the
// look ray, returned as the point just above it). ok=false if none in range.
fishing_target :: proc(w: ^World, eye, dir: Vec3) -> (pos: Vec3, ok: bool) {
	step := f32(0.25)
	for t := f32(1.0); t <= FISH_REACH; t += step {
		p := eye + dir * t
		bx := int(math.floor(p.x))
		by := int(math.floor(p.y))
		bz := int(math.floor(p.z))
		b := world_block(w, bx, by, bz)
		if b == .Water {
			return Vec3{f32(bx) + 0.5, f32(by) + 1.0, f32(bz) + 0.5}, true
		}
		if block_is_solid(b) do return {}, false // hit ground first
	}
	return {}, false
}

// Cast: sink the bobber and start the wait timer (shorter as Fishing levels up).
fishing_cast :: proc(w: ^World, p: ^Player, pos: Vec3) {
	p.fishing = true
	p.fish_pos = pos
	p.fish_bite = 0
	wait := rng_range(1.5, 4.5) - f32(p.skill_level[.Fishing]) * 0.15
	p.fish_timer = max(wait, 0.8)
	particle_spawn_splash(&w.particles, pos)
	audio_play(.Jump, 0.3)
}

// Reel in. A fish is landed only if it's mid-bite; otherwise the line comes back
// empty (an early reel just recasts next click).
fishing_reel :: proc(w: ^World, p: ^Player) {
	if p.fish_bite > 0 {
		fishing_catch(w, p)
	} else {
		p.fishing = false // reeled in early, nothing on the line
	}
}

@(private = "file")
fishing_catch :: proc(w: ^World, p: ^Player) {
	p.fishing = false
	p.fish_bite = 0
	r := rng_int(100)
	reward: BlockId = .RawFood
	if r >= 60 && r < 78 do reward = .Kelp
	else if r >= 78 && r < 88 do reward = .Bone
	else if r >= 88 && r < 95 do reward = .Leather
	else if r >= 95 do reward = .Bow // rare treasure
	inv_add(p, reward, 1)
	skill_gain(p, .Fishing, 6)
	if rng_int(100) < p.skill_level[.Fishing] * 5 do inv_add(p, reward, 1) // bonus catch
	particle_spawn_splash(&w.particles, p.fish_pos)
	audio_play(.Splash, 0.7)
	toast_show(fmt.tprintf("CAUGHT %s!", block_name(reward)))
}

// Per-frame fishing upkeep (called from player_tick): tick the wait toward a
// bite, then run the reel-in window; the bobber ripples the whole time.
fishing_tick :: proc(w: ^World, p: ^Player, dt: f32) {
	if !p.fishing do return
	// the bobber's own little ripple
	if rng_f32() < dt * 6 {
		append(
			&w.particles,
			Particle {
				pos = p.fish_pos + Vec3{rng_range(-0.15, 0.15), 0.02, rng_range(-0.15, 0.15)},
				vel = Vec3{rng_range(-0.3, 0.3), rng_range(0.1, 0.4), rng_range(-0.3, 0.3)},
				max_life = 0.4,
				color = Vec3{0.7, 0.82, 0.95},
				size = 0.04,
			},
		)
	}
	if p.fish_bite > 0 {
		p.fish_bite -= dt
		if p.fish_bite <= 0 {
			p.fishing = false
			toast_show("THE FISH GOT AWAY")
		}
		return
	}
	p.fish_timer -= dt
	if p.fish_timer <= 0 {
		p.fish_bite = 2.0 // reel-in window
		particle_spawn_splash(&w.particles, p.fish_pos)
		audio_play(.Splash, 0.5)
		toast_show("FISH ON! RIGHT-CLICK TO REEL IN")
	}
}
