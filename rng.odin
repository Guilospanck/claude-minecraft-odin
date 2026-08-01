package main

// Tiny xorshift64 PRNG for gameplay randomness (mob wander/spawn). Seeded from
// the world seed at startup; determinism across runs isn't required here.
g_rng: u64 = 0x9E3779B97F4A7C15

rng_seed :: proc(s: u64) {
	g_rng = s == 0 ? 1 : s
}

rng_next :: proc() -> u64 {
	x := g_rng
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	g_rng = x
	return x
}

rng_f32 :: proc() -> f32 {
	return f32(rng_next() >> 40) / f32(1 << 24) // [0, 1)
}

rng_range :: proc(lo, hi: f32) -> f32 {
	return lo + (hi - lo) * rng_f32()
}

rng_int :: proc(n: int) -> int {
	if n <= 0 do return 0
	return int(rng_next() % u64(n))
}
