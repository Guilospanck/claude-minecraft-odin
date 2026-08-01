package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "vendor:glfw"

// Debug helper: generate a region and report the nearest grass/water/snow
// surface columns to the origin. Used to aim screenshots at varied terrain.
scan_biomes :: proc(w: ^World) {
	SR :: 8
	for cz in -SR ..= SR {
		for cx in -SR ..= SR {
			world_ensure_chunk(w, Ivec2{cx, cz})
		}
	}
	lim := SR * CHUNK_W
	best_g, best_w, best_s := 1 << 30, 1 << 30, 1 << 30
	gx, gy, gz, wx0, wy0, wz0, sx, sy0, sz := 0, 0, 0, 0, 0, 0, 0, 0, 0
	fg, fw, fs := false, false, false
	for wz in -lim ..< lim {
		for wx in -lim ..< lim {
			surf_y := -1
			surf_b := BlockId.Air
			for y := 110; y >= 1; y -= 1 {
				b := world_block(w, wx, y, wz)
				if b != .Air && b != .Water {
					surf_y = y
					surf_b = b
					break
				}
			}
			if surf_y < 0 do continue
			d := wx * wx + wz * wz
			if surf_b == .Grass && d < best_g {best_g = d;gx, gy, gz = wx, surf_y, wz;fg = true}
			if surf_b == .Snow && d < best_s {best_s = d;sx, sy0, sz = wx, surf_y, wz;fs = true}
			if world_block(w, wx, SEA_LEVEL, wz) == .Water && d < best_w {
				best_w = d
				wx0, wy0, wz0 = wx, SEA_LEVEL, wz
				fw = true
			}
		}
	}
	fmt.println("grass:", fg, gx, gy, gz)
	fmt.println("water:", fw, wx0, wy0, wz0)
	fmt.println("snow: ", fs, sx, sy0, sz)
}

// Highest solid block near the world origin, used as the spawn point.
spawn_pos :: proc(w: ^World) -> Vec3 {
	x, z := 8, 8
	for y := CHUNK_H - 1; y >= 1; y -= 1 {
		if block_is_solid(world_block(w, x, y, z)) {
			return Vec3{f32(x) + 0.5, f32(y + 1), f32(z) + 0.5}
		}
	}
	return Vec3{f32(x) + 0.5, f32(SEA_LEVEL + 2), f32(z) + 0.5}
}

