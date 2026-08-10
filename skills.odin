package main

import "core:fmt"

// Player skills that level up through use, Stardew/Harvest-Moon style: mining
// rock, fighting, farming and foraging each earn their own experience and grant
// a growing perk. Progress shows on the SKILLS tab and each level-up toasts.

Skill :: enum {
	Mining, // breaking stone & ore
	Combat, // fighting mobs
	Farming, // harvesting crops
	Foraging, // chopping wood & leaves
	Fishing, // reeling in catches
}

skill_name :: proc(s: Skill) -> string {
	switch s {
	case .Mining:
		return "MINING"
	case .Combat:
		return "COMBAT"
	case .Farming:
		return "FARMING"
	case .Foraging:
		return "FORAGING"
	case .Fishing:
		return "FISHING"
	}
	return "?"
}

// A one-line description of what the current level of a skill does for you.
skill_perk :: proc(s: Skill, level: int) -> string {
	switch s {
	case .Mining:
		return fmt.tprintf("+%d%% chance of a bonus ore drop", level * 5)
	case .Combat:
		return fmt.tprintf("+%d melee & arrow damage", level / 2)
	case .Farming:
		return fmt.tprintf("+%d%% chance of a bonus crop/seed", level * 6)
	case .Foraging:
		return fmt.tprintf("+%d%% chance of a bonus log", level * 5)
	case .Fishing:
		return fmt.tprintf("+%d%% chance of a bonus catch, faster bites", level * 5)
	}
	return ""
}

// Experience to go from `level` to the next — a gentle ramp so early levels come
// quickly and later ones take real investment.
skill_next :: proc(level: int) -> int {
	return 40 + level * 45
}

skill_progress :: proc(p: ^Player, s: Skill) -> f32 {
	need := skill_next(p.skill_level[s])
	return need <= 0 ? 0 : clamp(f32(p.skill_xp[s]) / f32(need), 0, 1)
}

// Bank skill experience, rolling into as many level-ups as it covers.
skill_gain :: proc(p: ^Player, s: Skill, xp: int) {
	p.skill_xp[s] += xp
	for p.skill_xp[s] >= skill_next(p.skill_level[s]) {
		p.skill_xp[s] -= skill_next(p.skill_level[s])
		p.skill_level[s] += 1
		toast_show(fmt.tprintf("%s LEVEL %d!", skill_name(s), p.skill_level[s]))
		audio_play(.Pickup, 0.7)
	}
}

// Extra melee/arrow damage from the Combat skill.
combat_damage_bonus :: proc(p: ^Player) -> int {
	return p.skill_level[.Combat] / 2
}

// Which skill (if any) breaking a block trains, and how much XP it grants.
mined_block_skill :: proc(b: BlockId) -> (Skill, int, bool) {
	#partial switch b {
	case .Stone, .Cobblestone, .CoalOre, .GoldOre, .DiamondOre, .Ore, .Gravel:
		return .Mining, 4, true
	case .Wood, .Leaves:
		return .Foraging, 3, true
	}
	return .Mining, 0, false
}
