package main

import "core:fmt"
import "core:math"
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
	best_g, best_w, best_s, best_d, best_r := 1 << 30, 1 << 30, 1 << 30, 1 << 30, 1 << 30
	gx, gy, gz, wx0, wy0, wz0, sx, sy0, sz, dx0, dy0, dz0, rx, ry0, rz := 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
	fg, fw, fs, fd, fr := false, false, false, false, false
	tallest_y := -1
	tx0, tz0 := 0, 0
	hist: map[BlockId]int
	defer delete(hist)
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
			hist[surf_b] += 1
			if surf_y > tallest_y {tallest_y = surf_y;tx0, tz0 = wx, wz}
			d := wx * wx + wz * wz
			if surf_b == .Grass && d < best_g {best_g = d;gx, gy, gz = wx, surf_y, wz;fg = true}
			if surf_b == .Snow && d < best_s {best_s = d;sx, sy0, sz = wx, surf_y, wz;fs = true}
			if surf_b == .Sand && surf_y > SEA_LEVEL + 2 && d < best_d {
				best_d = d;dx0, dy0, dz0 = wx, surf_y, wz;fd = true
			}
			if surf_b == .RedSand && d < best_r {best_r = d;rx, ry0, rz = wx, surf_y, wz;fr = true}
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
	fmt.println("badlands:", fr, rx, ry0, rz)
	fmt.println("tallest:", tx0, tallest_y, tz0)
	fmt.println("surface block histogram:", hist)

	// Biome distribution over a wide sample: the whole point of the climate
	// rework is that a drive across the map hits many biomes, so this counts
	// how much of a broad area each biome actually covers.
	bhist: map[Biome]int
	defer delete(bhist)
	BR :: 700 // sample half-extent in blocks
	for wz := -BR; wz < BR; wz += 6 {
		for wx := -BR; wx < BR; wx += 6 {
			_, b, _ := world_height_and_biome(w.seed, wx, wz)
			bhist[b] += 1
		}
	}
	fmt.println("biome histogram:", bhist)
}

// Natural terrain blocks a spawn point may rest on — never water/lava, and
// never a tree/cactus/player-built block (irrelevant on a fresh world, but
// keeps the search meaning "real ground").
@(private = "file")
is_spawnable_ground :: proc(b: BlockId) -> bool {
	#partial switch b {
	case .Grass, .Dirt, .Stone, .Sand, .Snow, .Netherrack, .Farmland, .Ore, .Bedrock, .RedSand:
		return true
	}
	return false
}

// Confirms nothing solid sits between from_y and the world ceiling — i.e.
// this is a genuine outdoor surface spot, not a sealed cave/cavern pocket
// that happens to have a floor and two blocks of headroom (which, near an
// ocean, is easy to find underground without ever reaching real ground).
@(private = "file")
open_to_sky :: proc(w: ^World, x, from_y, z: int) -> bool {
	for y := from_y; y < CHUNK_H; y += 1 {
		if block_is_solid(world_block(w, x, y, z)) do return false
	}
	return true
}

// A column is a valid spawn if it has dry ground with two clear blocks of
// headroom above it (so the point is never underwater or floating in air)
// AND open sky above that — never inside a cave, even a sealed one that
// happens to have a floor (a real bug: these turn up under oceans, where a
// cavern ceiling reads as "ground" for a column scanned from the top down).
@(private = "file")
spawn_try_column :: proc(w: ^World, x, z: int) -> (Vec3, bool) {
	world_ensure_chunk(w, world_chunk_at(w, x, z))
	for y := CHUNK_H - 2; y >= 1; y -= 1 {
		b := world_block(w, x, y, z)
		if !is_spawnable_ground(b) do continue
		if world_block(w, x, y + 1, z) != .Air do continue
		if world_block(w, x, y + 2, z) != .Air do continue
		if !open_to_sky(w, x, y + 3, z) do continue
		return Vec3{f32(x) + 0.5, f32(y + 1), f32(z) + 0.5}, true
	}
	return Vec3{}, false
}

