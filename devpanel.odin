package main

import "core:fmt"

// A dev/creative overlay (toggle with the ` key): pick a category down the top
// and click a row to spawn a mob, drop a stack of any block into your inventory,
// teleport to the nearest chunk of a biome (or to a village / the other
// dimension), or change the time/weather/your gear. Drawn + hit-tested like the
// craft tab; the action dispatch lives in the main loop where the current
// dimension pointer is in scope.

DevCat :: enum {
	Mobs,
	Give,
	Teleport,
	World,
}

g_show_dev: bool
g_dev_cat: DevCat
g_dev_scroll: int

DEV_VISIBLE :: 20
DEV_TOP :: f32(0.60)
DEV_ROW :: f32(0.052)

// Blocks/items offered on the GIVE tab (a curated, useful subset — not every
// internal enum value like the growing wheat stages).
DEV_GIVE := [?]BlockId {
	.Grass,
	.Dirt,
	.Stone,
	.Cobblestone,
	.StoneBrick,
	.Bricks,
	.Sand,
	.RedSand,
	.Wood,
	.Planks,
	.Leaves,
	.Glass,
	.GlassPane,
	.Slab,
	.Stair,
	.Wall,
	.Fence,
	.FenceGate,
	.Ladder,
	.Door,
	.Snow,
	.Obsidian,
	.Netherrack,
	.Glowstone,
	.Torch,
	.Furnace,
	.Chest,
	.Bed,
	.Cactus,
	.Farmland,
	.Ore,
	.CoalOre,
	.GoldOre,
	.DiamondOre,
	.Iron,
	.Gold,
	.WoolWhite,
	.WoolRed,
	.WoolYellow,
	.WoolBlue,
	.CarpetWhite,
	.CarpetRed,
	.CarpetYellow,
	.CarpetBlue,
	.FlowerRed,
	.FlowerYellow,
	.FlowerBlue,
	.FlowerPink,
	.FlowerWhite,
	.TallGrass,
	.Fern,
	.DeadBush,
	.Seeds,
	.Wheat,
	.Bread,
	.RawFood,
	.CookedFood,
}

DEV_WORLD := [?]string {
	"Time: Day",
	"Time: Sunset",
	"Time: Night",
	"Time: Sunrise",
	"Weather: Clear",
	"Weather: Rain",
	"Weather: Thunderstorm",
	"Toggle Fly",
	"Heal + Feed",
	"Max Tools + Armor",
}

biome_dev_name :: proc(b: Biome) -> string {
	switch b {
	case .Ocean:
		return "Ocean"
	case .Beach:
		return "Beach"
	case .Plains:
		return "Plains"
	case .Forest:
		return "Forest"
	case .Desert:
		return "Desert"
	case .Badlands:
		return "Badlands"
	case .Snow:
		return "Snow"
	case .Mountains:
		return "Mountains"
	case .Savanna:
		return "Savanna"
	case .Swamp:
		return "Swamp"
	case .Taiga:
		return "Taiga"
	case .Jungle:
		return "Jungle"
	case .Meadow:
		return "Meadow"
	}
	return "?"
}

// Teleport tab = every biome, then two extras (village, dimension toggle).
DEV_TP_VILLAGE :: len(Biome)
DEV_TP_DIMENSION :: len(Biome) + 1

dev_entry_count :: proc(cat: DevCat) -> int {
	switch cat {
	case .Mobs:
		return MOB_KIND_COUNT
	case .Give:
		return len(DEV_GIVE)
	case .Teleport:
		return len(Biome) + 2
	case .World:
		return len(DEV_WORLD)
	}
	return 0
}

dev_entry_name :: proc(cat: DevCat, i: int) -> string {
	switch cat {
	case .Mobs:
		return mob_kind_label(MobKind(i))
	case .Give:
		return block_name(DEV_GIVE[i])
	case .Teleport:
		if i < len(Biome) do return biome_dev_name(Biome(i))
		if i == DEV_TP_VILLAGE do return "> Nearest Village"
		return "> Toggle Nether / Overworld"
	case .World:
		return DEV_WORLD[i]
	}
	return "?"
}

