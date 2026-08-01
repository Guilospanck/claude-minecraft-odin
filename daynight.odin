package main

import "core:math"

DAY_LENGTH :: f32(300.0) // seconds for one full day/night cycle

@(private = "file")
NIGHT_SKY :: Vec3{0.02, 0.03, 0.08}
@(private = "file")
DAY_SKY :: Vec3{0.55, 0.72, 0.92}
@(private = "file")
DUSK_SKY :: Vec3{0.85, 0.45, 0.30}

@(private = "file")
smoothstep :: proc(e0, e1, x: f32) -> f32 {
	t := clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
}

// Sky colour and ambient brightness (~0.2 night .. 1.0 day) for a time-of-day
// t in [0,1). Also returns the sun height (-1 midnight .. +1 noon).
daynight :: proc(t: f32) -> (sky: Vec3, ambient: f32, sun_height: f32) {
	sun_height = math.sin((t - 0.25) * 2 * math.PI)
	day := smoothstep(-0.05, 0.25, sun_height)
	// Night keeps a visible floor (~0.35) so you can still see; block lights
	// (glowstone) provide real brightness on top of this.
	ambient = 0.35 + 0.65 * day
	sky = NIGHT_SKY * (1 - day) + DAY_SKY * day

	// warm tint while the sun is near the horizon (dawn / dusk)
	near_horizon := 1 - smoothstep(0.0, 0.30, math.abs(sun_height))
	glow := near_horizon * smoothstep(-0.22, 0.06, sun_height)
	sky = sky * (1 - glow) + DUSK_SKY * glow
	return
}
