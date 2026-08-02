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

// Durability granted at tier 1..3 (index 0 unused = "not owned").
TOOL_DUR := [4]int{0, 60, 132, 251}
TIER_NAMES := [4]string{"None", "Wood", "Stone", "Iron"}

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
	case .Stone, .Ore, .Iron, .Furnace, .Glowstone, .Obsidian, .Netherrack, .Glass:
		return .Pickaxe, true
	case .Wood, .Leaves, .Cactus, .Bed, .Chest:
		return .Axe, true
	case .Dirt, .Grass, .Sand, .Snow, .Farmland:
		return .Shovel, true
	}
	return .Pickaxe, false
}

// Base seconds to break a block by hand.
block_hardness :: proc(b: BlockId) -> f32 {
	#partial switch b {
	case .Obsidian:
		return 9.0
	case .Stone, .Ore, .Iron, .Furnace, .Netherrack:
		return 2.2
	case .Wood, .Chest:
		return 1.6
	case .Dirt, .Grass, .Sand, .Snow, .Farmland:
		return 0.7
	case .Glowstone, .Glass, .Leaves, .Cactus, .Bed:
		return 0.4
	case .Wheat1, .Wheat2, .Wheat3, .Torch:
		return 0.15 // sprites pop almost instantly
	}
	return 0.8
}

// Minimum tool+tier required to break a block at all (0 = hand is fine).
// Obsidian needs an iron pickaxe.
block_min_tier :: proc(b: BlockId) -> (kind: ToolKind, tier: int) {
	if b == .Obsidian do return .Pickaxe, 3
	return .Pickaxe, 0
}

can_mine :: proc(p: ^Player, b: BlockId) -> bool {
	kind, tier := block_min_tier(b)
	if tier > 0 && p.tool_tier[kind] < tier do return false
	return true
}

// Seconds for this player to break block b, faster with a better matching tool.
mining_time :: proc(p: ^Player, b: BlockId) -> f32 {
	h := block_hardness(b)
	kind, applies := mine_tool(b)
	if applies {
		tier := p.tool_tier[kind]
		if tier > 0 do h /= f32(1 + tier) // wood /2, stone /3, iron /4
	}
	return h
}

sword_bonus :: proc(p: ^Player) -> int {
	bonus := [4]int{0, 1, 2, 4}
	return bonus[p.tool_tier[.Sword]]
}

// Spend one point of durability on a tool; it breaks (reverts to None) at zero.
tool_wear :: proc(p: ^Player, k: ToolKind) {
	if p.tool_tier[k] <= 0 do return
	p.tool_dur[k] -= 1
	if p.tool_dur[k] <= 0 {
		fmt.println("your", TIER_NAMES[p.tool_tier[k]], tool_name(k), "broke!")
		p.tool_tier[k] = 0
		p.tool_dur[k] = 0
	}
}

// Cost to craft/upgrade a tool to its next tier.
tool_next :: proc(p: ^Player, k: ToolKind) -> (tier: int, block: BlockId, count: int, ok: bool) {
	cur := p.tool_tier[k]
	next := cur + 1
	if next > 3 do return 0, .Air, 0, false
	block = next == 1 ? .Wood : (next == 2 ? .Stone : .Iron)
	count = next == 1 ? 2 : 3
	return next, block, count, true
}

tool_craft :: proc(p: ^Player, k: ToolKind) {
	next, block, count, ok := tool_next(p, k)
	if !ok {
		fmt.println(tool_name(k), "is already Iron (max)")
		return
	}
	if p.inventory[block] < count {
		fmt.println("need", count, block_name(block), "for a", TIER_NAMES[next], tool_name(k))
		return
	}
	p.inventory[block] -= count
	p.tool_tier[k] = next
	p.tool_dur[k] = TOOL_DUR[next]
	fmt.println("crafted", TIER_NAMES[next], tool_name(k))
	audio_play(.Place, 0.5)
}
