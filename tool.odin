package main

import "core:fmt"

// Tools: pickaxe / axe / shovel / sword, each in wood / stone / iron tiers.
// The right tool for a block mines it faster and wears down with use; a sword
// boosts melee damage. Tools live on the Player as tier + durability arrays,
// crafted/upgraded through the tools menu (X).

ToolKind :: enum {
	Pickaxe,
	Axe,
	Shovel,
	Sword,
}
TOOL_KIND_COUNT :: len(ToolKind)

// Durability granted at tier 1..4 (index 0 unused = "not owned").
TOOL_DUR := [5]int{0, 60, 132, 251, 480}
TIER_NAMES := [5]string{"None", "Wood", "Stone", "Iron", "Diamond"}

tool_name :: proc(k: ToolKind) -> string {
	switch k {
	case .Pickaxe:
		return "Pickaxe"
	case .Axe:
		return "Axe"
	case .Shovel:
		return "Shovel"
	case .Sword:
		return "Sword"
	}
	return "?"
}

// Which tool mines a block fastest. `applies` is false for hand-only blocks.
mine_tool :: proc(b: BlockId) -> (kind: ToolKind, applies: bool) {
	#partial switch b {
	case .Stone,
	     .Ore,
	     .Iron,
	     .Furnace,
	     .Glowstone,
	     .Obsidian,
	     .Netherrack,
	     .Glass,
	     .CoalOre,
	     .GoldOre,
	     .DiamondOre,
	     .Gold,
	     .Slab:
		return .Pickaxe, true
	case .Wood, .Leaves, .Cactus, .Bed, .Chest, .Door, .Fence:
		return .Axe, true
	case .Dirt, .Grass, .Sand, .Snow, .Farmland, .RedSand:
		return .Shovel, true
	}
	return .Pickaxe, false
}

// Base seconds to break a block by hand.
block_hardness :: proc(b: BlockId) -> f32 {
	#partial switch b {
	case .Obsidian:
		return 9.0
	case .DiamondOre:
		return 3.5
	case .GoldOre:
		return 3.0
	case .Stone, .Ore, .Iron, .Furnace, .Netherrack, .CoalOre, .Gold, .Slab:
		return 2.2
	case .Wood, .Chest, .Door, .Fence:
		return 1.6
	case .Dirt, .Grass, .Sand, .Snow, .Farmland, .RedSand:
		return 0.7
	case .Glowstone, .Glass, .Leaves, .Cactus, .Bed:
		return 0.4
	case .Wheat1, .Wheat2, .Wheat3, .Torch, .FlowerRed, .FlowerYellow:
		return 0.15 // sprites pop almost instantly
	}
	return 0.8
}

// Minimum tool+tier required to break a block at all (0 = hand is fine).
// Obsidian needs an iron pickaxe; gold and diamond ore are that little bit
// tougher too, matching real veins being deeper/rarer than plain stone.
block_min_tier :: proc(b: BlockId) -> (kind: ToolKind, tier: int) {
	if b == .Obsidian do return .Pickaxe, 3
	if b == .GoldOre || b == .DiamondOre do return .Pickaxe, 3
	return .Pickaxe, 0
}

can_mine :: proc(p: ^Player, b: BlockId) -> bool {
	kind, tier := block_min_tier(b)
	// a tier-gated block (obsidian etc.) needs the RIGHT tool of that tier in hand
	if tier > 0 && (p.held_tool != kind || p.tool_tier[kind] < tier) do return false
	return true
}

// Seconds for this player to break block b, faster with a better matching tool.
mining_time :: proc(p: ^Player, b: BlockId) -> f32 {
	h := block_hardness(b)
	kind, applies := mine_tool(b)
	// only the correct tool held in hand speeds mining; a wrong tool (or bare
	// hand) just chips at the block's raw hardness.
	if applies && p.held_tool == kind {
		tier := p.tool_tier[kind]
		if tier > 0 do h /= f32(1 + tier) // wood /2, stone /3, iron /4, diamond /5
	}
	return h
}

sword_bonus :: proc(p: ^Player) -> int {
	bonus := [5]int{0, 1, 2, 4, 7}
	return bonus[p.tool_tier[.Sword]]
}

// Melee damage bonus of whatever tool is currently in hand: a sword hits hardest,
// another tool does a little, a not-owned/bare hand adds nothing.
held_attack_bonus :: proc(p: ^Player) -> int {
	if p.held_tool == .Sword do return sword_bonus(p)
	if p.tool_tier[p.held_tool] > 0 do return 1 // a pick/axe/shovel is a poor weapon
	return 0
}

// Cycle the held tool to the next OWNED tool, skipping ones not yet crafted.
tool_cycle_held :: proc(p: ^Player) {
	for step in 1 ..= TOOL_KIND_COUNT {
		k := ToolKind((int(p.held_tool) + step) % TOOL_KIND_COUNT)
		if p.tool_tier[k] > 0 {
			p.held_tool = k
			toast_show(fmt.tprintf("EQUIPPED %s %s", TIER_NAMES[p.tool_tier[k]], tool_name(k)))
			return
		}
	}
}

// Spend one point of durability on a tool; it breaks (reverts to None) at zero.
tool_wear :: proc(p: ^Player, k: ToolKind) {
	if p.tool_tier[k] <= 0 do return
	p.tool_dur[k] -= 1
	if p.tool_dur[k] <= 0 {
		toast_show(fmt.tprintf("YOUR %s %s BROKE", TIER_NAMES[p.tool_tier[k]], tool_name(k)))
		p.tool_tier[k] = 0
		p.tool_dur[k] = 0
	}
}

// Cost to craft/upgrade a tool to its next tier. Diamond doesn't need
// smelting (unlike Ore -> Iron) so it uses the raw DiamondOre block
// directly, matching how mining it works in real Minecraft too.
tool_next :: proc(p: ^Player, k: ToolKind) -> (tier: int, block: BlockId, count: int, ok: bool) {
	cur := p.tool_tier[k]
	next := cur + 1
	if next > 4 do return 0, .Air, 0, false
	switch next {
	case 1:
		block, count = .Wood, 2
	case 2:
		block, count = .Stone, 3
	case 3:
		block, count = .Iron, 3
	case 4:
		block, count = .DiamondOre, 3
	}
	return next, block, count, true
}

tool_craft :: proc(p: ^Player, k: ToolKind) {
	next, block, count, ok := tool_next(p, k)
	if !ok {
		toast_show(fmt.tprintf("%s IS ALREADY DIAMOND (MAX)", tool_name(k)))
		return
	}
	if !inv_has(p, block, count) {
		toast_show(fmt.tprintf("NEED %d %s FOR %s %s", count, block_name(block), TIER_NAMES[next], tool_name(k)))
		return
	}
	inv_take(p, block, count)
	p.tool_tier[k] = next
	p.tool_dur[k] = TOOL_DUR[next]
	toast_show(fmt.tprintf("CRAFTED %s %s", TIER_NAMES[next], tool_name(k)))
	audio_play(.Place, 0.5)
}
