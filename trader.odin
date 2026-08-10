package main

import "core:fmt"
import "core:math"

// The wandering trader: a rare travelling merchant that turns up near you, roams
// like a nomad, and offers to swap common goods for rarer ones. Only ever one at
// a time, and it despawns when you wander far (handled by the nomad rules).

Trade :: struct {
	in_block:  BlockId,
	in_count:  int,
	out_block: BlockId,
	out_count: int,
}

TRADES := [?]Trade {
	{.Wheat, 8, .Iron, 1},
	{.Wood, 6, .CookedFood, 2},
	{.CoalOre, 10, .GoldOre, 1},
	{.Leather, 4, .Bread, 3},
	{.Gunpowder, 3, .Glowstone, 1},
	{.DiamondOre, 1, .Iron, 6},
	{.Wheat, 3, .Carrot, 4}, // bootstraps the carrot crop (replant to grow more)
}

// Rarely spawn a lone trader near the player (never a second one), reusing the
// nomad placement rules for a valid surface spot.
trader_try_spawn :: proc(w: ^World, villagers: ^[dynamic]Villager, player_pos: Vec3) {
	for &v in villagers^ do if v.is_trader do return // at most one trader at a time

	ang := rng_range(0, 2 * math.PI)
	dist := rng_range(22, 40)
	wx := int(player_pos.x + math.cos(ang) * dist)
	wz := int(player_pos.z + math.sin(ang) * dist)
	sy, surf := surface_y(w, wx, wz)
	if sy < 0 do return
	if surf != .Grass && surf != .Sand && surf != .Snow do return
	if world_block(w, wx, sy + 1, wz) == .Water do return
	if block_is_solid(world_block(w, wx, sy + 1, wz)) do return

	_, nbiome, _ := world_height_and_biome(w.seed, wx, wz)
	append(
		villagers,
		Villager {
			pos = Vec3{f32(wx) + 0.5, f32(sy + 1), f32(wz) + 0.5},
			yaw = rng_range(0, 2 * math.PI),
			health = 10,
			name = "Wandering Trader",
			is_nomad = true, // despawns by distance like any nomad
			is_trader = true,
			profession = .Merchant,
			home_biome = nbiome,
		},
	)
	toast_show("A WANDERING TRADER HAS APPEARED NEARBY")
}

// Interacting with a trader: present its current offer, taking the payment and
// handing over the goods if you can afford it, otherwise telling you what it
// wants. Offers rotate so repeat trades cycle through the list.
trader_interact :: proc(p: ^Player, v: ^Villager) {
	n := len(TRADES)
	for off in 0 ..< n {
		t := TRADES[(v.trade_idx + off) %% n]
		if inv_has(p, t.in_block, t.in_count) {
			inv_take(p, t.in_block, t.in_count)
			inv_add(p, t.out_block, t.out_count)
			toast_show(
				fmt.tprintf(
					"TRADED %d %s -> %d %s",
					t.in_count,
					block_name(t.in_block),
					t.out_count,
					block_name(t.out_block),
				),
			)
			v.trade_idx = (v.trade_idx + off + 1) %% n
			audio_play(.Pickup, 0.6)
			return
		}
	}
	t := TRADES[v.trade_idx %% n]
	toast_show(
		fmt.tprintf(
			"TRADER WANTS %d %s (FOR %d %s)",
			t.in_count,
			block_name(t.in_block),
			t.out_count,
			block_name(t.out_block),
		),
	)
}
