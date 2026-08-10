package main

import "core:fmt"

Ingredient :: struct {
	block: BlockId,
	count: int,
}

Recipe :: struct {
	inputs:        [3]Ingredient,
	n_in:          int,
	out:           BlockId,
	out_count:     int,
	needs_furnace: bool,
}

RECIPES := [?]Recipe {
	{inputs = {{.Stone, 8}, {}, {}}, n_in = 1, out = .Furnace, out_count = 1},
	{inputs = {{.Sand, 4}, {.Ore, 1}, {}}, n_in = 2, out = .Glowstone, out_count = 1},
	{inputs = {{.Ore, 1}, {.Wood, 1}, {}}, n_in = 2, out = .Iron, out_count = 1, needs_furnace = true},
	{inputs = {{.Sand, 1}, {.Wood, 1}, {}}, n_in = 2, out = .Glass, out_count = 1, needs_furnace = true},
	{inputs = {{.Stone, 8}, {}, {}}, n_in = 1, out = .Obsidian, out_count = 4},
	{inputs = {{.Wood, 1}, {}, {}}, n_in = 1, out = .Torch, out_count = 4},
	{inputs = {{.Wood, 5}, {}, {}}, n_in = 1, out = .Bed, out_count = 1},
	{inputs = {{.Wood, 8}, {}, {}}, n_in = 1, out = .Chest, out_count = 1},
	{inputs = {{.Stone, 3}, {}, {}}, n_in = 1, out = .Stair, out_count = 4},
	{inputs = {{.Wood, 1}, {}, {}}, n_in = 1, out = .Planks, out_count = 4},
	{inputs = {{.Stone, 4}, {}, {}}, n_in = 1, out = .Cobblestone, out_count = 4},
	{inputs = {{.Cobblestone, 4}, {}, {}}, n_in = 1, out = .StoneBrick, out_count = 4},
	{inputs = {{.Sand, 4}, {}, {}}, n_in = 1, out = .Bricks, out_count = 4, needs_furnace = true},
	{inputs = {{.Glass, 6}, {}, {}}, n_in = 1, out = .GlassPane, out_count = 16},
	{inputs = {{.Wood, 4}, {}, {}}, n_in = 1, out = .Ladder, out_count = 4},
	{inputs = {{.Cobblestone, 6}, {}, {}}, n_in = 1, out = .Wall, out_count = 6},
	{inputs = {{.Wood, 4}, {}, {}}, n_in = 1, out = .FenceGate, out_count = 2},
	{inputs = {{.Wood, 3}, {.Feather, 3}, {}}, n_in = 2, out = .Bow, out_count = 1},
	{inputs = {{.Feather, 1}, {.Stone, 1}, {}}, n_in = 2, out = .Arrow, out_count = 2},
	{inputs = {{.Wood, 3}, {.Feather, 2}, {}}, n_in = 2, out = .FishingRod, out_count = 1},
	{inputs = {{.Wood, 3}, {.CoalOre, 1}, {}}, n_in = 2, out = .Campfire, out_count = 1},
	// Dyed wool: wheat fleece coloured by a flower. Carpet: two wool -> three.
	{inputs = {{.Wheat, 4}, {.FlowerWhite, 1}, {}}, n_in = 2, out = .WoolWhite, out_count = 4},
	{inputs = {{.Wheat, 4}, {.FlowerRed, 1}, {}}, n_in = 2, out = .WoolRed, out_count = 4},
	{inputs = {{.Wheat, 4}, {.FlowerYellow, 1}, {}}, n_in = 2, out = .WoolYellow, out_count = 4},
	{inputs = {{.Wheat, 4}, {.FlowerBlue, 1}, {}}, n_in = 2, out = .WoolBlue, out_count = 4},
	{inputs = {{.WoolWhite, 2}, {}, {}}, n_in = 1, out = .CarpetWhite, out_count = 3},
	{inputs = {{.WoolRed, 2}, {}, {}}, n_in = 1, out = .CarpetRed, out_count = 3},
	{inputs = {{.WoolYellow, 2}, {}, {}}, n_in = 1, out = .CarpetYellow, out_count = 3},
	{inputs = {{.WoolBlue, 2}, {}, {}}, n_in = 1, out = .CarpetBlue, out_count = 3},
}

recipe_can_make :: proc(p: ^Player, w: ^World, r: Recipe) -> bool {
	for i in 0 ..< r.n_in {
		if !inv_has(p, r.inputs[i].block, r.inputs[i].count) do return false
	}
	if r.needs_furnace && !near_furnace(w, p) do return false
	return true
}

recipe_try :: proc(p: ^Player, w: ^World, idx: int) {
	if idx < 0 || idx >= len(RECIPES) do return
	r := RECIPES[idx]
	if !recipe_can_make(p, w, r) {
		if r.needs_furnace && !near_furnace(w, p) {
			toast_show("CRAFT: STAND NEXT TO A FURNACE")
		} else {
			toast_show("CRAFT: NOT ENOUGH MATERIALS")
		}
		return
	}
	for i in 0 ..< r.n_in {
		inv_take(p, r.inputs[i].block, r.inputs[i].count)
	}
	inv_add(p, r.out, r.out_count)
	toast_show(fmt.tprintf("MADE %d %s", r.out_count, block_name(r.out)))
	audio_play(.Place, 0.5)
}
