package main

// Live, in-memory game settings adjusted from the settings menu (O).
Settings :: struct {
	mouse_sens:    f32,
	fov_deg:       f32,
	render_radius: int,
	volume:        f32,
	day_length:    f32, // used only when real_time is off
	real_time:     bool, // sync day/night to the player's actual local time
	peaceful:      bool, // disable hostile mob spawning (zombies, skeletons, piglins, ghasts)
}

g_settings := Settings {
	mouse_sens    = 0.0022,
	fov_deg       = 70,
	render_radius = 6,
	volume        = 1.0,
	day_length    = 1800,
	real_time     = true,
	peaceful      = false,
}

g_show_settings: bool
g_settings_sel: int

SETTINGS_COUNT :: 7

settings_adjust :: proc(delta: int) {
	d := f32(delta)
	switch g_settings_sel {
	case 0:
		g_settings.mouse_sens = clamp(g_settings.mouse_sens + d * 0.0003, 0.0005, 0.01)
	case 1:
		g_settings.fov_deg = clamp(g_settings.fov_deg + d * 5, 40, 110)
	case 2:
		g_settings.render_radius = clamp(g_settings.render_radius + delta, 2, 8)
	case 3:
		g_settings.volume = clamp(g_settings.volume + d * 0.1, 0, 1)
	case 4:
		g_settings.real_time = !g_settings.real_time // either direction toggles
	case 5:
		g_settings.day_length = clamp(g_settings.day_length + d * 120, 300, 7200)
	case 6:
		g_settings.peaceful = !g_settings.peaceful
	}
}
