package main

import "core:math"
import "core:math/linalg"

// Forward look vector from yaw/pitch. yaw=0,pitch=0 looks toward -Z.
camera_front :: proc(yaw, pitch: f32) -> Vec3 {
	cp := math.cos(pitch)
	return Vec3{math.sin(yaw) * cp, math.sin(pitch), -math.cos(yaw) * cp}
}

view_matrix :: proc(eye: Vec3, yaw, pitch: f32) -> Mat4 {
	f := camera_front(yaw, pitch)
	return linalg.matrix4_look_at_f32(eye, eye + f, Vec3{0, 1, 0})
}

proj_matrix :: proc(aspect: f32, extra_fov_deg: f32 = 0) -> Mat4 {
	fov := (g_settings.fov_deg + extra_fov_deg) * (3.141592653589793 / 180.0)
	return linalg.matrix4_perspective_f32(fov, aspect, 0.1, 1000.0)
}
