package main

import "core:math"

// Integer hash (splitmix64-style finaliser).
hash_u64 :: proc(x: u64) -> u64 {
	v := x
	v ~= v >> 33
	v *= 0xff51afd7ed558ccd
	v ~= v >> 33
	v *= 0xc4ceb9fe1a85ec53
	v ~= v >> 33
	return v
}

// Lattice value in [-1, 1] for an integer 2D point.
lattice2 :: proc(seed: u64, ix, iz: int) -> f32 {
	n := u64(i64(ix)) * 0x9E3779B97F4A7C15
	n ~= u64(i64(iz)) * 0xC2B2AE3D27D4EB4F
	n ~= seed
	n = hash_u64(n)
	return f32(n >> 40) / f32(1 << 24) * 2.0 - 1.0
}

lattice3 :: proc(seed: u64, ix, iy, iz: int) -> f32 {
	n := u64(i64(ix)) * 0x9E3779B97F4A7C15
	n ~= u64(i64(iy)) * 0xC2B2AE3D27D4EB4F
	n ~= u64(i64(iz)) * 0x165667B19E3779F9
	n ~= seed
	n = hash_u64(n)
	return f32(n >> 40) / f32(1 << 24) * 2.0 - 1.0
}

@(private = "file")
smooth :: #force_inline proc(t: f32) -> f32 {
	return t * t * (3.0 - 2.0 * t)
}

// Smoothed value noise, output in [-1, 1].
value_noise2 :: proc(seed: u64, x, z: f32) -> f32 {
	x0 := int(math.floor(x))
	z0 := int(math.floor(z))
	fx := smooth(x - f32(x0))
	fz := smooth(z - f32(z0))
	c00 := lattice2(seed, x0, z0)
	c10 := lattice2(seed, x0 + 1, z0)
	c01 := lattice2(seed, x0, z0 + 1)
	c11 := lattice2(seed, x0 + 1, z0 + 1)
	a := lerpf(c00, c10, fx)
	b := lerpf(c01, c11, fx)
	return lerpf(a, b, fz)
}

value_noise3 :: proc(seed: u64, x, y, z: f32) -> f32 {
	x0 := int(math.floor(x))
	y0 := int(math.floor(y))
	z0 := int(math.floor(z))
	fx := smooth(x - f32(x0))
	fy := smooth(y - f32(y0))
	fz := smooth(z - f32(z0))

	c000 := lattice3(seed, x0, y0, z0)
	c100 := lattice3(seed, x0 + 1, y0, z0)
	c010 := lattice3(seed, x0, y0 + 1, z0)
	c110 := lattice3(seed, x0 + 1, y0 + 1, z0)
	c001 := lattice3(seed, x0, y0, z0 + 1)
	c101 := lattice3(seed, x0 + 1, y0, z0 + 1)
	c011 := lattice3(seed, x0, y0 + 1, z0 + 1)
	c111 := lattice3(seed, x0 + 1, y0 + 1, z0 + 1)

	x00 := lerpf(c000, c100, fx)
	x10 := lerpf(c010, c110, fx)
	x01 := lerpf(c001, c101, fx)
	x11 := lerpf(c011, c111, fx)
	y0v := lerpf(x00, x10, fy)
	y1v := lerpf(x01, x11, fy)
	return lerpf(y0v, y1v, fz)
}

// Fractal Brownian motion, output in [-1, 1].
fbm2 :: proc(seed: u64, x, z: f32, octaves: int) -> f32 {
	amp: f32 = 1.0
	freq: f32 = 1.0
	sum: f32 = 0.0
	norm: f32 = 0.0
	for i in 0 ..< octaves {
		sum += amp * value_noise2(seed + u64(i) * 1013904223, x * freq, z * freq)
		norm += amp
		amp *= 0.5
		freq *= 2.0
	}
	return sum / norm
}

fbm3 :: proc(seed: u64, x, y, z: f32, octaves: int) -> f32 {
	amp: f32 = 1.0
	freq: f32 = 1.0
	sum: f32 = 0.0
	norm: f32 = 0.0
	for i in 0 ..< octaves {
		sum += amp * value_noise3(seed + u64(i) * 1013904223, x * freq, y * freq, z * freq)
		norm += amp
		amp *= 0.5
		freq *= 2.0
	}
	return sum / norm
}
