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


// Quintic fade curve (true Perlin interpolant): flatter at the ends than a
// cubic smoothstep, which is what removes the axis-aligned "grid" look
// plain value noise has.
@(private = "file")
fade :: #force_inline proc(t: f32) -> f32 {
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
}

// Unit gradient direction for a 2D lattice point, from a hash angle.
@(private = "file")
grad2 :: #force_inline proc(seed: u64, ix, iz: int) -> Vec2 {
	n := u64(i64(ix)) * 0x9E3779B97F4A7C15
	n ~= u64(i64(iz)) * 0xC2B2AE3D27D4EB4F
	n ~= seed
	n = hash_u64(n)
	angle := f32(n >> 40) / f32(1 << 24) * 2.0 * math.PI
	return Vec2{math.cos(angle), math.sin(angle)}
}

// Ken Perlin's classic 12 edge-midpoint gradients — avoids per-corner trig
// in the 3D noise, which is the hot path (caves/ore, evaluated per voxel).
@(private = "file")
GRAD3 := [12]Vec3 {
	{1, 1, 0}, {-1, 1, 0}, {1, -1, 0}, {-1, -1, 0},
	{1, 0, 1}, {-1, 0, 1}, {1, 0, -1}, {-1, 0, -1},
	{0, 1, 1}, {0, -1, 1}, {0, 1, -1}, {0, -1, -1},
}

@(private = "file")
grad3 :: #force_inline proc(seed: u64, ix, iy, iz: int) -> Vec3 {
	n := u64(i64(ix)) * 0x9E3779B97F4A7C15
	n ~= u64(i64(iy)) * 0x165667B19E3779F9
	n ~= u64(i64(iz)) * 0xC2B2AE3D27D4EB4F
	n ~= seed
	n = hash_u64(n)
	return GRAD3[n % 12]
}

// Gradient (Perlin-style) noise, output renormalised to roughly [-1, 1].
// Smoother and less axis-aligned than plain value noise, since each
// lattice point contributes a gradient direction (dotted with the offset
// to the sample point) instead of a flat random value.
value_noise2 :: proc(seed: u64, x, z: f32) -> f32 {
	x0 := int(math.floor(x))
	z0 := int(math.floor(z))
	fx := x - f32(x0)
	fz := z - f32(z0)
	g00 := grad2(seed, x0, z0)
	g10 := grad2(seed, x0 + 1, z0)
	g01 := grad2(seed, x0, z0 + 1)
	g11 := grad2(seed, x0 + 1, z0 + 1)
	n00 := g00.x * fx + g00.y * fz
	n10 := g10.x * (fx - 1) + g10.y * fz
	n01 := g01.x * fx + g01.y * (fz - 1)
	n11 := g11.x * (fx - 1) + g11.y * (fz - 1)
	u := fade(fx)
	v := fade(fz)
	a := lerpf(n00, n10, u)
	b := lerpf(n01, n11, u)
	return clamp(lerpf(a, b, v) * 1.4142, -1.0, 1.0)
}

value_noise3 :: proc(seed: u64, x, y, z: f32) -> f32 {
	x0 := int(math.floor(x))
	y0 := int(math.floor(y))
	z0 := int(math.floor(z))
	fx := x - f32(x0)
	fy := y - f32(y0)
	fz := z - f32(z0)

	g000 := grad3(seed, x0, y0, z0)
	g100 := grad3(seed, x0 + 1, y0, z0)
	g010 := grad3(seed, x0, y0 + 1, z0)
	g110 := grad3(seed, x0 + 1, y0 + 1, z0)
	g001 := grad3(seed, x0, y0, z0 + 1)
	g101 := grad3(seed, x0 + 1, y0, z0 + 1)
	g011 := grad3(seed, x0, y0 + 1, z0 + 1)
	g111 := grad3(seed, x0 + 1, y0 + 1, z0 + 1)

	n000 := g000.x * fx + g000.y * fy + g000.z * fz
	n100 := g100.x * (fx - 1) + g100.y * fy + g100.z * fz
	n010 := g010.x * fx + g010.y * (fy - 1) + g010.z * fz
	n110 := g110.x * (fx - 1) + g110.y * (fy - 1) + g110.z * fz
	n001 := g001.x * fx + g001.y * fy + g001.z * (fz - 1)
	n101 := g101.x * (fx - 1) + g101.y * fy + g101.z * (fz - 1)
	n011 := g011.x * fx + g011.y * (fy - 1) + g011.z * (fz - 1)
	n111 := g111.x * (fx - 1) + g111.y * (fy - 1) + g111.z * (fz - 1)

	u := fade(fx)
	v := fade(fy)
	w := fade(fz)
	x00 := lerpf(n000, n100, u)
	x10 := lerpf(n010, n110, u)
	x01 := lerpf(n001, n101, u)
	x11 := lerpf(n011, n111, u)
	y0v := lerpf(x00, x10, v)
	y1v := lerpf(x01, x11, v)
	return clamp(lerpf(y0v, y1v, w) * 1.7, -1.0, 1.0)
}

// Piecewise-linear-with-smoothstep spline: control points must be sorted by
// x. Clamps outside the range, interpolates (smoothly, not linearly)
// between the bracketing pair otherwise. Used to map continentalness /
// erosion noise to terrain height and amplitude the way Minecraft's newer
// world generator does, instead of a flat linear formula.
SplinePoint :: struct {
	x, y: f32,
}

spline_eval :: proc(pts: []SplinePoint, x: f32) -> f32 {
	if len(pts) == 0 do return 0
	if x <= pts[0].x do return pts[0].y
	if x >= pts[len(pts) - 1].x do return pts[len(pts) - 1].y
	for i in 0 ..< len(pts) - 1 {
		a := pts[i]
		b := pts[i + 1]
		if x >= a.x && x <= b.x {
			t := (x - a.x) / (b.x - a.x)
			t = t * t * (3.0 - 2.0 * t) // smoothstep between control points
			return lerpf(a.y, b.y, t)
		}
	}
	return pts[len(pts) - 1].y
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
