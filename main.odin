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
	best_g, best_w, best_s, best_d := 1 << 30, 1 << 30, 1 << 30, 1 << 30
	gx, gy, gz, wx0, wy0, wz0, sx, sy0, sz, dx0, dy0, dz0 := 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
	fg, fw, fs, fd := false, false, false, false
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
			if surf_b == .Sand && surf_y > SEA_LEVEL + 2 && d < best_d {
				best_d = d;dx0, dy0, dz0 = wx, surf_y, wz;fd = true
			}
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
	fmt.println("desert:", fd, dx0, dy0, dz0)
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

	// multiplayer: --server [port] | --connect host[:port]
	net_role := ""
	net_port := 25565
	net_addr := ""
	{
		a := os.args
		for i := 1; i < len(a); i += 1 {
			switch a[i] {
			case "--server":
				net_role = "server"
				if i + 1 < len(a) {
					if v, ok := strconv.parse_int(a[i + 1]); ok {net_port = v;i += 1}
				}
			case "--connect":
				net_role = "client"
				if i + 1 < len(a) {net_addr = a[i + 1];i += 1}
			}
		}
	}

	save_ensure_dir()
	seed: u64
	if net_role == "client" {
		addr := net_addr
		if !strings.contains(addr, ":") do addr = fmt.tprintf("%s:%d", addr, net_port)
		s, ok := net_connect(addr)
		if !ok {
			fmt.eprintln("could not connect to", addr)
			return
		}
		seed = s
	} else {
		s, ok := load_meta()
		if !ok {
			s = hash_u64(u64(time.to_unix_nanoseconds(time.now())))
			save_meta(s)
		}
		seed = s
		if net_role == "server" {
			net_start_server(net_port, seed)
		}
	}
	fmt.println("world seed:", seed)
	rng_seed(seed ~ 0xA5A5_5A5A_C3C3_3C3C)

	world: World
	world_init(&world, seed)
	defer world_save_all(&world)

	// The Nether: a second world reached through portals.
	nether: World
	world_init(&nether, seed ~ 0x4E45_5448_4552_0001, .Nether)
	defer world_save_all(&nether)
	cur := &world // the dimension currently being played/rendered

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
	if os.get_env("MC_INV", context.temp_allocator) != "" do g_show_inventory = true
	if os.get_env("MC_SETTINGS", context.temp_allocator) != "" do g_show_settings = true
	if os.get_env("MC_CRAFT", context.temp_allocator) != "" do g_show_crafting = true
	if os.get_env("MC_QUITUI", context.temp_allocator) != "" do g_show_quit_confirm = true

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

	// Debug: MC_SKELS=N spawns N skeletons ahead (they fire arrows).
	if s := os.get_env("MC_SKELS", context.temp_allocator); s != "" {
		if n, ok := strconv.parse_int(s); ok {
			fwd := camera_front(player.yaw, 0)
			c := player.pos + fwd * 9
			for k in 0 ..< n {
				x := int(c.x) + rng_int(6) - 3
				z := int(c.z) + rng_int(6) - 3
				world_ensure_chunk(&world, world_chunk_at(&world, x, z))
				for y := CHUNK_H - 2; y >= 1; y -= 1 {
					if block_is_solid(world_block(&world, x, y, z)) {
						append(
							&world.mobs,
							Mob {
								kind = .Skeleton,
								pos = Vec3{f32(x) + 0.5, f32(y + 1), f32(z) + 0.5},
								health = 8,
								ai_timer = rng_range(0, 1),
							},
						)
						break
					}
				}
			}
		}
	}

	// Debug: MC_BUILD places a row of the special blocks ahead (2 tall).
	if os.get_env("MC_BUILD", context.temp_allocator) != "" {
		fwd := camera_front(player.yaw, 0)
		right := Vec3{-fwd.z, 0, fwd.x}
		base := player.pos + fwd * 7
		blocks := [?]BlockId{.Glass, .Furnace, .Iron, .Cactus, .Glowstone}
		for b, k in blocks {
			x := int(base.x + right.x * f32(k * 2 - 4))
			z := int(base.z + right.z * f32(k * 2 - 4))
			world_ensure_chunk(&world, world_chunk_at(&world, x, z))
			for y := CHUNK_H - 2; y >= 1; y -= 1 {
				if block_is_solid(world_block(&world, x, y, z)) {
					world_set_block(&world, x, y + 1, z, b)
					world_set_block(&world, x, y + 2, z, b)
					break
				}
			}
		}
	}

	// Debug: MC_FARM lays out a tilled field (wheat at each stage), torches, a bed.
	if os.get_env("MC_FARM", context.temp_allocator) != "" {
		fwd := camera_front(player.yaw, 0)
		right := Vec3{-fwd.z, 0, fwd.x}
		base := player.pos + fwd * 6
		surface_y :: proc(w: ^World, x, z: int) -> int {
			world_ensure_chunk(w, world_chunk_at(w, x, z))
			for y := CHUNK_H - 2; y >= 1; y -= 1 {
				if block_is_solid(world_block(w, x, y, z)) do return y
			}
			return SEA_LEVEL
		}
		// a 5x4 field of farmland with rows of wheat at increasing stages
		stages := [?]BlockId{.Wheat1, .Wheat2, .Wheat3, .Wheat3}
		for row in 0 ..< 4 {
			for col in 0 ..< 5 {
				x := int(base.x + right.x * f32(col - 2) + fwd.x * f32(row))
				z := int(base.z + right.z * f32(col - 2) + fwd.z * f32(row))
				gy := surface_y(&world, x, z)
				world_set_block(&world, x, gy, z, .Farmland)
				world_set_block(&world, x, gy + 1, z, stages[row])
			}
		}
		// torches + a bed flanking the field
		tx := int(base.x + right.x * 3)
		tz := int(base.z + right.z * 3)
		ty := surface_y(&world, tx, tz)
		world_set_block(&world, tx, ty + 1, tz, .Torch)
		bx := int(base.x - right.x * 3)
		bz := int(base.z - right.z * 3)
		by := surface_y(&world, bx, bz)
		world_set_block(&world, bx, by + 1, bz, .Bed)
	}

	// Debug: MC_PARTICLES bursts break-particles ahead.
	if os.get_env("MC_PARTICLES", context.temp_allocator) != "" {
		fwd := camera_front(player.yaw, 0)
		c := player.pos + fwd * 4
		for k in 0 ..< 4 {
			particle_spawn_break(&world.particles, .Grass, int(c.x), int(c.y) + k, int(c.z))
			particle_spawn_break(&world.particles, .Stone, int(c.x) + 1, int(c.y) + k, int(c.z) + 1)
		}
	}

	// Debug: MC_PORTAL builds a lit portal ahead; MC_NETHER starts in the nether.
	if os.get_env("MC_PORTAL", context.temp_allocator) != "" {
		fwd := camera_front(player.yaw, 0)
		ox := int(player.pos.x + fwd.x * 3) - 1
		oz := int(player.pos.z + fwd.z * 3)
		oy := int(player.pos.y)
		world_ensure_chunk(cur, world_chunk_at(cur, ox, oz))
		world_ensure_chunk(cur, world_chunk_at(cur, ox + 3, oz))
		build_portal(cur, ox, oy, oz)
	}
	if os.get_env("MC_NETHER", context.temp_allocator) != "" {
		cur = &nether // camera positioned via MC_CAM
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

	// Title screen. MC_TITLE screenshots it; headless scene runs skip it.
	if os.get_env("MC_TITLE", context.temp_allocator) != "" {
		for f in 0 ..< max(max_frames, 1) {
			glfw.PollEvents()
			render_title(g_input.fb_w, g_input.fb_h)
			if f == max(max_frames, 1) - 1 && shot_path != "" {
				render_screenshot(shot_path, g_input.fb_w, g_input.fb_h)
			}
			glfw.SwapBuffers(win)
			free_all(context.temp_allocator)
		}
		return
	}
	if max_frames <= 0 && net_role == "" {
		for !glfw.WindowShouldClose(win) && !g_input.start {
			glfw.PollEvents()
			render_title(g_input.fb_w, g_input.fb_h)
			glfw.SwapBuffers(win)
			free_all(context.temp_allocator)
		}
	}

	// Drain any keys pressed on the title screen so they don't leak into play.
	g_input.craft = false
	g_input.smelt = false
	g_input.eat = false
	g_input.fly_toggle = false
	g_input.break_req = false
	g_input.place_req = false
	g_input.select = 0
	g_input.inv_toggle = false
	g_input.settings_toggle = false
	g_input.craft_toggle = false
	g_input.interact = false
	g_input.confirm = false
	g_input.portal = false

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
			world.time_of_day += dt / g_settings.day_length
			if world.time_of_day >= 1 do world.time_of_day -= 1
		}

		glfw.PollEvents()
		// ESC opens a quit-confirm overlay (or backs out of a menu / the
		// overlay). Y on the overlay actually exits.
		if g_input.quit {
			g_input.quit = false
			if g_show_quit_confirm {
				g_show_quit_confirm = false
			} else if g_show_inventory || g_show_settings || g_show_crafting {
				g_show_inventory = false
				g_show_settings = false
				g_show_crafting = false
			} else {
				g_show_quit_confirm = true
			}
		}
		if g_show_quit_confirm && g_input.confirm {
			glfw.SetWindowShouldClose(win, true)
		}
		g_input.confirm = false

		// menu toggles (mutually exclusive; disabled while confirming quit)
		if !g_show_quit_confirm {
			if g_input.inv_toggle {
				g_show_inventory = !g_show_inventory
				if g_show_inventory {g_show_settings = false;g_show_crafting = false}
			}
			if g_input.settings_toggle {
				g_show_settings = !g_show_settings
				if g_show_settings {g_show_inventory = false;g_show_crafting = false}
			}
			if g_input.craft_toggle {
				g_show_crafting = !g_show_crafting
				if g_show_crafting {g_show_inventory = false;g_show_settings = false}
			}
		}
		g_input.inv_toggle = false
		g_input.settings_toggle = false
		g_input.craft_toggle = false

		paused := g_show_inventory || g_show_settings || g_show_crafting || g_show_quit_confirm
		if paused {
			// discard buffered gameplay one-shots so they don't fire on close
			g_input.dx = 0
			g_input.dy = 0
			g_input.break_req = false
			g_input.place_req = false
			g_input.craft = false
			g_input.smelt = false
			g_input.eat = false
			g_input.fly_toggle = false
			g_input.interact = false
			g_input.portal = false
			if g_show_settings {
				if g_input.nav_up do g_settings_sel = (g_settings_sel + SETTINGS_COUNT - 1) % SETTINGS_COUNT
				if g_input.nav_down do g_settings_sel = (g_settings_sel + 1) % SETTINGS_COUNT
				if g_input.nav_left do settings_adjust(-1)
				if g_input.nav_right do settings_adjust(1)
			}
			if g_show_crafting && g_input.select > 0 {
				recipe_try(&player, cur, g_input.select - 1)
			}
			g_input.select = 0
		} else {
			process_input(&player, dt)
			physics_update(cur, &player, dt)
			player_tick(&player, dt)
			handle_break_place(cur, &player)

			// R: use/interact (till, plant, harvest, sleep)
			if g_input.interact {
				try_interact(cur, &player)
				g_input.interact = false
			}
			crops_tick(cur, dt)

			// build a portal in front of the player (P)
			if g_input.portal {
				if player.inventory[.Obsidian] >= PORTAL_COST {
					fwd := camera_front(player.yaw, 0)
					ox := int(player.pos.x + fwd.x * 2) - 1
					oz := int(player.pos.z + fwd.z * 2)
					oy := int(player.pos.y)
					build_portal(cur, ox, oy, oz)
					player.inventory[.Obsidian] -= PORTAL_COST
					fmt.println("portal lit - step in to travel")
				} else {
					fmt.println("need", PORTAL_COST, "Obsidian for a portal (craft: T)")
				}
				g_input.portal = false
			}

			// dimension travel
			if player_in_portal(cur, player.pos) {
				player.portal_timer += dt
				if player.portal_timer > PORTAL_TRIGGER {
					player.portal_timer = -1.5 // cooldown before it can trigger again
					cur = cur == &world ? &nether : &world
					player.pos = portal_destination(cur, int(player.pos.x), int(player.pos.z))
					player.vel = Vec3{0, 0, 0}
					fmt.println("entered the", cur.dimension)
				}
			} else if player.portal_timer < 0 {
				player.portal_timer += dt
			} else {
				player.portal_timer = 0
			}

			// lava burns
			if player_in_lava(cur, player.pos) {
				player.lava_timer += dt
				if player.lava_timer > 0.4 {
					player_damage(&player, 2, Vec3{0, 0, 0})
					player.lava_timer = 0
				}
			} else {
				player.lava_timer = 0
			}

			world_stream(cur, player.pos)
			mobs_update(cur, &player, &cur.mobs, dt)
			items_update(cur, &player, &cur.items, dt)
			arrows_update(cur, &player, dt)
			particles_update(cur, &cur.particles, dt)
		}
		g_input.nav_up = false;g_input.nav_down = false;g_input.nav_left = false;g_input.nav_right = false

		if net_active() {
			net_send_pos(&player)
			net_apply_edits(&world, &nether)
		}

		render_remesh(cur, player.pos)
		render_frame(cur, &player, g_input.fb_w, g_input.fb_h)
		fw, fh := int(g_input.fb_w), int(g_input.fb_h)
		if g_show_inventory do ui_draw_inventory(&player, fw, fh)
		else if g_show_settings do ui_draw_settings(fw, fh)
		else if g_show_crafting do ui_draw_crafting(&player, cur, fw, fh)
		if g_show_quit_confirm do ui_draw_quit_confirm(fw, fh)

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
