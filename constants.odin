package main

import "core:math/linalg"

// ---- type aliases ----
Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32
Ivec2 :: [2]int
Ivec3 :: [3]int
Mat4 :: linalg.Matrix4f32

// ---- world dimensions ----
CHUNK_W :: 16 // x
CHUNK_D :: 16 // z
CHUNK_H :: 128 // y
CHUNK_BLOCKS :: CHUNK_W * CHUNK_D * CHUNK_H

SEA_LEVEL :: 48

// ---- streaming ----
LOAD_RADIUS :: 6 // chunks generated/kept around the player
UNLOAD_RADIUS :: LOAD_RADIUS + 2 // chunks beyond this are saved + freed
MAX_GEN_PER_FRAME :: 6
MAX_MESH_PER_FRAME :: 8

// ---- player / camera ----
EYE_HEIGHT :: 1.62
PLAYER_HW :: 0.3 // half width/depth
PLAYER_H :: 1.8 // total height
FOV_DEG :: 70.0
FOV_RAD :: f32(FOV_DEG) * (3.141592653589793 / 180.0)
REACH :: 6.0

// ---- movement ----
GRAVITY :: 28.0
JUMP_SPEED :: 8.5
WALK_SPEED :: 5.5
SNEAK_MULT :: 0.32 // sneak (crouch) speed multiplier over WALK_SPEED
SPRINT_MULT :: 1.35 // sprint speed multiplier over WALK_SPEED
SPRINT_FOV :: 12.0 // extra FOV degrees at full sprint (widening zoom)
FLY_SPEED :: 18.0
TERMINAL_VEL :: 60.0

// ---- health / combat ----
MAX_HEALTH :: 20
HUNGER_MAX :: 20
OXYGEN_MAX :: f32(12.0) // seconds of air before drowning starts
EAT_ANIM_DURATION :: f32(0.5) // seconds the eat camera-bob / crumbs animation lasts
SWING_DURATION :: f32(0.28) // seconds the first-person held-item swing lasts
FALL_SAFE :: f32(14.0) // fall speed below this does no damage

// ---- render ----
FOG_START :: f32(CHUNK_W * (LOAD_RADIUS - 2))
FOG_END :: f32(CHUNK_W * (LOAD_RADIUS))
SKY_COLOR :: Vec3{0.55, 0.72, 0.92}

// ---- small utilities ----

// Floor division that rounds toward negative infinity (unlike Odin's `/`,
// which truncates toward zero). Needed to map world coords to chunk coords.
floor_div :: proc(a, b: int) -> int {
	q := a / b
	if (a % b != 0) && ((a < 0) != (b < 0)) {
		q -= 1
	}
	return q
}

floor_mod :: proc(a, b: int) -> int {
	m := a % b
	if m != 0 && ((m < 0) != (b < 0)) {
		m += b
	}
	return m
}

b2i :: #force_inline proc(v: bool) -> int {
	return v ? 1 : 0
}

iabs :: #force_inline proc(a: int) -> int {
	return a < 0 ? -a : a
}

lerpf :: #force_inline proc(a, b, t: f32) -> f32 {
	return a + (b - a) * t
}