dev_scroll_clamp :: proc() {
	maxs := max(0, dev_entry_count(g_dev_cat) - DEV_VISIBLE)
	if g_dev_scroll < 0 do g_dev_scroll = 0
	if g_dev_scroll > maxs do g_dev_scroll = maxs
}

@(private = "file")
CATS := [?]string{"MOBS", "GIVE", "TELEPORT", "WORLD"}

// x-range of category tab i, in NDC.
@(private = "file")
dev_tab_x :: proc(i: int) -> (x0, x1: f32) {
	x0 = -0.9 + f32(i) * 0.46
	x1 = x0 + 0.42
	return
}

dev_draw :: proc(fbw, fbh: int) {
	aspect := f32(fbw) / f32(max(fbh, 1))
	hud_quad(-0.95, -0.92, 0.95, 0.9, Vec4{0.05, 0.05, 0.08, 0.97})
	ch_h: f32 = 0.045
	ch_w := ch_h / aspect * (f32(GLYPH_W) / f32(GLYPH_H))

	text_draw("DEV OVERLAY", -0.9, 0.85, ch_w, ch_h, Vec4{1, 0.9, 0.5, 1})
	text_draw("ESC CLOSES", 0.58, 0.85, ch_w * 0.8, ch_h * 0.8, Vec4{0.6, 0.65, 0.72, 1})

	for name, i in CATS {
		x0, x1 := dev_tab_x(i)
		active := DevCat(i) == g_dev_cat
		hud_quad(x0, 0.72, x1, 0.79, active ? Vec4{0.28, 0.34, 0.5, 1} : Vec4{0.12, 0.13, 0.17, 1})
		text_draw(name, x0 + 0.02, 0.775, ch_w * 0.85, ch_h * 0.85, Vec4{1, 1, 1, active ? 1 : 0.7})
	}

	dev_scroll_clamp()
	n := dev_entry_count(g_dev_cat)
	lo := g_dev_scroll
	hi := min(n, lo + DEV_VISIBLE)
	if lo > 0 do text_draw("^ more", 0.7, 0.66, ch_w * 0.8, ch_h * 0.8, Vec4{0.7, 0.8, 0.9, 1})
	y := DEV_TOP
	for i in lo ..< hi {
		give_icon := g_dev_cat == .Give
		tx: f32 = -0.88
		if give_icon {
			ui_block_icon(-0.9, y - ch_h, -0.9 + ch_h / aspect, y, DEV_GIVE[i])
			tx = -0.9 + ch_h / aspect + 0.02
		}
		text_draw(dev_entry_name(g_dev_cat, i), tx, y, ch_w * 0.85, ch_h * 0.85, Vec4{0.9, 0.95, 1, 1})
		y -= DEV_ROW
	}
	if hi < n do text_draw("v more", 0.7, y + DEV_ROW * 0.3, ch_w * 0.8, ch_h * 0.8, Vec4{0.7, 0.8, 0.9, 1})
}

// Which category tab the NDC point is over, or -1.
dev_hit_cat :: proc(nx, ny: f32) -> int {
	if ny < 0.72 || ny > 0.79 do return -1
	for i in 0 ..< len(CATS) {
		x0, x1 := dev_tab_x(i)
		if nx >= x0 && nx <= x1 do return i
	}
	return -1
}

// Which entry row the NDC point is over (already offset by scroll), or -1.
dev_hit_entry :: proc(nx, ny: f32) -> int {
	if nx < -0.92 || nx > 0.92 do return -1
	dev_scroll_clamp()
	n := dev_entry_count(g_dev_cat)
	hi := min(n, g_dev_scroll + DEV_VISIBLE)
	for i in g_dev_scroll ..< hi {
		y := DEV_TOP - f32(i - g_dev_scroll) * DEV_ROW
		if ny <= y + DEV_ROW * 0.25 && ny >= y - DEV_ROW * 0.8 do return i
	}
	return -1
}

// ---- actions (those that don't need to reassign the dimension pointer) ----

