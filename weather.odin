package main

// Overworld-only weather: a wet/dry state toggles on a timer, and a slowly
// drifting wind vector blows precipitation sideways. When a wet spell begins it
// rolls a STORM LEVEL (light/normal/heavy); what actually falls then depends on
// both that level and the biome the player is standing in — so the same storm
// reads as a light drizzle or a full thunderstorm in temperate country, gentle
// snowfall or driving hail up in the cold, and a sandstorm out in the deserts
// (which stay calm during lighter spells). Weather is part of the biome rather
// than a uniform sheet everywhere.

WEATHER_DRY_MIN :: f32(90.0)
WEATHER_DRY_MAX :: f32(240.0)
WEATHER_RAIN_MIN :: f32(25.0)
WEATHER_RAIN_MAX :: f32(70.0)
RAIN_CHANCE :: f32(0.35) // odds a dry spell ending turns into a wet one vs. staying dry

WIND_MAX :: f32(6.0) // peak horizontal drift speed of precipitation

Precip :: enum {
	None, // dry: deserts in a light spell, everywhere when clear
	Drizzle, // temperate, light: a few thin slow drops
	Rain, // temperate, normal
	Thunder, // temperate, heavy: driving rain + lightning flashes
	Snow, // cold, light/normal: fat drifting flakes
	Hail, // cold, heavy: small fast icy pellets
	Sandstorm, // desert, heavy: sand blown near-horizontal in a tan haze
}

// What precipitation a biome gets during a wet spell of a given intensity
// (1=light, 2=normal, 3=heavy). Not file-private: tests exercise it directly.
biome_precip :: proc(b: Biome, level: int = 2) -> Precip {
	#partial switch b {
	case .Snow, .Taiga, .Mountains:
		return level >= 3 ? .Hail : .Snow // cold: snow, or hail in a heavy storm
	case .Desert, .Badlands:
		return level >= 2 ? .Sandstorm : .None // deserts kick up sand only in strong spells
	}
	// temperate country: drizzle -> rain -> thunderstorm as the storm intensifies
	switch {
	case level <= 1:
		return .Drizzle
	case level == 2:
		return .Rain
	}
	return .Thunder
}

// A rain-type precip drives the falling-water ambience; the others are quiet.
precip_is_wet :: proc(p: Precip) -> bool {
	return p == .Drizzle || p == .Rain || p == .Thunder
}

weather_tick :: proc(w: ^World, dt: f32) {
	if w.dimension != .Overworld {
		w.raining = false
		w.storm_level = 0
		w.flash = 0
		return
	}

	// Wind random-walks slowly and stays bounded, so the drift shifts over
	// time instead of being a fixed constant. Heavier storms blow harder.
	gust := f32(1) + f32(w.storm_level) * 0.4
	w.wind_x = clamp(w.wind_x + rng_range(-1, 1) * dt, -WIND_MAX * gust, WIND_MAX * gust)
	w.wind_z = clamp(w.wind_z + rng_range(-1, 1) * dt, -WIND_MAX * gust, WIND_MAX * gust)

	if w.flash > 0 do w.flash = max(0, w.flash - dt * 3.0) // lightning flash decays fast

	w.weather_timer -= dt
	if w.weather_timer > 0 do return

	if w.raining {
		w.raining = false
		w.storm_level = 0
		w.weather_timer = rng_range(WEATHER_DRY_MIN, WEATHER_DRY_MAX)
	} else if rng_f32() < RAIN_CHANCE {
		w.raining = true
		// weighted intensity: light spells common, full storms rare
		r := rng_f32()
		w.storm_level = r < 0.5 ? 1 : (r < 0.85 ? 2 : 3)
		w.weather_timer = rng_range(WEATHER_RAIN_MIN, WEATHER_RAIN_MAX)
	} else {
		w.weather_timer = rng_range(WEATHER_DRY_MIN, WEATHER_DRY_MAX)
	}
}

// During a thunderstorm, occasionally fire a lightning flash (a brief screen
// brighten handled in render). Called from the main loop, which knows the
// precip actually falling on the player.
weather_maybe_lightning :: proc(w: ^World, precip: Precip, dt: f32) {
	if precip == .Thunder && rng_f32() < dt * 0.22 {
		w.flash = 1.0
	}
}

// Per-precip visual parameters for the falling particles.
@(private = "file")
PrecipStyle :: struct {
	count:     int,
	fall:      f32, // vertical velocity (negative = down)
	wind_mul:  f32, // how strongly the wind carries it sideways
	life:      f32,
	size:      f32,
	color:     Vec3,
	spawn_low: bool, // sandstorm spawns near ground level, not high up
}

@(private = "file")
precip_style :: proc(kind: Precip) -> PrecipStyle {
	switch kind {
	case .Drizzle:
		return {4, -9, 1, 1.3, 0.03, {0.62, 0.72, 0.9}, false}
	case .Rain:
		return {8, -14, 1, 1.1, 0.04, {0.6, 0.7, 0.88}, false}
	case .Thunder:
		return {13, -19, 1.2, 0.9, 0.045, {0.55, 0.63, 0.82}, false}
	case .Snow:
		return {8, -3, 1, 2.4, 0.08, {0.95, 0.96, 0.98}, false}
	case .Hail:
		return {10, -17, 0.8, 0.9, 0.055, {0.86, 0.92, 0.98}, false}
	case .Sandstorm:
		return {16, -2, 2.6, 0.8, 0.07, {0.78, 0.64, 0.38}, true}
	case .None:
		return {}
	}
	return {}
}

// Sheets a few precipitation particles near the player each frame, blown along
// by the wind, styled per weather type. Reuses the generic Particle system
// (gravity + settle-on-ground already fades a drop/flake that lands).
precip_particles_spawn :: proc(ps: ^[dynamic]Particle, center: Vec3, kind: Precip, wind_x, wind_z: f32) {
	if kind == .None do return
	s := precip_style(kind)
	for _ in 0 ..< s.count {
		y_off := s.spawn_low ? rng_range(0.5, 5.0) : rng_range(10, 16)
		append(
			ps,
			Particle {
				pos = Vec3{center.x + rng_range(-9, 9), center.y + y_off, center.z + rng_range(-9, 9)},
				vel = Vec3{wind_x * s.wind_mul, s.fall, wind_z * s.wind_mul},
				max_life = s.life,
				color = s.color,
				size = s.size,
			},
		)
	}
}
