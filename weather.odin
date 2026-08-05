package main

// Simple overworld-only weather: rain toggles on a timer with a random
// duration each way. No storms/snow biomes — just a binary raining/dry state
// that dims the sky, tints the fog, and sheets rain particles near the player.

WEATHER_DRY_MIN :: f32(90.0)
WEATHER_DRY_MAX :: f32(240.0)
WEATHER_RAIN_MIN :: f32(25.0)
WEATHER_RAIN_MAX :: f32(70.0)
RAIN_CHANCE :: f32(0.35) // odds a dry spell ending turns into rain vs. staying dry

weather_tick :: proc(w: ^World, dt: f32) {
	if w.dimension != .Overworld {
		w.raining = false
		return
	}
	w.weather_timer -= dt
	if w.weather_timer > 0 do return

	if w.raining {
		w.raining = false
		w.weather_timer = rng_range(WEATHER_DRY_MIN, WEATHER_DRY_MAX)
	} else {
		w.raining = rng_f32() < RAIN_CHANCE
		w.weather_timer =
			w.raining ? rng_range(WEATHER_RAIN_MIN, WEATHER_RAIN_MAX) : rng_range(WEATHER_DRY_MIN, WEATHER_DRY_MAX)
	}
}

// Sheets a couple of falling raindrop particles near the player each frame.
// Reuses the generic Particle system (gravity + settle-on-ground already
// works fine for a drop that lands and quickly fades).
rain_particles_spawn :: proc(ps: ^[dynamic]Particle, center: Vec3) {
	for _ in 0 ..< 2 {
		append(
			ps,
			Particle {
				pos = Vec3 {
					center.x + rng_range(-8, 8),
					center.y + rng_range(10, 16),
					center.z + rng_range(-8, 8),
				},
				vel = Vec3{0, -14, 0},
				max_life = 1.1,
				color = Vec3{0.6, 0.7, 0.88},
				size = 0.035,
			},
		)
	}
}
