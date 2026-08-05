package main

import "core:fmt"

// Armor: helmet/chestplate/leggings/boots, each in wood/stone/iron tiers, sold
// through the same Tools tab (numbered 5-8) as the tools. Each equipped piece
// reduces incoming damage; there's no separate "equip" step — crafting a
// piece wears it immediately, same as tools become active the moment you
// craft them. Simplification: the reduction applies to all damage sources
// (combat, falls, lava, drowning, starvation) rather than vanilla
// Minecraft's per-source rules, keeping the single player_damage choke point.

ArmorSlot :: enum {
	Helmet,
	Chestplate,
	Leggings,
	Boots,
}
ARMOR_SLOT_COUNT :: len(ArmorSlot)

ARMOR_DUR := [4]int{0, 80, 176, 336} // tier 0 unused = "not owned"

armor_name :: proc(s: ArmorSlot) -> string {
	switch s {
	case .Helmet:
		return "Helmet"
	case .Chestplate:
		return "Chestplate"
	case .Leggings:
		return "Leggings"
	case .Boots:
		return "Boots"
	}
	return "?"
}

// Cost to craft/upgrade one armor piece to its next tier (mirrors tool_next).
armor_next :: proc(p: ^Player, s: ArmorSlot) -> (tier: int, block: BlockId, count: int, ok: bool) {
	cur := p.armor_tier[s]
	next := cur + 1
	if next > 3 do return 0, .Air, 0, false
	block = next == 1 ? .Wood : (next == 2 ? .Stone : .Iron)
	count = next == 1 ? 2 : 3
	return next, block, count, true
}

armor_craft :: proc(p: ^Player, s: ArmorSlot) {
	next, block, count, ok := armor_next(p, s)
	if !ok {
		toast_show(fmt.tprintf("%s IS ALREADY IRON (MAX)", armor_name(s)))
		return
	}
	if p.inventory[block] < count {
		toast_show(fmt.tprintf("NEED %d %s FOR %s %s", count, block_name(block), TIER_NAMES[next], armor_name(s)))
		return
	}
	p.inventory[block] -= count
	p.armor_tier[s] = next
	p.armor_dur[s] = ARMOR_DUR[next]
	toast_show(fmt.tprintf("EQUIPPED %s %s", TIER_NAMES[next], armor_name(s)))
	audio_play(.Place, 0.5)
}

// Total armor points across all worn pieces (0..16: four slots, 0/1/2/4 each).
armor_points :: proc(p: ^Player) -> int {
	bonus := [4]int{0, 1, 2, 4}
	total := 0
	for s in ArmorSlot do total += bonus[p.armor_tier[s]]
	return total
}

// Fraction of incoming damage armor absorbs, capped at 80% (full iron set).
armor_reduction :: proc(p: ^Player) -> f32 {
	return min(f32(armor_points(p)) * 0.05, 0.8)
}

// Spend one point of durability on every worn piece (called once per hit, not
// per point of damage) — a full set wears down together, like a vest would.
armor_wear :: proc(p: ^Player) {
	for s in ArmorSlot {
		if p.armor_tier[s] <= 0 do continue
		p.armor_dur[s] -= 1
		if p.armor_dur[s] <= 0 {
			toast_show(fmt.tprintf("YOUR %s %s BROKE", TIER_NAMES[p.armor_tier[s]], armor_name(s)))
			p.armor_tier[s] = 0
			p.armor_dur[s] = 0
		}
	}
}