// Absolute last resort: no natural dry land was found anywhere within the
// search radius (e.g. an all-ocean seed near the origin). Build a small
// guaranteed-dry island instead of ever leaving the player spawned over —
// or falling into — open water.
@(private = "file")
spawn_build_platform :: proc(w: ^World, x, z: int) -> Vec3 {
	y := SEA_LEVEL + 1
	for dz in -1 ..= 1 {
		for dx in -1 ..= 1 {
			cx, cz := x + dx, z + dz
			world_ensure_chunk(w, world_chunk_at(w, cx, cz))
			world_set_block(w, cx, y - 1, cz, .Stone)
			world_set_block(w, cx, y, cz, .Sand)
			world_set_block(w, cx, y + 1, cz, .Air)
			world_set_block(w, cx, y + 2, cz, .Air)
		}
	}
	return Vec3{f32(x) + 0.5, f32(y + 1), f32(z) + 0.5}
}

// Nearest dry land near the world origin, used as the spawn point. Never
// water, lava, or mid-air: spirals outward from (8,8) until a valid column
// (solid ground with clear headroom) is found. Real oceans can be enormous —
// a small search radius previously let this fall through to a fixed-height
// fallback that was itself sometimes still underwater — so this now searches
// a wide radius and, failing that, builds a guaranteed-dry platform.
spawn_pos :: proc(w: ^World) -> Vec3 {
	if p, ok := spawn_try_column(w, 8, 8); ok do return p
	SEARCH_RADIUS :: 48
	for r in 1 ..< SEARCH_RADIUS {
		for dx in -r ..= r {
			if p, ok := spawn_try_column(w, 8 + dx, 8 - r); ok do return p
			if p, ok := spawn_try_column(w, 8 + dx, 8 + r); ok do return p
		}
		for dz in -r + 1 ..= r - 1 {
			if p, ok := spawn_try_column(w, 8 - r, 8 + dz); ok do return p
			if p, ok := spawn_try_column(w, 8 + r, 8 + dz); ok do return p
		}
	}
	return spawn_build_platform(w, 8, 8)
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
	load_chests(&world)
	load_doors(&world)
	defer world_save_all(&world)
	defer save_chests(&world)
	defer save_doors(&world)

	// The Nether: a second world reached through portals.
	nether: World
	world_init(&nether, seed ~ 0x4E45_5448_4552_0001, .Nether)
	load_chests(&nether)
	load_doors(&nether)
	defer world_save_all(&nether)
	defer save_chests(&nether)
	defer save_doors(&nether)
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
	if os.get_env("MC_INV", context.temp_allocator) != "" {
		g_show_inventory = true;g_inv_tab = .Items
		// sample stock so the Items grid is populated for the screenshot
		for b in ([?]BlockId{.Grass, .Dirt, .Stone, .Wood, .Sand, .Glass, .Stair, .CoalOre, .Iron, .Leaves, .Snow, .FlowerRed, .Cactus}) {
			player.inventory[b] = 16
		}
		g_inv_cursor = 6
	}
	if os.get_env("MC_SETTINGS", context.temp_allocator) != "" do g_show_settings = true
	if os.get_env("MC_CRAFT", context.temp_allocator) != "" {g_show_inventory = true;g_inv_tab = .Craft}
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

	// Debug: MC_PICKUP drops an item right at the player's feet so it's
	// picked up within a few frames (toast + particle burst + sound).
	if os.get_env("MC_PICKUP", context.temp_allocator) != "" {
		item_spawn(&world.items, .Iron, player.pos + Vec3{0, 0.3, 0})
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

	// Debug: MC_NPC spawns one villager of every profession in a row ahead,
	// for screenshotting the humanoid model + robe colours without
	// depending on village RNG.
	if os.get_env("MC_NPC", context.temp_allocator) != "" {
		fwd := camera_front(player.yaw, 0)
		right := Vec3{-fwd.z, 0, fwd.x}
		base := player.pos + fwd * 5
		// MC_NPCBIOME=snow|desert dresses the row for that climate (coats/hats).
		npc_biome := Biome.Plains
		switch os.get_env("MC_NPCBIOME", context.temp_allocator) {
		case "snow":
			npc_biome = .Snow
		case "desert":
			npc_biome = .Desert
		}
		professions := [5]Profession{.None, .Farmer, .Priest, .Blacksmith, .Merchant}
		names := [5]string{"NOMAD", "FARMER", "PRIEST", "SMITH", "MERCH"}
		for i in 0 ..< 5 {
			np := base + right * f32(i - 2) * 2.0
			append(
				&world.villagers,
				Villager {
					pos = np,
					yaw = player.yaw + math.PI,
					health = 10,
					name = names[i],
					profession = professions[i],
					home_biome = npc_biome,
				},
			)
		}
		// a second row of nomads (Profession.None, different names) to show
		// the per-individual palette that keeps them from all looking alike
		nomad_names := [6]string{"OTIS", "PIP", "RUNA", "GUS", "NELL", "BRAM"}
		for i in 0 ..< 6 {
			np := base + fwd * 3 + right * f32(i - 2) * 2.0
			append(
				&world.villagers,
				Villager{pos = np, yaw = player.yaw + math.PI, health = 10, name = nomad_names[i]},
			)
		}
	}

	// Debug: MC_ORES places a row of solid stone with one of each ore tier
	// embedded, at eye level directly ahead, for screenshotting them
	// without digging.
	if os.get_env("MC_ORES", context.temp_allocator) != "" {
		fwd := camera_front(player.yaw, 0)
		right := Vec3{-fwd.z, 0, fwd.x}
		base := player.pos + fwd * 4
		ores := [5]BlockId{.CoalOre, .Ore, .GoldOre, .DiamondOre, .Gold}
		for i in 0 ..< 5 {
			bp := base + right * f32(i - 2) * 1.5
			bx, by, bz := int(bp.x), int(bp.y), int(bp.z)
			world_ensure_chunk(&world, world_chunk_at(&world, bx, bz))
			world_set_block(&world, bx, by, bz, ores[i])
		}
	}

	// Debug: MC_AQUA floods a big pool ahead and spawns one of every aquatic
	// mob inside it, then submerges the camera to view them (like MC_FISH but
	// for the full aquatic roster).
	if os.get_env("MC_AQUA", context.temp_allocator) != "" {
		fwd := camera_front(player.yaw, 0)
		base := player.pos + fwd * 8
		bx, by, bz := int(base.x), int(base.y) - 3, int(base.z)
		for dx in -5 ..= 5 {
			for dy in 0 ..= 6 {
				for dz in -5 ..= 5 {
					world_set_block(&world, bx + dx, by + dy, bz + dz, .Water)
				}
			}
		}
		kinds := [5]MobKind{.Fish, .Squid, .Dolphin, .Pufferfish, .Jellyfish}
		for k, i in kinds {
			append(
				&world.mobs,
				Mob {
					kind = k,
					pos = Vec3{f32(bx) + f32(i - 2) * 1.6, f32(by) + 3, f32(bz)},
					yaw = 1.4,
					health = 6,
				},
			)
		}
		player.pos = Vec3{f32(bx) - 4, f32(by) + 3.2, f32(bz)}
		player.yaw = math.PI * 0.5
		player.pitch = 0.0
		player.fly = true
		fmt.println("MC_AQUA: aquatic mobs at", bx, by + 3, bz)
	}

	// Debug: MC_HORSE spawns a horse directly ahead at ground level.
	if os.get_env("MC_HORSE", context.temp_allocator) != "" {
		fwd := camera_front(player.yaw, 0)
		bx := int(player.pos.x + fwd.x * 5)
		bz := int(player.pos.z + fwd.z * 5)
		world_ensure_chunk(&world, world_chunk_at(&world, bx, bz))
		by := SEA_LEVEL
		for y := CHUNK_H - 2; y >= 1; y -= 1 {
			if block_is_solid(world_block(&world, bx, y, bz)) {
				by = y
				break
			}
		}
		append(
			&world.mobs,
			Mob{kind = .Horse, pos = Vec3{f32(bx) + 0.5, f32(by + 1), f32(bz) + 0.5}, yaw = player.yaw + math.PI, health = 8},
		)
	}

	// Debug: MC_STAIRS lays out one stair of each facing (0..3) on a stone pad
	// ahead and drops the camera to eye level to check the oriented geometry.
	if os.get_env("MC_STAIRS", context.temp_allocator) != "" {
		fwd := camera_front(player.yaw, 0)
		bx := int(player.pos.x + fwd.x * 5)
		bz := int(player.pos.z + fwd.z * 5)
		world_ensure_chunk(&world, world_chunk_at(&world, bx, bz))
		by := SEA_LEVEL
		for y := CHUNK_H - 2; y >= 1; y -= 1 {
			if block_is_solid(world_block(&world, bx, y, bz)) {by = y;break}
		}
		for f in 0 ..< 4 {
			sx := bx + f - 1
			world_set_block(&world, sx, by, bz, .Stone) // a pad under each stair
			world_set_block(&world, sx, by + 1, bz, .Stair)
			world.stairs[Ivec3{sx, by + 1, bz}] = u8(f)
		}
		player.pos = Vec3{f32(bx) - fwd.x * 3, f32(by) + 2, f32(bz) - fwd.z * 3}
		player.pitch = -0.25
		player.fly = true
	}

	// Debug: MC_BED places a bed on the real ground directly ahead (and
	// drops the camera to eye level there) for screenshotting the low-box
	// furniture shape without having to guess terrain height up front.
	if os.get_env("MC_BED", context.temp_allocator) != "" {
		fwd := camera_front(player.yaw, 0)
		bx := int(player.pos.x + fwd.x * 4)
		bz := int(player.pos.z + fwd.z * 4)
		world_ensure_chunk(&world, world_chunk_at(&world, bx, bz))
		by := SEA_LEVEL
		for y := CHUNK_H - 2; y >= 1; y -= 1 {
			if block_is_solid(world_block(&world, bx, y, bz)) {
				by = y
				break
			}
		}
		world_set_block(&world, bx, by + 1, bz, .Bed)
		player.pos = Vec3{f32(bx) - fwd.x * 3, f32(by) + 1, f32(bz) - fwd.z * 3}
	}

	// Debug: MC_VILLAGE generates chunks outward from spawn until a village
	// rolls in (VILLAGE_CHANCE makes it rare - not every world has one
	// nearby) and teleports the camera there, for screenshotting.
	if os.get_env("MC_VILLAGE", context.temp_allocator) != "" {
		found := false
		SR :: 24
		for r in 0 ..= SR {
			for cz in -r ..= r {
				for cx in -r ..= r {
					if max(abs(cx), abs(cz)) != r do continue // ring order: nearest first
					world_ensure_chunk(&world, Ivec2{cx, cz})
					if len(world.villages) > 0 {
						found = true
					}
				}
			}
			if found do break
		}
		if len(world.villages) > 0 {
			t := world.villages[0].center
			player.pos = Vec3{f32(t.x) - 14, f32(t.y) + 9, f32(t.z) - 14}
			player.yaw = 2.35
			player.pitch = -0.35
			player.fly = true
			fmt.println(
				"MC_VILLAGE: found village at",
				world.villages[0].center,
				"with",
				world.villages[0].houses,
				"houses and",
				len(world.villagers),
				"villagers",
			)
		} else {
			fmt.println("MC_VILLAGE: no village found within", SR, "chunks")
		}
	}

	// Debug: MC_SNOWVILLAGE=<biome> force-builds a village in the nearest chunk
	// of that biome (default Snow), bypassing only the rarity roll — the real
	// biome + flatness gates still apply — then teleports the camera there. For
	// eyeballing biome-specific building materials (white snow roofs etc.)
	// without hunting for a naturally rare cold/arid village.
	if s := os.get_env("MC_SNOWVILLAGE", context.temp_allocator); s != "" {
		want := Biome.Snow
		switch s {
		case "desert":
			want = .Desert
		case "taiga":
			want = .Taiga
		case "savanna":
			want = .Savanna
		}
		SR :: 48
		search: for r in 0 ..= SR {
			for cz in -r ..= r {
				for cx in -r ..= r {
					if max(abs(cx), abs(cz)) != r do continue
					// cheap biome probe first — only pay to generate chunks that
					// are actually the biome we want
					_, b, _ := world_height_and_biome(world.seed, cx * CHUNK_W + 8, cz * CHUNK_D + 8)
					if b != want do continue
					before := len(world.villages)
					g_force_village = true
					g_force_village_chunk = Ivec2{cx, cz}
					world_ensure_chunk(&world, Ivec2{cx, cz})
					if len(world.villages) > before do break search // flatness passed too
				}
			}
		}
		g_force_village = false
		if len(world.villages) > 0 {
			t := world.villages[len(world.villages) - 1].center
			player.pos = Vec3{f32(t.x) - 14, f32(t.y) + 9, f32(t.z) - 14}
			player.yaw = 2.35
			player.pitch = -0.35
			player.fly = true
			fmt.println("MC_SNOWVILLAGE:", want, "village at", t)
		} else {
			fmt.println("MC_SNOWVILLAGE: no flat", want, "chunk found within", SR)
		}
	}

	// Debug: MC_DOOR places a door on the real ground directly ahead (open
	// if MC_DOOR=open) and drops the camera to eye level there, for
	// screenshotting the open/closed low-box door shape.
	if s := os.get_env("MC_DOOR", context.temp_allocator); s != "" {
		fwd := camera_front(player.yaw, 0)
		dx := int(player.pos.x + fwd.x * 4)
		dz := int(player.pos.z + fwd.z * 4)
		world_ensure_chunk(&world, world_chunk_at(&world, dx, dz))
		dy := SEA_LEVEL
		for y := CHUNK_H - 2; y >= 1; y -= 1 {
			if block_is_solid(world_block(&world, dx, y, dz)) {
				dy = y
				break
			}
		}
		world_set_block(&world, dx, dy + 1, dz, .Door)
		world_set_block(&world, dx, dy + 2, dz, .Air)
		world.doors[Ivec3{dx, dy + 1, dz}] = Door{facing = 0, open = s == "open"}
		player.pos = Vec3{f32(dx) - fwd.x * 3, f32(dy) + 1, f32(dz) - fwd.z * 3}
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

	// Debug: MC_NMOBS=N spawns nether mobs (piglins + ghasts) ahead in cur.
	if s := os.get_env("MC_NMOBS", context.temp_allocator); s != "" {
		n := 4
		if v, ok := strconv.parse_int(s); ok do n = v
		fwd := camera_front(player.yaw, 0)
		base := player.pos + fwd * 9
		for k in 0 ..< n {
			gh := k % 2 == 1
			pos := base + Vec3{f32((k % 3 - 1) * 3), gh ? 3 : 0, f32(k / 3 * 3)}
			append(
				&cur.mobs,
				Mob {
					kind = gh ? .Ghast : .Piglin,
					pos = pos,
					yaw = player.yaw + 3.14159265,
					health = 10,
				},
			)
		}
	}

	// Debug: MC_DIVE submerges the player in a water pool (oxygen HUD/tint).
	if os.get_env("MC_DIVE", context.temp_allocator) != "" {
		px := int(player.pos.x)
		py := int(player.pos.y)
		pz := int(player.pos.z)
		for dy in -1 ..= 4 {
			for dz in -4 ..= 4 {
				for dx in -4 ..= 4 {
					world_set_block(&world, px + dx, py + dy, pz + dz, .Water)
				}
			}
		}
		player.oxygen = 7.0
	}

	// Debug: MC_FISH=N floods a pool ahead and spawns N fish/squid inside it.
	if s := os.get_env("MC_FISH", context.temp_allocator); s != "" {
		n := 4
		if v, ok := strconv.parse_int(s); ok do n = v
		fwd := camera_front(player.yaw, 0)
		base := player.pos + fwd * 8
		bx, by, bz := int(base.x), int(base.y) - 2, int(base.z)
		for dx in -3 ..= 3 {
			for dy in 0 ..= 4 {
				for dz in -3 ..= 3 {
					world_set_block(&world, bx + dx, by + dy, bz + dz, .Water)
				}
			}
		}
		for k in 0 ..< n {
			kind: MobKind = k % 2 == 0 ? .Fish : .Squid
			append(
				&world.mobs,
				Mob {
					kind = kind,
					pos = Vec3{f32(bx) + f32(k % 3 - 1) * 1.5, f32(by) + 2, f32(bz) + f32(k / 3) * 1.5},
					yaw = 0,
					health = 4,
				},
			)
		}
	}

	// Debug: MC_EAT gives the player cooked food and triggers the eat
	// animation (camera bob + crumb particles) so it lands on frame 0.
	if os.get_env("MC_EAT", context.temp_allocator) != "" {
		player.cooked_food = 3
		g_input.eat = true
	}

	// Debug: MC_TOAST shows a sample on-screen action-bar message.
	if os.get_env("MC_TOAST", context.temp_allocator) != "" {
		toast_show("GOOD MORNING - SPAWN POINT SET")
	}

	// Debug UI screenshots.
	if os.get_env("MC_TOOLS", context.temp_allocator) != "" {
		player.inventory[.Stone] = 20
		player.inventory[.Iron] = 6
		g_show_inventory = true
		g_inv_tab = .Tools
	}
	// Debug: MC_ARMOR equips a mixed-tier set for a screenshot of the tab.
	if os.get_env("MC_ARMOR", context.temp_allocator) != "" {
		player.inventory[.Wood] = 20
		player.inventory[.Stone] = 20
		player.inventory[.Iron] = 20
		armor_craft(&player, .Helmet)
		armor_craft(&player, .Helmet)
		armor_craft(&player, .Helmet) // iron helmet
		armor_craft(&player, .Chestplate)
		armor_craft(&player, .Chestplate) // stone chestplate
		armor_craft(&player, .Boots) // wood boots
		g_show_inventory = true
		g_inv_tab = .Tools
	}
	// Debug: MC_RAIN forces rain on immediately (skips the weather timer).
	if os.get_env("MC_RAIN", context.temp_allocator) != "" {
		world.raining = true
		world.weather_timer = 1000
	}
	// Debug: MC_BABY spawns an adult + baby cow pair ahead for comparison.
	if os.get_env("MC_BABY", context.temp_allocator) != "" {
		fwd := camera_front(player.yaw, 0)
		base := player.pos + fwd * 6
		append(&world.mobs, Mob{kind = .Cow, pos = base + Vec3{-1, 0, 0}, health = 6})
		append(
			&world.mobs,
			Mob{kind = .Cow, pos = base + Vec3{1, 0, 0}, is_baby = true, grow_timer = 60, health = 6},
		)
	}
	// Debug: MC_BREED spawns two cows a few blocks apart and feeds both, so
	// love-mode particles show immediately and they visibly walk toward
	// each other (mate-seeking) over subsequent frames.
	if os.get_env("MC_BREED", context.temp_allocator) != "" {
		fwd := camera_front(player.yaw, 0)
		base := player.pos + fwd * 8
		append(&world.mobs, Mob{kind = .Cow, pos = base + Vec3{-4, 0, 0}, health = 6})
		append(&world.mobs, Mob{kind = .Cow, pos = base + Vec3{4, 0, 0}, health = 6})
		fed_p: Player
		fed_p.wheat = 2
		try_feed(&world, &fed_p, &world.mobs[len(world.mobs) - 2])
		try_feed(&world, &fed_p, &world.mobs[len(world.mobs) - 1])
	}
	// Debug: MC_DEATH spawns a Pig already past MOB_OLD_AGE with 1 hp, so the
	// old-age death toast/particle burst fires on the very next mobs_update.
	if os.get_env("MC_DEATH", context.temp_allocator) != "" {
		fwd := camera_front(player.yaw, 0)
		append(
			&world.mobs,
			Mob{kind = .Pig, pos = player.pos + fwd * 4, health = 1, age = MOB_OLD_AGE + 1},
		)
	}
	if os.get_env("MC_CHESTUI", context.temp_allocator) != "" {
		g_chest_pos = Ivec3{int(player.pos.x), int(player.pos.y), int(player.pos.z)}
		ch: Chest
		ch.items[.Stone] = 64
		ch.items[.Iron] = 12
		ch.items[.Glowstone] = 8
		ch.items[.Wood] = 30
		world.chests[g_chest_pos] = ch
		g_show_chest = true
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
	g_input.tools_toggle = false
	g_input.quit = false // an ESC on the title screen must not open quit-confirm on frame 0

	frame := 0
	last := glfw.GetTime()
	for !glfw.WindowShouldClose(win) {
		now := glfw.GetTime()
		dt := f32(now - last)
		last = now
		if dt > 0.05 do dt = 0.05 // clamp to avoid tunnelling after hitches

		if fixed_time >= 0 {
			world.time_of_day = fixed_time
		} else if g_settings.real_time {
			world.time_of_day = real_time_fraction()
		} else {
			world.time_of_day += dt / g_settings.day_length
			if world.time_of_day >= 1 do world.time_of_day -= 1
		}
		toast_tick(dt)

		glfw.PollEvents()
		// ESC opens a quit-confirm overlay (or backs out of a menu / the
		// overlay). Y on the overlay actually exits.
		if g_input.quit {
			g_input.quit = false
			if g_show_quit_confirm {
				g_show_quit_confirm = false
			} else if g_show_inventory || g_show_settings || g_show_chest {
				g_show_inventory = false
				g_show_settings = false
				g_show_chest = false
			} else {
				g_show_quit_confirm = true
			}
		}
		if g_show_quit_confirm && g_input.confirm {
			glfw.SetWindowShouldClose(win, true)
		}
		g_input.confirm = false

		// Inventory/crafting/tools are one tabbed panel now: E/T/X each open
		// straight to their tab (or close it, if that tab is already showing).
		// LEFT/RIGHT below moves the Items-tab grid cursor.
		if !g_show_quit_confirm {
			open_tab :: proc(tab: InvTab) {
				if g_show_inventory && g_inv_tab == tab {
					g_show_inventory = false
				} else {
					g_show_inventory = true
					g_inv_tab = tab
					g_show_settings = false
					g_show_chest = false
					if tab == .Items do g_inv_cursor = 0
				}
			}
			if g_input.inv_toggle do open_tab(.Items)
			if g_input.craft_toggle do open_tab(.Craft)
			if g_input.tools_toggle do open_tab(.Tools)
			if g_input.settings_toggle {
				g_show_settings = !g_show_settings
				if g_show_settings {g_show_inventory = false;g_show_chest = false}
			}
		}
		g_input.inv_toggle = false
		g_input.settings_toggle = false
		g_input.craft_toggle = false
		g_input.tools_toggle = false

		paused := g_show_inventory || g_show_settings || g_show_chest || g_show_quit_confirm
		// Release the OS cursor so menus are clickable; recapture it for
		// gameplay. Clearing have_last stops the reacquired cursor from
		// snapping the camera on the next move.
		if paused != g_cursor_free {
			if g_win != nil {
				glfw.SetInputMode(g_win, glfw.CURSOR, paused ? glfw.CURSOR_NORMAL : glfw.CURSOR_DISABLED)
			}
			g_input.have_last = false
			g_cursor_free = paused
		}
		if paused {
			ui_click := g_input.break_req // left-click, captured before it's discarded below
			// chest transfers: R takes everything, a hotbar number deposits it
			if g_show_chest {
				if g_input.interact do chest_withdraw_all(cur, &player)
				if g_input.select >= 1 && g_input.select <= 9 {
					chest_deposit(cur, &player, player.hotbar[g_input.select - 1])
				}
			}
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
			if g_show_inventory {
				switch g_inv_tab {
				case .Items:
					// Select an item with the mouse (hover to highlight, click
					// to lock it in) or the arrow keys, then assign it to a
					// hotbar slot by clicking that slot or pressing 1-9.
					entries := inventory_entries(&player)
					if len(entries) > 0 {
						cols := INV_COLS
						if g_input.nav_left do g_inv_cursor -= 1
						if g_input.nav_right do g_inv_cursor += 1
						if g_input.nav_up do g_inv_cursor -= cols
						if g_input.nav_down do g_inv_cursor += cols
						g_inv_cursor = clamp(g_inv_cursor, 0, len(entries) - 1)

						aspect := f32(g_input.fb_w) / f32(max(g_input.fb_h, 1))
						mnx, mny := cursor_ndc()
						if hov := inv_hit_grid(aspect, mnx, mny, len(entries)); hov >= 0 {
							g_inv_cursor = hov // hovering highlights
						}
						assign_to := -1
						if ui_click {
							if inv_hit_grid(aspect, mnx, mny, len(entries)) < 0 {
								if hb := inv_hit_hotbar(aspect, mnx, mny); hb >= 0 do assign_to = hb
							}
						}
						if g_input.select > 0 do assign_to = g_input.select - 1
						if assign_to >= 0 {
							e := entries[g_inv_cursor]
							if e.use_tex {
								player.hotbar[assign_to] = e.blk
								player.selected = e.blk // equip it, ready to place
								toast_show(fmt.tprintf("HOTBAR %d: %s", assign_to + 1, block_name(e.blk)))
							} else {
								toast_show("CANT PUT THAT ON THE HOTBAR")
							}
						}
					}
				case .Craft:
					if g_input.select > 0 {
						recipe_try(&player, cur, g_input.select - 1)
					}
					if ui_click {
						mnx, mny := cursor_ndc()
						if row := inv_hit_craft_row(mnx, mny); row >= 0 {
							recipe_try(&player, cur, row)
						}
					}
				case .Tools:
					if g_input.select >= 1 && g_input.select <= TOOL_KIND_COUNT {
						tool_craft(&player, ToolKind(g_input.select - 1))
					} else if g_input.select > TOOL_KIND_COUNT &&
					   g_input.select <= TOOL_KIND_COUNT + ARMOR_SLOT_COUNT {
						armor_craft(&player, ArmorSlot(g_input.select - 1 - TOOL_KIND_COUNT))
					}
				}
			}
			g_input.select = 0
		} else {
			process_input(&player, dt)
			physics_update(cur, &player, dt)
			player_tick(cur, &player, dt)
			handle_break_place(cur, &player, dt)

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
					toast_show("PORTAL LIT - STEP IN TO TRAVEL")
				} else {
					toast_show(fmt.tprintf("NEED %d OBSIDIAN FOR A PORTAL", PORTAL_COST))
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
					toast_show(fmt.tprintf("ENTERED THE %v", cur.dimension))
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

			// oxygen / drowning while the head is underwater
			player_oxygen_tick(cur, &player, dt)

			world_stream(cur, player.pos)
			mobs_update(cur, &player, &cur.mobs, dt)
			villagers_update(cur, &player, &cur.villagers, dt)
			items_update(cur, &player, &cur.items, dt)
			arrows_update(cur, &player, dt)
			weather_tick(cur, dt)
			// Precipitation type follows the biome the player is in: rain in
			// temperate country, snow in the cold biomes, nothing in deserts.
			precip := Precip.None
			if cur.raining {
				_, pbiome, _ := world_height_and_biome(cur.seed, int(player.pos.x), int(player.pos.z))
				precip = biome_precip(pbiome)
				precip_particles_spawn(&cur.particles, player.pos, precip, cur.wind_x, cur.wind_z)
			}
			audio_set_rain(precip == .Rain) // snow falls silently; deserts stay dry
			particles_update(cur, &cur.particles, dt)

			// background music by context: nether > combat > calm
			track := MusicTrack.Calm
			if cur.dimension == .Nether {
				track = .Nether
			} else {
				for m in cur.mobs {
					if !mob_is_hostile(m.kind) do continue
					dx := m.pos.x - player.pos.x
					dz := m.pos.z - player.pos.z
					if dx * dx + dz * dz < 22 * 22 {
						track = .Combat
						break
					}
				}
			}
			audio_set_music(track)
		}
		g_input.nav_up = false;g_input.nav_down = false;g_input.nav_left = false;g_input.nav_right = false

		if net_active() {
			net_send_pos(&player)
			net_apply_edits(&world, &nether)
		}

		render_remesh(cur, player.pos)
		render_frame(cur, &player, g_input.fb_w, g_input.fb_h)
		fw, fh := int(g_input.fb_w), int(g_input.fb_h)
		if g_show_inventory do ui_draw_inventory(&player, cur, fw, fh)
		else if g_show_settings do ui_draw_settings(fw, fh)
		else if g_show_chest do ui_draw_chest(&player, cur, fw, fh)
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