dev_spawn_mob :: proc(w: ^World, p: ^Player, kind: MobKind) {
	fwd := camera_front(p.yaw, 0)
	base := p.pos + fwd * 4
	wx, wz := int(base.x), int(base.z)
	world_ensure_chunk(w, world_chunk_at(w, wx, wz))
	sy, _ := surface_y(w, wx, wz)
	if sy < 0 do sy = int(p.pos.y)
	append(
		&w.mobs,
		Mob {
			kind = kind,
			pos = Vec3{f32(wx) + 0.5, f32(sy + 1), f32(wz) + 0.5},
			yaw = rng_range(0, 6.28),
			ai_timer = rng_range(0, 2),
			health = 12,
		},
	)
	toast_show(fmt.tprintf("SPAWNED %s", mob_kind_label(kind)))
}

// Teleport to the nearest chunk whose centre is the requested biome.
dev_teleport_biome :: proc(w: ^World, p: ^Player, target: Biome) {
	pc := world_chunk_at(w, int(p.pos.x), int(p.pos.z))
	for r in 0 ..= 96 {
		for dz in -r ..= r {
			for dx in -r ..= r {
				if max(abs(dx), abs(dz)) != r do continue
				ccx := (pc.x + dx) * CHUNK_W + CHUNK_W / 2
				ccz := (pc.y + dz) * CHUNK_D + CHUNK_D / 2
				h, b, _ := world_height_and_biome(w.seed, ccx, ccz)
				if b != target do continue
				world_ensure_chunk(w, Ivec2{pc.x + dx, pc.y + dz})
				p.pos = Vec3{f32(ccx) + 0.5, f32(h) + 2, f32(ccz) + 0.5}
				p.vel = Vec3{0, 0, 0}
				toast_show(fmt.tprintf("TELEPORTED TO %s", biome_dev_name(target)))
				return
			}
		}
	}
	toast_show(fmt.tprintf("NO %s WITHIN RANGE", biome_dev_name(target)))
}

// Find (generating chunks outward) the nearest village and teleport to it.
dev_teleport_village :: proc(w: ^World, p: ^Player) {
	pc := world_chunk_at(w, int(p.pos.x), int(p.pos.z))
	start := len(w.villages)
	for r in 0 ..= 40 {
		for dz in -r ..= r {
			for dx in -r ..= r {
				if max(abs(dx), abs(dz)) != r do continue
				world_ensure_chunk(w, Ivec2{pc.x + dx, pc.y + dz})
				if len(w.villages) > start {
					t := w.villages[len(w.villages) - 1].center
					p.pos = Vec3{f32(t.x) + 0.5, f32(t.y) + 2, f32(t.z) + 0.5}
					p.vel = Vec3{0, 0, 0}
					toast_show("TELEPORTED TO A VILLAGE")
					return
				}
			}
		}
	}
	toast_show("NO VILLAGE FOUND NEARBY")
}

dev_world_action :: proc(w: ^World, p: ^Player, row: int) {
	switch row {
	case 0:
		w.time_of_day = 0.5 // day
	case 1:
		w.time_of_day = 0.78 // sunset
	case 2:
		w.time_of_day = 0.0 // night
	case 3:
		w.time_of_day = 0.25 // sunrise
	case 4:
		w.raining = false;w.storm_level = 0;w.flash = 0
		toast_show("WEATHER: CLEAR")
	case 5:
		w.raining = true;w.storm_level = 2;w.weather_timer = 600
		toast_show("WEATHER: RAIN")
	case 6:
		w.raining = true;w.storm_level = 3;w.weather_timer = 600
		toast_show("WEATHER: THUNDERSTORM")
	case 7:
		p.fly = !p.fly
		toast_show(p.fly ? "FLY ON" : "FLY OFF")
	case 8:
		p.health = MAX_HEALTH;p.hunger = HUNGER_MAX;p.oxygen = OXYGEN_MAX
		toast_show("HEALED & FED")
	case 9:
		for k in ToolKind do p.tool_tier[k] = 4 // diamond tier
		for s in ArmorSlot {p.armor_tier[s] = 4;p.armor_dur[s] = 999}
		toast_show("MAXED TOOLS & ARMOR")
	}
}
