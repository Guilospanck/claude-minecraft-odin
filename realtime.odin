package main

import "core:c/libc"

// Local wall-clock time as a fraction of the day (0=midnight .. 0.5=noon),
// matching world.time_of_day's convention exactly. Used when
// g_settings.real_time is on, so the in-game day/night cycle mirrors the
// player's actual day — it's morning in-game when it's morning for them.
// libc.localtime consults the OS timezone database, so this is genuinely
// local time, not UTC.
real_time_fraction :: proc() -> f32 {
	now := libc.time(nil)
	info := libc.localtime(&now)
	if info == nil do return 0.3 // fallback if the platform ever refuses (shouldn't happen)
	secs := f32(info.tm_hour) * 3600 + f32(info.tm_min) * 60 + f32(info.tm_sec)
	return secs / 86400.0
}
