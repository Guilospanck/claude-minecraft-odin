package main

// Overworld-only weather: a wet/dry state toggles on a timer, and a slowly
// drifting wind vector blows precipitation sideways. What actually falls
// depends on the biome the player is standing in — rain in temperate/jungle
// country, snow up in the cold biomes, and nothing at all in the deserts
// (they stay dry even during a "wet" spell) — so weather reads as part of the
// biome rather than a uniform sheet everywhere.

WEATHER_DRY_MIN :: f32(90.0)
WEATHER_DRY_MAX :: f32(240.0)
WEATHER_RAIN_MIN :: f32(25.0)
WEATHER_RAIN_MAX :: f32(70.0)
RAIN_CHANCE :: f32(0.35) // odds a dry spell ending turns into a wet one vs. staying dry

WIND_MAX :: f32(6.0) // peak horizontal drift speed of precipitation

Precip :: enum {
	None, // deserts/badlands: dry even during a wet spell
	Rain,
	Snow,
}

// What precipitation a biome gets during a wet spell.
biome_precip :: proc(b: Biome) -> Precip {
	#partial switch b {
	case .Snow, .Taiga, .Mountains:
		return .Snow
	case .Desert, .Badlands:
		return .None // too dry to rain
	}
	return .Rain
}

weather_tick :: proc(w: ^World, dt: f32) {
	if w.dimension != .Overworld {
		w.raining = false
		return
	}

	// Wind random-walks slowly and stays bounded, so the drift shifts over
	// time instead of being a fixed constant.
	w.wind_x = clamp(w.wind_x + rng_range(-1, 1) * dt, -WIND_MAX, WIND_MAX)
	w.wind_z = clamp(w.wind_z + rng_range(-1, 1) * dt, -WIND_MAX, WIND_MAX)

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

// Sheets a few precipitation particles near the player each frame, blown along
// by the wind. Snow falls slowly in fat white flakes; rain is fast, thin and
// blue. Reuses the generic Particle system (gravity + settle-on-ground already
// handles a drop/flake that lands and fades).
precip_particles_spawn :: proc(ps: ^[dynamic]Particle, center: Vec3, kind: Precip, wind_x, wind_z: f32) {
	if kind == .None do return
	snow := kind == .Snow
	n := snow ? 3 : 2
	for _ in 0 ..< n {
		fall := snow ? f32(-3.0) : f32(-14.0) // flakes drift, drops plummet
		append(
			ps,
			Particle {
				pos = Vec3 {
					center.x + rng_range(-8, 8),
					center.y + rng_range(10, 16),
					center.z + rng_range(-8, 8),
				},
				vel = Vec3{wind_x, fall, wind_z},
				max_life = snow ? 2.4 : 1.1,
				color = snow ? Vec3{0.95, 0.96, 0.98} : Vec3{0.6, 0.7, 0.88},
				size = snow ? 0.07 : 0.035,
			},
		)
	}
}
