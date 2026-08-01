package main

import "core:math"
import "core:math/linalg"

RayHit :: struct {
	hit:            bool,
	bx, by, bz:     int, // hit block
	nx, ny, nz:     int, // face normal (points back toward the ray origin)
}

@(private = "file")
RAY_BIG :: f32(1e30)

// Distance along the ray to the first voxel boundary on one axis.
@(private = "file")
ray_tmax :: proc(s, ds: f32) -> f32 {
	if ds == 0 do return RAY_BIG
	if ds > 0 do return (math.floor(s) + 1 - s) / ds
	return (s - math.floor(s)) / -ds
}

// Amanatides & Woo voxel traversal. Stops at the first solid block.
raycast :: proc(w: ^World, origin, dir: Vec3, max_dist: f32) -> RayHit {
	d := linalg.normalize(dir)

	x := int(math.floor(origin.x))
	y := int(math.floor(origin.y))
	z := int(math.floor(origin.z))

	step_x := d.x > 0 ? 1 : (d.x < 0 ? -1 : 0)
	step_y := d.y > 0 ? 1 : (d.y < 0 ? -1 : 0)
	step_z := d.z > 0 ? 1 : (d.z < 0 ? -1 : 0)

	t_max_x := ray_tmax(origin.x, d.x)
	t_max_y := ray_tmax(origin.y, d.y)
	t_max_z := ray_tmax(origin.z, d.z)

	t_delta_x := d.x != 0 ? math.abs(1.0 / d.x) : RAY_BIG
	t_delta_y := d.y != 0 ? math.abs(1.0 / d.y) : RAY_BIG
	t_delta_z := d.z != 0 ? math.abs(1.0 / d.z) : RAY_BIG

	nx, ny, nz := 0, 0, 0
	t: f32 = 0

	for t <= max_dist {
		if block_is_solid(world_block(w, x, y, z)) {
			return RayHit{true, x, y, z, nx, ny, nz}
		}
		if t_max_x < t_max_y {
			if t_max_x < t_max_z {
				x += step_x
				t = t_max_x
				t_max_x += t_delta_x
				nx, ny, nz = -step_x, 0, 0
			} else {
				z += step_z
				t = t_max_z
				t_max_z += t_delta_z
				nx, ny, nz = 0, 0, -step_z
			}
		} else {
			if t_max_y < t_max_z {
				y += step_y
				t = t_max_y
				t_max_y += t_delta_y
				nx, ny, nz = 0, -step_y, 0
			} else {
				z += step_z
				t = t_max_z
				t_max_z += t_delta_z
				nx, ny, nz = 0, 0, -step_z
			}
		}
	}
	return RayHit{hit = false}
}
