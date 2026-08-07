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

ARMOR_DUR := [5]int{0, 80, 176, 336, 600} // tier 0 unused = "not owned"

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

// Cost to craft/upgrade one armor piece to its next tier (mirrors tool_next,
// including Diamond using the raw ore block directly, no smelting needed).
armor_next :: proc(p: ^Player, s: ArmorSlot) -> (tier: int, block: BlockId, count: int, ok: bool) {
	cur := p.armor_tier[s]
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

armor_craft :: proc(p: ^Player, s: ArmorSlot) {
	next, block, count, ok := armor_next(p, s)
	if !ok {
		toast_show(fmt.tprintf("%s IS ALREADY DIAMOND (MAX)", armor_name(s)))
		return
	}
	if !inv_has(p, block, count) {
		toast_show(fmt.tprintf("NEED %d %s FOR %s %s", count, block_name(block), TIER_NAMES[next], armor_name(s)))
		return
	}
	inv_take(p, block, count)
	p.armor_tier[s] = next
	p.armor_dur[s] = ARMOR_DUR[next]
	toast_show(fmt.tprintf("EQUIPPED %s %s", TIER_NAMES[next], armor_name(s)))
	audio_play(.Place, 0.5)
}

// Total armor points across all worn pieces (four slots, 0/1/2/4/6 each).
armor_points :: proc(p: ^Player) -> int {
	bonus := [5]int{0, 1, 2, 4, 6}
	total := 0
	for s in ArmorSlot do total += bonus[p.armor_tier[s]]
	return total
}

// Fraction of incoming damage armor absorbs, capped at 80% (was a full iron
// set; a full diamond set now reaches the cap with room to spare, which is
// fine — the cap is the actual ceiling, not the iron-set total).
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