main :: proc() {
	win := window_init(1280, 720, "Odin Minecraft")
	defer glfw.Terminate()

	render_init(atlas_load())
	hud_init()
	audio_init()
	defer audio_shutdown()

	save_ensure_dir()
	seed, ok := load_meta()
	if !ok {
		seed = hash_u64(u64(time.to_unix_nanoseconds(time.now())))
		save_meta(seed)
	}
	fmt.println("world seed:", seed)
	rng_seed(seed ~ 0xA5A5_5A5A_C3C3_3C3C)

	world: World
	world_init(&world, seed)
	defer world_save_all(&world)

	// One-off: locate nearby biomes for this seed, print, and exit.
	if os.get_env("MC_SCAN", context.allocator) != "" {
		scan_biomes(&world)
		os.exit(0)
	}

	// generate the spawn column before placing the player on it
	world_ensure_chunk(&world, Ivec2{0, 0})

	player: Player
	player_init(&player, spawn_pos(&world))

	// Optional camera override for screenshots/tests: MC_CAM="x,y,z,yaw,pitch"
	if s := os.get_env("MC_CAM", context.temp_allocator); s != "" {
		parts := strings.split(s, ",", context.temp_allocator)
		if len(parts) >= 5 {
			px, _ := strconv.parse_f32(parts[0])
			py, _ := strconv.parse_f32(parts[1])
			pz, _ := strconv.parse_f32(parts[2])
			yaw, _ := strconv.parse_f32(parts[3])
			pitch, _ := strconv.parse_f32(parts[4])
			player.pos = Vec3{px, py, pz}
			player.yaw = yaw
			player.pitch = pitch
			player.fly = true
		}
	}

	fmt.println(
		"controls: WASD move, mouse look, space jump, F fly, 1-9 select, LMB break, RMB place, ESC quit",
	)

	// Headless smoke test: MC_FRAMES=N renders N frames then exits cleanly.
	max_frames := -1
	if s := os.get_env("MC_FRAMES", context.temp_allocator); s != "" {
		if v, ok := strconv.parse_int(s); ok do max_frames = v
	}
	shot_path := os.get_env("MC_SHOT", context.allocator) // persists across per-frame temp resets

	// Optional fixed time-of-day for screenshots (0=midnight .. 0.5=noon).
	fixed_time: f32 = -1
	if s := os.get_env("MC_TIME", context.temp_allocator); s != "" {
		if v, ok := strconv.parse_f32(s); ok do fixed_time = v
	}

	// Debug: MC_MOBS=N force-spawns N animals in front of the camera.
	if s := os.get_env("MC_MOBS", context.temp_allocator); s != "" {
		if n, ok := strconv.parse_int(s); ok {
			fwd := camera_front(player.yaw, 0)
			mob_debug_populate(&world, &world.mobs, player.pos + fwd * 8, n)
		}
	}

	// Debug: MC_ZOMBIES=N spawns N zombies ahead (for screenshots/testing).
	if s := os.get_env("MC_ZOMBIES", context.temp_allocator); s != "" {
		if n, ok := strconv.parse_int(s); ok {
			fwd := camera_front(player.yaw, 0)
			c := player.pos + fwd * 10
			for k in 0 ..< n {
				x := int(c.x) + rng_int(8) - 4
				z := int(c.z) + rng_int(8) - 4
				world_ensure_chunk(&world, world_chunk_at(&world, x, z))
				for y := CHUNK_H - 2; y >= 1; y -= 1 {
					if block_is_solid(world_block(&world, x, y, z)) {
						append(
							&world.mobs,
							Mob {
								kind = .Zombie,
								pos = Vec3{f32(x) + 0.5, f32(y + 1), f32(z) + 0.5},
								health = 12,
								ai_timer = rng_range(0, 1),
							},
						)
						break
					}
				}
			}
		}
	}

	// Debug: MC_ITEMS=N drops N assorted item cubes ahead.
	if s := os.get_env("MC_ITEMS", context.temp_allocator); s != "" {
		if n, ok := strconv.parse_int(s); ok {
			fwd := camera_front(player.yaw, 0)
			c := player.pos + fwd * 6
			kinds := [?]BlockId{.Grass, .Stone, .Wood, .Sand, .Ore, .Glowstone}
			for k in 0 ..< n {
				x := int(c.x) + rng_int(6) - 3
				z := int(c.z) + rng_int(6) - 3
				world_ensure_chunk(&world, world_chunk_at(&world, x, z))
				for y := CHUNK_H - 2; y >= 1; y -= 1 {
					if block_is_solid(world_block(&world, x, y, z)) {
						item_spawn(
							&world.items,
							kinds[k % len(kinds)],
							Vec3{f32(x) + 0.5, f32(y + 1) + 0.4, f32(z) + 0.5},
						)
						break
					}
				}
			}
		}
	}

	// Debug: MC_GLOW places a few glowstone blocks on the ground ahead.
	if os.get_env("MC_GLOW", context.temp_allocator) != "" {
		fwd := camera_front(player.yaw, 0)
		base := player.pos + fwd * 6
		offs := [5]Ivec2{{0, 0}, {3, 1}, {-3, 2}, {2, 5}, {-2, -2}}
		for o in offs {
			x := int(base.x) + o.x
			z := int(base.z) + o.y
			world_ensure_chunk(&world, world_chunk_at(&world, x, z))
			for y := CHUNK_H - 2; y >= 1; y -= 1 {
				if block_is_solid(world_block(&world, x, y, z)) {
					world_set_block(&world, x, y + 1, z, .Glowstone)
					break
				}
			}
		}
	}

	frame := 0
	last := glfw.GetTime()
	for !glfw.WindowShouldClose(win) {
		now := glfw.GetTime()
		dt := f32(now - last)
		last = now
		if dt > 0.05 do dt = 0.05 // clamp to avoid tunnelling after hitches

		if fixed_time >= 0 {
			world.time_of_day = fixed_time
		} else {
			world.time_of_day += dt / DAY_LENGTH
			if world.time_of_day >= 1 do world.time_of_day -= 1
		}

		glfw.PollEvents()
		if g_input.quit {
			glfw.SetWindowShouldClose(win, true)
		}

		process_input(&player, dt)
		physics_update(&world, &player, dt)
		player_tick(&player, dt)
		handle_break_place(&world, &player)
		world_stream(&world, player.pos)
		mobs_update(&world, &player, &world.mobs, dt)
		items_update(&world, &player, &world.items, dt)
		render_remesh(&world, player.pos)
		render_frame(&world, &player, g_input.fb_w, g_input.fb_h)

		is_last := max_frames > 0 && frame + 1 >= max_frames
		if is_last && shot_path != "" {
			render_screenshot(shot_path, g_input.fb_w, g_input.fb_h)
		}

		glfw.SwapBuffers(win)
		free_all(context.temp_allocator)

		frame += 1
		if max_frames > 0 && frame >= max_frames {
			fmt.println("rendered", frame, "frames; loaded chunks:", len(world.chunks))
			break
		}
	}
}
