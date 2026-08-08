package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import gl "vendor:OpenGL"

// One box of a mob model: centre offset from the feet (local, pre-yaw), full
// size, colour, and a leg-swing sign (0 = static part).
MobPart :: struct {
	offset: Vec3,
	size:   Vec3,
	color:  Vec3,
	swing:  f32,
}

@(private = "file")
EntVert :: struct {
	pos:   Vec3,
	shade: f32,
}

e_prog: u32
e_mvp: i32
e_color: i32
e_ambient: i32
e_vao: u32
e_vbo: u32

@(private = "file")
PINK :: Vec3{0.93, 0.62, 0.64}
@(private = "file")
WHITE :: Vec3{0.95, 0.95, 0.92}
@(private = "file")
BROWN :: Vec3{0.46, 0.31, 0.18}
@(private = "file")
DARK :: Vec3{0.22, 0.20, 0.20}
@(private = "file")
ORANGE :: Vec3{0.95, 0.66, 0.16}
@(private = "file")
CREAM :: Vec3{0.86, 0.78, 0.62}
@(private = "file")
ZGREEN :: Vec3{0.30, 0.55, 0.32}
@(private = "file")
ZSKIN :: Vec3{0.26, 0.46, 0.30}
@(private = "file")
PANTS :: Vec3{0.26, 0.30, 0.52}
@(private = "file")
RBROWN :: Vec3{0.60, 0.45, 0.30}
@(private = "file")
BONE :: Vec3{0.90, 0.90, 0.84}

@(private = "file")
pig_parts := [9]MobPart {
	{{0, 0.50, 0}, {0.6, 0.5, 0.9}, PINK, 0},
	{{0, 0.55, -0.55}, {0.5, 0.5, 0.45}, PINK, 0},
	{{0, 0.48, -0.8}, {0.28, 0.2, 0.12}, {0.8, 0.5, 0.52}, 0},
	{{-0.16, 0.78, -0.5}, {0.12, 0.1, 0.06}, {0.82, 0.52, 0.54}, 0}, // ear L
	{{0.16, 0.78, -0.5}, {0.12, 0.1, 0.06}, {0.82, 0.52, 0.54}, 0}, // ear R
	{{-0.2, 0.18, -0.28}, {0.2, 0.36, 0.2}, PINK, 1},
	{{0.2, 0.18, -0.28}, {0.2, 0.36, 0.2}, PINK, 1},
	{{-0.2, 0.18, 0.28}, {0.2, 0.36, 0.2}, PINK, -1},
	{{0.2, 0.18, 0.28}, {0.2, 0.36, 0.2}, PINK, -1},
}

@(private = "file")
sheep_parts := [8]MobPart {
	{{0, 0.78, 0}, {0.7, 0.66, 0.95}, WHITE, 0},
	{{0, 0.88, -0.62}, {0.45, 0.5, 0.42}, CREAM, 0},
	{{-0.26, 0.92, -0.6}, {0.1, 0.08, 0.06}, CREAM, 0}, // ear L
	{{0.26, 0.92, -0.6}, {0.1, 0.08, 0.06}, CREAM, 0}, // ear R
	{{-0.22, 0.25, -0.3}, {0.18, 0.5, 0.18}, DARK, 1},
	{{0.22, 0.25, -0.3}, {0.18, 0.5, 0.18}, DARK, 1},
	{{-0.22, 0.25, 0.3}, {0.18, 0.5, 0.18}, DARK, -1},
	{{0.22, 0.25, 0.3}, {0.18, 0.5, 0.18}, DARK, -1},
}

@(private = "file")
cow_parts := [9]MobPart {
	{{0, 0.88, 0}, {0.76, 0.66, 1.05}, BROWN, 0},
	{{0, 0.98, -0.72}, {0.5, 0.5, 0.45}, BROWN, 0},
	{{0, 0.9, -0.98}, {0.32, 0.26, 0.12}, {0.9, 0.85, 0.8}, 0},
	{{-0.18, 1.22, -0.66}, {0.07, 0.14, 0.07}, BONE, 0}, // horn L
	{{0.18, 1.22, -0.66}, {0.07, 0.14, 0.07}, BONE, 0}, // horn R
	{{-0.26, 0.3, -0.34}, {0.2, 0.6, 0.2}, {0.3, 0.22, 0.15}, 1},
	{{0.26, 0.3, -0.34}, {0.2, 0.6, 0.2}, {0.3, 0.22, 0.15}, 1},
	{{-0.26, 0.3, 0.34}, {0.2, 0.6, 0.2}, {0.3, 0.22, 0.15}, -1},
	{{0.26, 0.3, 0.34}, {0.2, 0.6, 0.2}, {0.3, 0.22, 0.15}, -1},
}

@(private = "file")
HORSEC :: Vec3{0.42, 0.26, 0.14}
@(private = "file")
HORSEMANE :: Vec3{0.20, 0.12, 0.08}

// Taller and leaner than Cow (bigger stride, higher chest), with a separate
// neck/head instead of a flush front block and a mane/tail accent, so it
// reads as its own animal rather than a recoloured cow.
@(private = "file")
horse_parts := [9]MobPart {
	{{0, 1.05, 0}, {0.62, 0.62, 1.2}, HORSEC, 0}, // body
	{{0, 1.35, -0.68}, {0.3, 0.5, 0.32}, HORSEC, 0}, // neck (angled up-forward)
	{{0, 1.55, -0.92}, {0.26, 0.26, 0.34}, HORSEC, 0}, // head
	{{0, 1.68, -0.78}, {0.08, 0.16, 0.32}, HORSEMANE, 0}, // mane ridge
	{{0, 1.0, 0.62}, {0.08, 0.34, 0.1}, HORSEMANE, 0}, // tail
	{{-0.22, 0.4, -0.4}, {0.18, 0.8, 0.18}, HORSEC, 1}, // front-left leg
	{{0.22, 0.4, -0.4}, {0.18, 0.8, 0.18}, HORSEC, -1}, // front-right leg
	{{-0.22, 0.4, 0.4}, {0.18, 0.8, 0.18}, HORSEC, -1}, // back-left leg
	{{0.22, 0.4, 0.4}, {0.18, 0.8, 0.18}, HORSEC, 1}, // back-right leg
}

@(private = "file")
chicken_parts := [6]MobPart {
	{{0, 0.34, 0}, {0.36, 0.4, 0.5}, WHITE, 0}, // body
	{{0, 0.56, -0.22}, {0.3, 0.32, 0.3}, WHITE, 0}, // head
	{{0, 0.53, -0.42}, {0.14, 0.1, 0.16}, ORANGE, 0}, // beak
	{{-0.1, 0.12, 0.05}, {0.09, 0.24, 0.09}, ORANGE, 1}, // left leg
	{{0.1, 0.12, 0.05}, {0.09, 0.24, 0.09}, ORANGE, -1}, // right leg
	{{0, 0.46, 0.3}, {0.08, 0.24, 0.06}, WHITE, 0}, // tail feathers
}

@(private = "file")
LEOPARD :: Vec3{0.84, 0.82, 0.76}
@(private = "file")
LEOPARDDK :: Vec3{0.52, 0.50, 0.46}
@(private = "file")
CAMELC :: Vec3{0.78, 0.63, 0.39}
@(private = "file")
LLAMAC :: Vec3{0.80, 0.72, 0.56}

// Snow leopard: a low, long-bodied cat with a long tail — pale coat for the
// snow it lives in.
@(private = "file")
snowleopard_parts := [8]MobPart {
	{{0, 0.5, 0}, {0.42, 0.4, 1.1}, LEOPARD, 0}, // body
	{{0, 0.6, -0.62}, {0.34, 0.32, 0.34}, LEOPARD, 0}, // head
	{{0, 0.52, 0.66}, {0.1, 0.1, 0.42}, LEOPARDDK, 0}, // long tail
	{{-0.16, 0.22, -0.4}, {0.13, 0.44, 0.13}, LEOPARD, 1}, // front-left leg
	{{0.16, 0.22, -0.4}, {0.13, 0.44, 0.13}, LEOPARD, -1}, // front-right leg
	{{-0.16, 0.22, 0.4}, {0.13, 0.44, 0.13}, LEOPARD, -1}, // back-left leg
	{{0.16, 0.22, 0.4}, {0.13, 0.44, 0.13}, LEOPARD, 1}, // back-right leg
	{{0, 0.8, -0.58}, {0.32, 0.08, 0.04}, LEOPARDDK, 0}, // ear ridge
}

// Camel: tall, humped, long-legged and slow.
@(private = "file")
camel_parts := [9]MobPart {
	{{0, 1.1, 0}, {0.55, 0.6, 1.2}, CAMELC, 0}, // body
	{{0, 1.56, 0}, {0.4, 0.42, 0.5}, CAMELC, 0}, // hump
	{{0, 1.4, -0.68}, {0.28, 0.72, 0.3}, CAMELC, 0}, // neck (tall, forward-up)
	{{0, 1.78, -0.86}, {0.26, 0.28, 0.42}, CAMELC, 0}, // head
	{{0, 1.0, 0.66}, {0.08, 0.5, 0.08}, CAMELC, 0}, // tail
	{{-0.22, 0.5, -0.4}, {0.16, 1.0, 0.16}, CAMELC, 1}, // front-left leg
	{{0.22, 0.5, -0.4}, {0.16, 1.0, 0.16}, CAMELC, -1}, // front-right leg
	{{-0.22, 0.5, 0.4}, {0.16, 1.0, 0.16}, CAMELC, -1}, // back-left leg
	{{0.22, 0.5, 0.4}, {0.16, 1.0, 0.16}, CAMELC, 1}, // back-right leg
}

// Llama: upright long neck, tall ears, woolly build.
@(private = "file")
llama_parts := [9]MobPart {
	{{0, 0.9, 0}, {0.44, 0.55, 0.9}, LLAMAC, 0}, // body
	{{0, 1.35, -0.36}, {0.24, 0.62, 0.26}, LLAMAC, 0}, // upright neck
	{{0, 1.72, -0.44}, {0.26, 0.26, 0.34}, LLAMAC, 0}, // head
	{{-0.09, 1.94, -0.42}, {0.06, 0.16, 0.06}, LLAMAC, 0}, // left ear
	{{0.09, 1.94, -0.42}, {0.06, 0.16, 0.06}, LLAMAC, 0}, // right ear
	{{-0.18, 0.42, -0.32}, {0.15, 0.85, 0.15}, LLAMAC, 1}, // front-left leg
	{{0.18, 0.42, -0.32}, {0.15, 0.85, 0.15}, LLAMAC, -1}, // front-right leg
	{{-0.18, 0.42, 0.32}, {0.15, 0.85, 0.15}, LLAMAC, -1}, // back-left leg
	{{0.18, 0.42, 0.32}, {0.15, 0.85, 0.15}, LLAMAC, 1}, // back-right leg
}

@(private = "file")
zombie_parts := [6]MobPart {
	{{-0.13, 0.45, 0}, {0.22, 0.9, 0.22}, PANTS, 1}, // left leg
	{{0.13, 0.45, 0}, {0.22, 0.9, 0.22}, PANTS, -1}, // right leg
	{{0, 1.2, 0}, {0.5, 0.62, 0.28}, ZGREEN, 0}, // body
	{{0, 1.68, 0}, {0.42, 0.42, 0.42}, ZSKIN, 0}, // head
	{{-0.36, 1.2, 0.28}, {0.16, 0.6, 0.16}, ZGREEN, -1}, // left arm
	{{0.36, 1.2, -0.28}, {0.16, 0.6, 0.16}, ZGREEN, 1}, // right arm
}

@(private = "file")
rabbit_parts := [6]MobPart {
	{{0, 0.20, 0.05}, {0.24, 0.24, 0.36}, RBROWN, 0}, // body
	{{0, 0.30, -0.18}, {0.22, 0.22, 0.20}, RBROWN, 0}, // head
	{{-0.06, 0.46, -0.16}, {0.06, 0.20, 0.05}, RBROWN, 0}, // left ear
	{{0.06, 0.46, -0.16}, {0.06, 0.20, 0.05}, RBROWN, 0}, // right ear
	{{-0.08, 0.09, 0}, {0.10, 0.18, 0.14}, RBROWN, 1}, // left hind leg
	{{0.08, 0.09, 0}, {0.10, 0.18, 0.14}, RBROWN, -1}, // right hind leg
}

@(private = "file")
skeleton_parts := [6]MobPart {
	{{-0.11, 0.45, 0}, {0.14, 0.9, 0.14}, BONE, 1}, // left leg
	{{0.11, 0.45, 0}, {0.14, 0.9, 0.14}, BONE, -1}, // right leg
	{{0, 1.2, 0}, {0.36, 0.6, 0.2}, BONE, 0}, // body
	{{0, 1.66, 0}, {0.4, 0.4, 0.4}, BONE, 0}, // head
	{{-0.28, 1.2, 0.1}, {0.12, 0.6, 0.12}, BONE, -1}, // left arm
	{{0.28, 1.2, -0.1}, {0.12, 0.6, 0.12}, BONE, 1}, // right arm
}

@(private = "file")
PIGSKIN :: Vec3{0.84, 0.54, 0.55}
@(private = "file")
PIGCLOTH :: Vec3{0.42, 0.30, 0.32}
@(private = "file")
GHASTW :: Vec3{0.87, 0.85, 0.84}
@(private = "file")
GHASTFACE :: Vec3{0.20, 0.16, 0.22}

@(private = "file")
piglin_parts := [6]MobPart {
	{{-0.13, 0.45, 0}, {0.22, 0.9, 0.22}, PIGCLOTH, 1}, // left leg
	{{0.13, 0.45, 0}, {0.22, 0.9, 0.22}, PIGCLOTH, -1}, // right leg
	{{0, 1.2, 0}, {0.5, 0.62, 0.28}, {0.55, 0.42, 0.44}, 0}, // body
	{{0, 1.68, 0}, {0.52, 0.44, 0.44}, PIGSKIN, 0}, // big snouted head
	{{-0.36, 1.2, 0}, {0.16, 0.6, 0.16}, PIGSKIN, -1}, // left arm
	{{0.36, 1.2, 0}, {0.16, 0.6, 0.16}, PIGSKIN, 1}, // right arm
}

@(private = "file")
ghast_parts := [7]MobPart {
	{{0, 0.95, 0}, {1.3, 1.3, 1.3}, GHASTW, 0}, // body
	{{0, 0.98, -0.66}, {0.52, 0.18, 0.06}, GHASTFACE, 0}, // mouth
	{{-0.42, 0.18, -0.42}, {0.15, 0.55, 0.15}, GHASTW, 1}, // tentacles
	{{0.42, 0.18, -0.42}, {0.15, 0.55, 0.15}, GHASTW, -1},
	{{-0.42, 0.18, 0.42}, {0.15, 0.55, 0.15}, GHASTW, -1},
	{{0.42, 0.18, 0.42}, {0.15, 0.55, 0.15}, GHASTW, 1},
	{{0, 0.18, 0}, {0.15, 0.55, 0.15}, GHASTW, 1},
}

@(private = "file")
FISHC :: Vec3{0.80, 0.55, 0.30}
@(private = "file")
SQUIDC :: Vec3{0.68, 0.58, 0.72}

@(private = "file")
fish_parts := [5]MobPart {
	{{0, 0.14, -0.02}, {0.15, 0.13, 0.28}, FISHC, 0}, // body
	{{0, 0.14, -0.18}, {0.09, 0.09, 0.10}, FISHC, 0}, // head, tapered narrower
	{{0, 0.14, 0.20}, {0.03, 0.12, 0.14}, FISHC, 1}, // tail fin (wiggles)
	{{0, 0.22, -0.02}, {0.10, 0.03, 0.10}, FISHC, 0}, // dorsal fin
	{{0.08, 0.10, -0.02}, {0.08, 0.02, 0.08}, FISHC, 0}, // pectoral fin
}

@(private = "file")
squid_parts := [7]MobPart {
	{{0, 0.32, 0}, {0.34, 0.30, 0.34}, SQUIDC, 0}, // mantle (lower, wider)
	{{0, 0.50, 0}, {0.22, 0.18, 0.22}, SQUIDC, 0}, // mantle taper (upper, narrower)
	{{-0.10, 0.06, -0.10}, {0.06, 0.30, 0.06}, SQUIDC, 1}, // tentacles (sway)
	{{0.10, 0.06, -0.10}, {0.06, 0.30, 0.06}, SQUIDC, -1},
	{{-0.10, 0.06, 0.10}, {0.06, 0.30, 0.06}, SQUIDC, -1},
	{{0.10, 0.06, 0.10}, {0.06, 0.30, 0.06}, SQUIDC, 1},
	{{0, 0.06, 0}, {0.06, 0.28, 0.06}, SQUIDC, -1}, // centre tentacle
}

@(private = "file")
DOLPHINC :: Vec3{0.56, 0.63, 0.72}
@(private = "file")
PUFFERC :: Vec3{0.86, 0.74, 0.32}
@(private = "file")
JELLYC :: Vec3{0.80, 0.62, 0.86}

// Dolphin: sleek torpedo body with a snout, dorsal fin, flippers and a
// side-swaying tail.
@(private = "file")
dolphin_parts := [6]MobPart {
	{{0, 0.28, 0}, {0.26, 0.26, 0.7}, DOLPHINC, 0}, // body
	{{0, 0.26, -0.42}, {0.16, 0.15, 0.24}, DOLPHINC, 0}, // snout
	{{0, 0.44, 0.02}, {0.06, 0.14, 0.14}, DOLPHINC, 0}, // dorsal fin
	{{0, 0.28, 0.44}, {0.04, 0.16, 0.2}, DOLPHINC, 1}, // tail (sways)
	{{-0.15, 0.2, -0.06}, {0.14, 0.03, 0.1}, DOLPHINC, 0}, // left flipper
	{{0.15, 0.2, -0.06}, {0.14, 0.03, 0.1}, DOLPHINC, 0}, // right flipper
}

// Pufferfish: a round body bristling with little spikes.
@(private = "file")
pufferfish_parts := [6]MobPart {
	{{0, 0.24, 0}, {0.26, 0.26, 0.26}, PUFFERC, 0}, // round body
	{{0, 0.24, 0.18}, {0.03, 0.1, 0.1}, PUFFERC, 1}, // tail
	{{0, 0.41, 0}, {0.06, 0.08, 0.06}, PUFFERC, 0}, // top spike
	{{0, 0.07, 0}, {0.06, 0.08, 0.06}, PUFFERC, 0}, // bottom spike
	{{-0.16, 0.24, 0.02}, {0.08, 0.06, 0.06}, PUFFERC, 0}, // left spike
	{{0.16, 0.24, 0.02}, {0.08, 0.06, 0.06}, PUFFERC, 0}, // right spike
}

// Jellyfish: a domed bell over four drifting tentacles.
@(private = "file")
jellyfish_parts := [6]MobPart {
	{{0, 0.42, 0}, {0.3, 0.22, 0.3}, JELLYC, 0}, // bell top
	{{0, 0.3, 0}, {0.24, 0.1, 0.24}, JELLYC, 0}, // bell rim
	{{-0.08, 0.12, -0.08}, {0.04, 0.24, 0.04}, JELLYC, 1}, // tentacles (sway)
	{{0.08, 0.12, -0.08}, {0.04, 0.24, 0.04}, JELLYC, -1},
	{{-0.08, 0.12, 0.08}, {0.04, 0.24, 0.04}, JELLYC, -1},
	{{0.08, 0.12, 0.08}, {0.04, 0.24, 0.04}, JELLYC, 1},
}

@(private = "file")
PSKIN :: Vec3{0.86, 0.70, 0.56}
@(private = "file")
PSHIRT :: Vec3{0.20, 0.55, 0.75}

@(private = "file")
player_parts := [6]MobPart {
	{{-0.11, 0.45, 0}, {0.14, 0.9, 0.14}, PANTS, 0}, // left leg
	{{0.11, 0.45, 0}, {0.14, 0.9, 0.14}, PANTS, 0}, // right leg
	{{0, 1.2, 0}, {0.4, 0.62, 0.22}, PSHIRT, 0}, // body
	{{0, 1.66, 0}, {0.42, 0.42, 0.42}, PSKIN, 0}, // head
	{{-0.31, 1.2, 0}, {0.14, 0.6, 0.14}, PSKIN, 0}, // left arm
	{{0.31, 1.2, 0}, {0.14, 0.6, 0.14}, PSKIN, 0}, // right arm
}

@(private = "file")
VSKIN :: Vec3{0.82, 0.64, 0.52}

// Sentinel colour: any part painted with this in villager_parts gets
// replaced by profession_color(v.profession) at draw time, so the same part
// list works for every profession instead of needing one array per look.
@(private = "file")
VROBE_MARKER :: Vec3{-1, -1, -1}

@(private = "file")
villager_parts := [6]MobPart {
	{{-0.11, 0.45, 0}, {0.14, 0.9, 0.14}, VSKIN, 1}, // left leg
	{{0.11, 0.45, 0}, {0.14, 0.9, 0.14}, VSKIN, -1}, // right leg
	{{0, 1.2, 0}, {0.42, 0.62, 0.24}, VROBE_MARKER, 0}, // body/robe
	{{0, 1.66, 0}, {0.4, 0.42, 0.4}, VSKIN, 0}, // head
	{{-0.29, 1.2, 0}, {0.14, 0.6, 0.14}, VROBE_MARKER, -1}, // left arm (opposes left leg)
	{{0.29, 1.2, 0}, {0.14, 0.6, 0.14}, VROBE_MARKER, 1}, // right arm
}

// Distinct robe colour per profession, so villagers read as different
// people at a glance instead of palette-identical copies.
profession_color :: proc(p: Profession) -> Vec3 {
	switch p {
	case .Farmer:
		return Vec3{0.62, 0.52, 0.24} // straw brown
	case .Priest:
		return Vec3{0.85, 0.85, 0.82} // white/grey vestments
	case .Blacksmith:
		return Vec3{0.30, 0.26, 0.24} // dark leather apron
	case .Merchant:
		return Vec3{0.55, 0.16, 0.18} // deep red
	case .Guard:
		return Vec3{0.40, 0.42, 0.46} // steel grey
	case .None:
		return Vec3{0.50, 0.46, 0.36} // fallback; nomads use NOMAD_PALETTE instead
	}
	return Vec3{0.42, 0.34, 0.58}
}

// A Guard's spear, drawn as one extra part on top of the shared humanoid
// base — the first villager accessory beyond palette, so a Guard is
// silhouette-distinct on top of being colour-distinct.
@(private = "file")
GUARD_SPEAR :: Vec3{0.55, 0.48, 0.38}
@(private = "file")
guard_spear_part := MobPart{{0.32, 1.35, 0}, {0.07, 1.3, 0.07}, GUARD_SPEAR, 0}

// Nomads (Profession.None) have no building to anchor a role colour, and
// they're the villager a player is statistically most likely to actually
// run into — villages are rare, so if every nomad shared one flat earth
// tone, "most villagers a player ever sees" would in practice all look
// identical regardless of how distinct the profession colours are. Each
// nomad instead picks from a small palette by a hash of their own name.
@(private = "file")
NOMAD_PALETTE := []Vec3 {
	{0.50, 0.46, 0.36}, // sand
	{0.34, 0.42, 0.30}, // moss
	{0.55, 0.30, 0.22}, // rust leather
	{0.30, 0.32, 0.44}, // dusk blue
	{0.46, 0.40, 0.55}, // faded violet
	{0.42, 0.42, 0.42}, // ash grey
	{0.58, 0.48, 0.20}, // ochre
	{0.26, 0.46, 0.42}, // teal
}

// FNV-1a: a small, dependency-free string hash for deriving per-villager
// visual variation from their name (stable for a given villager, distinct
// villager to villager).
@(private = "file")
hash_string :: proc(s: string) -> u64 {
	h := u64(0xcbf29ce484222325)
	for c in s {
		h ~= u64(c)
		h *= 0x100000001b3
	}
	return h
}

// A small per-individual colour jitter on top of the profession colour, so
// even two villagers with the same profession (e.g. two farmers in
// different villages) don't render pixel-identical.
@(private = "file")
individual_color_jitter :: proc(h: u64) -> Vec3 {
	r := f32(h % 100) / 100.0 - 0.5
	g := f32((h >> 8) % 100) / 100.0 - 0.5
	b := f32((h >> 16) % 100) / 100.0 - 0.5
	return Vec3{r, g, b} * 0.12
}

// Villagers dress for where they live: heavy coats + fur hats in the cold,
// light linen + sun hats in the hot/arid biomes, ordinary robes elsewhere.
@(private = "file")
VClimate :: enum {
	Temperate,
	Cold,
	Arid,
}

@(private = "file")
villager_climate :: proc(b: Biome) -> VClimate {
	#partial switch b {
	case .Snow, .Taiga, .Mountains:
		return .Cold
	case .Desert, .Badlands, .Savanna:
		return .Arid
	}
	return .Temperate
}

@(private = "file")
mix3 :: proc(a, b: Vec3, t: f32) -> Vec3 {
	return a * (1 - t) + b * t
}

@(private = "file")
villager_robe_color :: proc(v: ^Villager) -> Vec3 {
	h := hash_string(v.name)
	col: Vec3
	if v.profession == .None {
		col = NOMAD_PALETTE[h % u64(len(NOMAD_PALETTE))]
	} else {
		col = profession_color(v.profession) + individual_color_jitter(h)
	}
	// Bias the garment toward the biome's clothing: a bundled dark coat in the
	// cold, pale linen in the heat.
	switch villager_climate(v.home_biome) {
	case .Cold:
		col = mix3(col, Vec3{0.32, 0.30, 0.38}, 0.42)
	case .Arid:
		col = mix3(col, Vec3{0.84, 0.76, 0.56}, 0.40)
	case .Temperate:
	}
	return Vec3{clamp(col.r, 0, 1), clamp(col.g, 0, 1), clamp(col.b, 0, 1)}
}

// A hat drawn on top of the head for cold/arid villagers, so their outfit reads
// at a glance even in silhouette.
@(private = "file")
FUR_HAT :: Vec3{0.42, 0.30, 0.20}
@(private = "file")
SUN_HAT :: Vec3{0.82, 0.74, 0.48}

@(private = "file")
emit_headwear :: proc(vp, base: Mat4, v: ^Villager) {
	switch villager_climate(v.home_biome) {
	case .Cold:
		draw_cube(vp, base, Vec3{0, 1.92, 0}, Vec3{0.48, 0.20, 0.48}, FUR_HAT) // fur cap
		draw_cube(vp, base, Vec3{0, 1.80, -0.2}, Vec3{0.46, 0.10, 0.10}, FUR_HAT) // front band
	case .Arid:
		draw_cube(vp, base, Vec3{0, 1.90, 0}, Vec3{0.72, 0.06, 0.72}, SUN_HAT) // wide brim
		draw_cube(vp, base, Vec3{0, 1.97, 0}, Vec3{0.34, 0.12, 0.34}, SUN_HAT) // crown
	case .Temperate:
	}
}

// A little build variation (0.92x-1.08x) from the same name hash, so
// villagers don't all share one identical silhouette either.
@(private = "file")
villager_build_scale :: proc(v: ^Villager) -> f32 {
	h := hash_string(v.name) >> 24
	return 0.92 + f32(h % 100) / 100.0 * 0.16
}

// Draw villagers as robed humanoids — the robe colour comes from their
// profession, jittered per-individual (or, for nomads with no profession
// to anchor a colour, picked from a dedicated palette) so different
// villagers read as visibly different people, not interchangeable copies.
villagers_render_frame :: proc(villagers: ^[dynamic]Villager, vp: Mat4, ambient: f32) {
	if len(villagers^) == 0 do return
	gl.UseProgram(e_prog)
	gl.Uniform1f(e_ambient, ambient)
	gl.BindVertexArray(e_vao)
	for i in 0 ..< len(villagers^) {
		v := &villagers^[i]
		build := villager_build_scale(v)
		base :=
			linalg.matrix4_translate_f32(v.pos) *
			linalg.matrix4_rotate_f32(-v.yaw, Vec3{0, 1, 0}) *
			linalg.matrix4_scale_f32(Vec3{build, build, build})
		sw := math.sin(v.walk_phase)
		robe := villager_robe_color(v)
		for pt in villager_parts {
			model := limb_model(base, pt, sw, true)
			ent_set_mat4(e_mvp, vp * model)
			col := pt.color == VROBE_MARKER ? robe : pt.color
			gl.Uniform3f(e_color, col.r, col.g, col.b)
			gl.DrawArrays(gl.TRIANGLES, 0, 36)
		}
		emit_face(vp, base, villager_face_def(v))
		emit_headwear(vp, base, v)
		if v.profession == .Guard {
			model :=
				base *
				linalg.matrix4_translate_f32(guard_spear_part.offset) *
				linalg.matrix4_scale_f32(guard_spear_part.size)
			ent_set_mat4(e_mvp, vp * model)
			gl.Uniform3f(e_color, GUARD_SPEAR.r, GUARD_SPEAR.g, GUARD_SPEAR.b)
			gl.DrawArrays(gl.TRIANGLES, 0, 36)
		}
	}
	gl.BindVertexArray(0)
}

@(private = "file")
remotes_buf: [dynamic]RemotePlayer

// Draw other networked players as blue humanoids.
remotes_render_frame :: proc(vp: Mat4, ambient: f32) {
	if !net_active() do return
	net_remotes_snapshot(&remotes_buf)
	if len(remotes_buf) == 0 do return
	gl.UseProgram(e_prog)
	gl.Uniform1f(e_ambient, ambient)
	gl.BindVertexArray(e_vao)
	for rp in remotes_buf {
		base :=
			linalg.matrix4_translate_f32(rp.pos) *
			linalg.matrix4_rotate_f32(-rp.yaw, Vec3{0, 1, 0})
		for pt in player_parts {
			model :=
				base *
				linalg.matrix4_translate_f32(pt.offset) *
				linalg.matrix4_scale_f32(pt.size)
			ent_set_mat4(e_mvp, vp * model)
			gl.Uniform3f(e_color, pt.color.r, pt.color.g, pt.color.b)
			gl.DrawArrays(gl.TRIANGLES, 0, 36)
		}
		emit_face(vp, base, player_face)
	}
	gl.BindVertexArray(0)
}

@(private = "file")
WOLFC :: Vec3{0.62, 0.62, 0.66}
@(private = "file")
WOLFDK :: Vec3{0.40, 0.40, 0.44}
@(private = "file")
CATC :: Vec3{0.85, 0.55, 0.25}
@(private = "file")
FOXC :: Vec3{0.82, 0.42, 0.16}
@(private = "file")
FOXDK :: Vec3{0.50, 0.28, 0.12}
@(private = "file")
GOATC :: Vec3{0.86, 0.84, 0.80}
@(private = "file")
GOATDK :: Vec3{0.40, 0.36, 0.30}
@(private = "file")
DEERC :: Vec3{0.60, 0.42, 0.24}
@(private = "file")
DEERDK :: Vec3{0.45, 0.32, 0.20}
@(private = "file")
BEEY :: Vec3{0.92, 0.78, 0.20}
@(private = "file")
BEEDK :: Vec3{0.20, 0.16, 0.10}
@(private = "file")
TURTLESH :: Vec3{0.32, 0.50, 0.28}
@(private = "file")
TURTLEBODY :: Vec3{0.50, 0.60, 0.35}
@(private = "file")
TURTLESK :: Vec3{0.55, 0.62, 0.40}

@(private = "file")
wolf_parts := [8]MobPart {
	{{0, 0.62, 0}, {0.34, 0.42, 0.78}, WOLFC, 0}, // body
	{{0, 0.72, -0.5}, {0.32, 0.34, 0.34}, WOLFC, 0}, // head
	{{0, 0.66, -0.7}, {0.18, 0.18, 0.18}, WOLFDK, 0}, // snout
	{{0, 0.74, 0.46}, {0.12, 0.12, 0.34}, WOLFC, 0}, // tail
	{{-0.16, 0.24, -0.28}, {0.14, 0.48, 0.14}, WOLFC, 1},
	{{0.16, 0.24, -0.28}, {0.14, 0.48, 0.14}, WOLFC, -1},
	{{-0.16, 0.24, 0.28}, {0.14, 0.48, 0.14}, WOLFC, -1},
	{{0.16, 0.24, 0.28}, {0.14, 0.48, 0.14}, WOLFC, 1},
}

@(private = "file")
cat_parts := [9]MobPart {
	{{0, 0.34, 0}, {0.2, 0.24, 0.5}, CATC, 0}, // body
	{{0, 0.42, -0.32}, {0.22, 0.22, 0.22}, CATC, 0}, // head
	{{-0.08, 0.56, -0.32}, {0.06, 0.1, 0.05}, CATC, 0}, // ear L
	{{0.08, 0.56, -0.32}, {0.06, 0.1, 0.05}, CATC, 0}, // ear R
	{{0, 0.5, 0.26}, {0.07, 0.3, 0.07}, CATC, 0}, // upright tail
	{{-0.09, 0.12, -0.16}, {0.08, 0.26, 0.08}, CATC, 1},
	{{0.09, 0.12, -0.16}, {0.08, 0.26, 0.08}, CATC, -1},
	{{-0.09, 0.12, 0.16}, {0.08, 0.26, 0.08}, CATC, -1},
	{{0.09, 0.12, 0.16}, {0.08, 0.26, 0.08}, CATC, 1},
}

@(private = "file")
fox_parts := [10]MobPart {
	{{0, 0.4, 0}, {0.24, 0.28, 0.62}, FOXC, 0}, // body
	{{0, 0.5, -0.42}, {0.24, 0.24, 0.26}, FOXC, 0}, // head
	{{0, 0.44, -0.58}, {0.12, 0.12, 0.14}, WHITE, 0}, // white snout
	{{-0.09, 0.66, -0.42}, {0.07, 0.12, 0.05}, FOXDK, 0}, // ear L
	{{0.09, 0.66, -0.42}, {0.07, 0.12, 0.05}, FOXDK, 0}, // ear R
	{{0, 0.4, 0.46}, {0.16, 0.16, 0.36}, WHITE, 0}, // bushy white-tipped tail
	{{-0.12, 0.14, -0.2}, {0.1, 0.3, 0.1}, FOXDK, 1},
	{{0.12, 0.14, -0.2}, {0.1, 0.3, 0.1}, FOXDK, -1},
	{{-0.12, 0.14, 0.2}, {0.1, 0.3, 0.1}, FOXDK, -1},
	{{0.12, 0.14, 0.2}, {0.1, 0.3, 0.1}, FOXDK, 1},
}

@(private = "file")
goat_parts := [9]MobPart {
	{{0, 0.72, 0}, {0.4, 0.5, 0.85}, GOATC, 0}, // body
	{{0, 0.9, -0.55}, {0.32, 0.34, 0.34}, GOATC, 0}, // head
	{{-0.1, 1.16, -0.55}, {0.06, 0.18, 0.06}, GOATDK, 0}, // horn L
	{{0.1, 1.16, -0.55}, {0.06, 0.18, 0.06}, GOATDK, 0}, // horn R
	{{0, 0.78, -0.72}, {0.1, 0.14, 0.08}, WHITE, 0}, // beard
	{{-0.24, 0.3, -0.3}, {0.16, 0.6, 0.16}, GOATC, 1},
	{{0.24, 0.3, -0.3}, {0.16, 0.6, 0.16}, GOATC, -1},
	{{-0.24, 0.3, 0.3}, {0.16, 0.6, 0.16}, GOATC, -1},
	{{0.24, 0.3, 0.3}, {0.16, 0.6, 0.16}, GOATC, 1},
}

@(private = "file")
deer_parts := [10]MobPart {
	{{0, 0.95, 0}, {0.4, 0.5, 0.95}, DEERC, 0}, // body
	{{0, 1.25, -0.55}, {0.24, 0.4, 0.28}, DEERC, 0}, // neck
	{{0, 1.5, -0.7}, {0.22, 0.22, 0.3}, DEERC, 0}, // head
	{{-0.1, 1.72, -0.72}, {0.05, 0.24, 0.05}, DEERDK, 0}, // antler L
	{{0.1, 1.72, -0.72}, {0.05, 0.24, 0.05}, DEERDK, 0}, // antler R
	{{0, 0.95, 0.5}, {0.08, 0.16, 0.1}, WHITE, 0}, // tail
	{{-0.22, 0.36, -0.35}, {0.14, 0.72, 0.14}, DEERC, 1},
	{{0.22, 0.36, -0.35}, {0.14, 0.72, 0.14}, DEERC, -1},
	{{-0.22, 0.36, 0.35}, {0.14, 0.72, 0.14}, DEERC, -1},
	{{0.22, 0.36, 0.35}, {0.14, 0.72, 0.14}, DEERC, 1},
}

// Bee has no legs (it hovers); its wings use the fin-style z-sway (swing -1).
@(private = "file")
bee_parts := [6]MobPart {
	{{0, 0.4, 0.08}, {0.24, 0.24, 0.28}, BEEY, 0}, // abdomen
	{{0, 0.4, -0.1}, {0.22, 0.22, 0.16}, BEEDK, 0}, // thorax stripe
	{{0, 0.42, -0.28}, {0.18, 0.18, 0.16}, BEEDK, 0}, // head
	{{-0.16, 0.52, 0}, {0.02, 0.02, 0.2}, WHITE, -1}, // wing L
	{{0.16, 0.52, 0}, {0.02, 0.02, 0.2}, WHITE, -1}, // wing R
	{{0, 0.4, 0.26}, {0.05, 0.05, 0.08}, BEEDK, 0}, // stinger
}

// Turtle is aquatic: flippers use the fin sway (swing -1), not a leg stride.
@(private = "file")
turtle_parts := [7]MobPart {
	{{0, 0.28, 0}, {0.6, 0.3, 0.7}, TURTLESH, 0}, // shell
	{{0, 0.18, -0.02}, {0.5, 0.14, 0.6}, TURTLEBODY, 0}, // underbelly
	{{0, 0.26, -0.44}, {0.2, 0.18, 0.2}, TURTLESK, 0}, // head
	{{-0.34, 0.16, -0.24}, {0.16, 0.1, 0.22}, TURTLESK, -1}, // front flipper L
	{{0.34, 0.16, -0.24}, {0.16, 0.1, 0.22}, TURTLESK, -1}, // front flipper R
	{{-0.34, 0.16, 0.24}, {0.16, 0.1, 0.22}, TURTLESK, -1}, // rear flipper L
	{{0.34, 0.16, 0.24}, {0.16, 0.1, 0.22}, TURTLESK, -1}, // rear flipper R
}

mob_parts :: proc(k: MobKind) -> []MobPart {
	switch k {
	case .Pig:
		return pig_parts[:]
	case .Sheep:
		return sheep_parts[:]
	case .Cow:
		return cow_parts[:]
	case .Chicken:
		return chicken_parts[:]
	case .Rabbit:
		return rabbit_parts[:]
	case .Horse:
		return horse_parts[:]
	case .Zombie:
		return zombie_parts[:]
	case .Skeleton:
		return skeleton_parts[:]
	case .Piglin:
		return piglin_parts[:]
	case .Ghast:
		return ghast_parts[:]
	case .Fish:
		return fish_parts[:]
	case .Squid:
		return squid_parts[:]
	case .Dolphin:
		return dolphin_parts[:]
	case .Pufferfish:
		return pufferfish_parts[:]
	case .Jellyfish:
		return jellyfish_parts[:]
	case .SnowLeopard:
		return snowleopard_parts[:]
	case .Camel:
		return camel_parts[:]
	case .Llama:
		return llama_parts[:]
	case .Wolf:
		return wolf_parts[:]
	case .Cat:
		return cat_parts[:]
	case .Fox:
		return fox_parts[:]
	case .Goat:
		return goat_parts[:]
	case .Deer:
		return deer_parts[:]
	case .Bee:
		return bee_parts[:]
	case .Turtle:
		return turtle_parts[:]
	}
	return pig_parts[:]
}

@(private = "file")
ent_set_mat4 :: proc(loc: i32, m: Mat4) {
	mm := m
	gl.UniformMatrix4fv(loc, 1, false, transmute([^]f32)(&mm[0, 0]))
}

// Model matrix for one body part, animating limbs from the walk phase.
//   swing == 0        : a static part, drawn in place.
//   pivot (legs/arms) : the limb rotates about its TOP edge (the hip or
//                       shoulder) so the foot/hand arcs forward and back like a
//                       real stride, instead of the whole rigid box sliding.
//   else (fins etc.)  : the gentle z-sway aquatic parts always had.
@(private = "file")
limb_model :: proc(base: Mat4, pt: MobPart, sw: f32, pivot: bool) -> Mat4 {
	if pt.swing == 0 {
		return base * linalg.matrix4_translate_f32(pt.offset) * linalg.matrix4_scale_f32(pt.size)
	}
	if pivot {
		angle := pt.swing * sw * 0.6
		half := Vec3{0, pt.size.y * 0.5, 0}
		return(
			base *
			linalg.matrix4_translate_f32(pt.offset + half) * // to the hip/shoulder
			linalg.matrix4_rotate_f32(angle, Vec3{1, 0, 0}) *
			linalg.matrix4_translate_f32(-half) * // back down to the box centre
			linalg.matrix4_scale_f32(pt.size) \
		)
	}
	off := pt.offset
	off.z += pt.swing * sw * 0.16
	return base * linalg.matrix4_translate_f32(off) * linalg.matrix4_scale_f32(pt.size)
}

// Facial features so heads read as faces, not blank boxes. Rather than hand-
// adding eye/mouth/hair cubes to every model array (and threading them through
// the limb animation), a MobFace describes just the head box; emit_face paints
// the features onto its front (-Z, the heading) at draw time.
MobFaceStyle :: enum {
	None, // no face (tiny/aquatic mobs)
	Humanoid, // eyes + nose + mouth + hair
	Animal, // eyes only (snout/beak already modelled as body parts)
}

MobFace :: struct {
	center: Vec3, // head-box centre offset (feet-relative, pre-yaw)
	size:   Vec3, // head-box size
	style:  MobFaceStyle,
	skin:   Vec3, // nose colour (Humanoid)
	hair:   Vec3, // hair colour (Humanoid)
	eye:    Vec3, // pupil / socket colour
}

@(private = "file")
EYE_WHITE :: Vec3{0.95, 0.95, 0.93}
@(private = "file")
EYE_DARK :: Vec3{0.11, 0.10, 0.10}
@(private = "file")
MOUTH :: Vec3{0.40, 0.20, 0.20}

@(private = "file")
draw_cube :: proc(vp, base: Mat4, center, size, color: Vec3) {
	model := base * linalg.matrix4_translate_f32(center) * linalg.matrix4_scale_f32(size)
	ent_set_mat4(e_mvp, vp * model)
	gl.Uniform3f(e_color, color.r, color.g, color.b)
	gl.DrawArrays(gl.TRIANGLES, 0, 36)
}

@(private = "file")
emit_face :: proc(vp, base: Mat4, fd: MobFace) {
	if fd.style == .None do return
	hs := fd.size
	// Front face is -Z; nudge features a hair further out so they never z-fight
	// with the head cube.
	fz := fd.center.z - hs.z * 0.5 - 0.005
	ex := hs.x * 0.24 // eye offset either side of centre
	ey := fd.center.y + hs.y * 0.10 // eyes a touch above the head centre
	signs := [2]f32{-1, 1}

	if fd.style == .Humanoid {
		for s in signs {
			draw_cube(vp, base, Vec3{s * ex, ey, fz}, Vec3{hs.x * 0.16, hs.y * 0.15, 0.04}, EYE_WHITE)
			draw_cube(
				vp,
				base,
				Vec3{s * ex, ey, fz - 0.012},
				Vec3{hs.x * 0.08, hs.y * 0.10, 0.05},
				fd.eye,
			)
		}
		draw_cube(
			vp,
			base,
			Vec3{0, ey - hs.y * 0.16, fz},
			Vec3{hs.x * 0.10, hs.y * 0.14, 0.05},
			fd.skin,
		) // nose
		draw_cube(
			vp,
			base,
			Vec3{0, fd.center.y - hs.y * 0.30, fz},
			Vec3{hs.x * 0.40, hs.y * 0.06, 0.03},
			MOUTH,
		)
		// Hair: a cap over the crown, a curtain down the back, and a short
		// fringe across the top of the forehead.
		t := hs.y * 0.18
		draw_cube(
			vp,
			base,
			Vec3{0, fd.center.y + hs.y * 0.5 - t * 0.4, 0},
			Vec3{hs.x * 1.06, t, hs.z * 1.06},
			fd.hair,
		)
		draw_cube(
			vp,
			base,
			Vec3{0, fd.center.y + hs.y * 0.08, fd.center.z + hs.z * 0.5 + 0.01},
			Vec3{hs.x * 1.06, hs.y * 0.72, 0.05},
			fd.hair,
		)
		draw_cube(
			vp,
			base,
			Vec3{0, fd.center.y + hs.y * 0.34, fz},
			Vec3{hs.x * 1.02, hs.y * 0.14, 0.04},
			fd.hair,
		)
	} else { 	// Animal: just eyes
		for s in signs {
			draw_cube(vp, base, Vec3{s * ex, ey, fz}, Vec3{hs.x * 0.17, hs.y * 0.17, 0.05}, EYE_WHITE)
			draw_cube(
				vp,
				base,
				Vec3{s * ex, ey, fz - 0.012},
				Vec3{hs.x * 0.10, hs.y * 0.11, 0.06},
				fd.eye,
			)
		}
	}
}

// Head geometry per mob, mirroring the head part in each *_parts array above.
// Not file-private: tests exercise it directly.
face_def_for_mob :: proc(k: MobKind) -> MobFace {
	switch k {
	case .Pig:
		return {{0, 0.55, -0.55}, {0.5, 0.5, 0.45}, .Animal, {}, {}, EYE_DARK}
	case .Sheep:
		return {{0, 0.88, -0.62}, {0.45, 0.5, 0.42}, .Animal, {}, {}, EYE_DARK}
	case .Cow:
		return {{0, 0.98, -0.72}, {0.5, 0.5, 0.45}, .Animal, {}, {}, EYE_DARK}
	case .Chicken:
		return {{0, 0.56, -0.22}, {0.3, 0.32, 0.3}, .Animal, {}, {}, EYE_DARK}
	case .Rabbit:
		return {{0, 0.30, -0.18}, {0.22, 0.22, 0.20}, .Animal, {}, {}, EYE_DARK}
	case .Horse:
		return {{0, 1.55, -0.92}, {0.26, 0.26, 0.34}, .Animal, {}, {}, EYE_DARK}
	case .Zombie:
		return {{0, 1.68, 0}, {0.42, 0.42, 0.42}, .Humanoid, ZSKIN, {0.14, 0.12, 0.10}, EYE_DARK}
	case .Skeleton:
		return {{0, 1.66, 0}, {0.4, 0.4, 0.4}, .Animal, {}, {}, EYE_DARK} // dark skull sockets
	case .Piglin:
		return {{0, 1.68, 0}, {0.52, 0.44, 0.44}, .Animal, {}, {}, EYE_DARK}
	case .Ghast:
		return {{0, 0.95, 0}, {1.3, 1.3, 1.3}, .Animal, {}, {}, GHASTFACE}
	case .Fish, .Squid, .Pufferfish, .Jellyfish:
		return {style = .None}
	case .Dolphin:
		return {{0, 0.26, -0.42}, {0.16, 0.15, 0.24}, .Animal, {}, {}, EYE_DARK}
	case .SnowLeopard:
		return {{0, 0.6, -0.62}, {0.34, 0.32, 0.34}, .Animal, {}, {}, EYE_DARK}
	case .Camel:
		return {{0, 1.78, -0.86}, {0.26, 0.28, 0.42}, .Animal, {}, {}, EYE_DARK}
	case .Llama:
		return {{0, 1.72, -0.44}, {0.26, 0.26, 0.34}, .Animal, {}, {}, EYE_DARK}
	case .Wolf:
		return {{0, 0.72, -0.5}, {0.32, 0.34, 0.34}, .Animal, {}, {}, EYE_DARK}
	case .Cat:
		return {{0, 0.42, -0.32}, {0.22, 0.22, 0.22}, .Animal, {}, {}, EYE_DARK}
	case .Fox:
		return {{0, 0.5, -0.42}, {0.24, 0.24, 0.26}, .Animal, {}, {}, EYE_DARK}
	case .Goat:
		return {{0, 0.9, -0.55}, {0.32, 0.34, 0.34}, .Animal, {}, {}, EYE_DARK}
	case .Deer:
		return {{0, 1.5, -0.7}, {0.22, 0.22, 0.3}, .Animal, {}, {}, EYE_DARK}
	case .Bee:
		return {{0, 0.42, -0.28}, {0.18, 0.18, 0.16}, .Animal, {}, {}, EYE_DARK}
	case .Turtle:
		return {{0, 0.26, -0.44}, {0.2, 0.18, 0.2}, .Animal, {}, {}, EYE_DARK}
	}
	return {style = .None}
}

// A few natural hair tones, picked per villager by name hash so heads vary.
@(private = "file")
HAIR_TONES := []Vec3 {
	{0.16, 0.11, 0.07}, // near black
	{0.34, 0.22, 0.10}, // brown
	{0.52, 0.30, 0.12}, // auburn
	{0.60, 0.54, 0.42}, // ash blond
	{0.46, 0.46, 0.46}, // grey
}

@(private = "file")
villager_face_def :: proc(v: ^Villager) -> MobFace {
	h := hash_string(v.name)
	hair := HAIR_TONES[(h >> 40) % u64(len(HAIR_TONES))]
	return {{0, 1.66, 0}, {0.4, 0.42, 0.4}, .Humanoid, VSKIN, hair, EYE_DARK}
}

@(private = "file")
player_face := MobFace{{0, 1.66, 0}, {0.42, 0.42, 0.42}, .Humanoid, PSKIN, {0.20, 0.14, 0.09}, EYE_DARK}

entity_render_init :: proc() {
	ok: bool
	if e_prog, ok = gl.load_shaders_source(ENTITY_VERT, ENTITY_FRAG); !ok {
		fmt.panicf("entity shader failed to compile/link")
	}
	e_mvp = gl.GetUniformLocation(e_prog, "uMVP")
	e_color = gl.GetUniformLocation(e_prog, "uColor")
	e_ambient = gl.GetUniformLocation(e_prog, "uAmbient")

	// Unit cube centred at the origin (-0.5..0.5), reusing the world face
	// tables for correct CCW winding and per-face shading.
	verts: [36]EntVert
	n := 0
	for face in Face {
		fd := FACES[face]
		sh := FACE_SHADE[face]
		quad: [4]EntVert
		for i in 0 ..< 4 {
			off := fd.pos[i]
			quad[i] = EntVert{Vec3{f32(off.x) - 0.5, f32(off.y) - 0.5, f32(off.z) - 0.5}, sh}
		}
		idx := [6]int{0, 1, 2, 0, 2, 3}
		for j in idx {
			verts[n] = quad[j]
			n += 1
		}
	}

	gl.GenVertexArrays(1, &e_vao)
	gl.GenBuffers(1, &e_vbo)
	gl.BindVertexArray(e_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, e_vbo)
	gl.BufferData(gl.ARRAY_BUFFER, 36 * size_of(EntVert), &verts[0], gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, i32(size_of(EntVert)), offset_of(EntVert, pos))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 1, gl.FLOAT, false, i32(size_of(EntVert)), offset_of(EntVert, shade))
	gl.BindVertexArray(0)
}

entity_render_frame :: proc(mobs: ^[dynamic]Mob, vp: Mat4, ambient: f32) {
	if len(mobs^) == 0 do return
	gl.UseProgram(e_prog)
	gl.Uniform1f(e_ambient, ambient)
	gl.BindVertexArray(e_vao)
	for i in 0 ..< len(mobs^) {
		m := &mobs^[i]
		// -yaw so the model's local -Z (its face) points along the heading.
		base := linalg.matrix4_translate_f32(m.pos) * linalg.matrix4_rotate_f32(-m.yaw, Vec3{0, 1, 0})
		if m.is_baby {
			base = base * linalg.matrix4_scale_f32(Vec3{0.55, 0.55, 0.55}) // shrink around the feet
		}
		sw := math.sin(m.walk_phase)
		// Land creatures stride from the hip; aquatic fins/tentacles just sway.
		pivot := !mob_is_aquatic(m.kind) && m.kind != .Ghast
		for pt in mob_parts(m.kind) {
			model := limb_model(base, pt, sw, pivot)
			ent_set_mat4(e_mvp, vp * model)
			gl.Uniform3f(e_color, pt.color.r, pt.color.g, pt.color.b)
			gl.DrawArrays(gl.TRIANGLES, 0, 36)
		}
		emit_face(vp, base, face_def_for_mob(m.kind))
	}
	gl.BindVertexArray(0)
}

@(private = "file")
held_box :: proc(proj, base: Mat4, off, size, col: Vec3) {
	m := base * linalg.matrix4_translate_f32(off) * linalg.matrix4_scale_f32(size)
	ent_set_mat4(e_mvp, proj * m)
	gl.Uniform3f(e_color, col.r, col.g, col.b)
	gl.DrawArrays(gl.TRIANGLES, 0, 36)
}

// First-person view model in the bottom-right: the block you're holding (a
// small cube) or, when mining or empty-handed, your pickaxe. It swings when you
// use it (driven by p.swing_timer). Rendered in camera-local space (proj with
// no view) over a freshly-cleared depth buffer so it always sits on top of the
// world and self-occludes correctly.
held_item_render :: proc(p: ^Player, proj: Mat4, ambient: f32) {
	sel := inv_selected(p)
	show_tool := p.tool_mode || p.mine_active || sel == .Air

	sw := f32(0)
	if p.swing_timer > 0 do sw = math.sin((1 - p.swing_timer / SWING_DURATION) * math.PI)

	gl.UseProgram(e_prog)
	gl.Uniform1f(e_ambient, clamp(ambient + 0.4, 0, 1))
	gl.BindVertexArray(e_vao)
	gl.Clear(gl.DEPTH_BUFFER_BIT)

	base :=
		linalg.matrix4_translate_f32(Vec3{0.52, -0.52 - sw * 0.14, -1.0}) *
		linalg.matrix4_rotate_f32(-0.35 + sw * 1.1, Vec3{1, 0, 0}) * // swing pitches it down
		linalg.matrix4_rotate_f32(0.5, Vec3{0, 1, 0})

	if show_tool {
		kind := p.held_tool
		tier := p.tool_tier[kind]
		metal: Vec3
		switch tier {
		case 1:
			metal = {0.52, 0.38, 0.22}
		case 2:
			metal = {0.55, 0.55, 0.58}
		case 3:
			metal = {0.82, 0.82, 0.86}
		case 4:
			metal = {0.45, 0.86, 0.86}
		case:
			metal = {0.72, 0.58, 0.46}
		}
		handle := Vec3{0.42, 0.28, 0.16}
		switch kind {
		case .Sword:
			held_box(proj, base, Vec3{0, -0.12, 0}, Vec3{0.06, 0.3, 0.06}, handle) // grip
			held_box(proj, base, Vec3{0, 0.05, 0}, Vec3{0.24, 0.06, 0.06}, metal) // crossguard
			held_box(proj, base, Vec3{0, 0.42, 0}, Vec3{0.05, 0.62, 0.05}, metal) // long blade
		case .Shovel:
			held_box(proj, base, Vec3{0, -0.05, 0}, Vec3{0.07, 0.5, 0.07}, handle)
			held_box(proj, base, Vec3{0, 0.26, 0}, Vec3{0.16, 0.16, 0.06}, metal) // flat blade
		case .Axe:
			held_box(proj, base, Vec3{0, -0.05, 0}, Vec3{0.07, 0.5, 0.07}, handle)
			held_box(proj, base, Vec3{0.12, 0.22, 0}, Vec3{0.16, 0.2, 0.08}, metal) // side head
		case .Pickaxe:
			held_box(proj, base, Vec3{0, -0.05, 0}, Vec3{0.07, 0.5, 0.07}, handle)
			held_box(proj, base, Vec3{0, 0.24, 0}, Vec3{0.3, 0.1, 0.09}, metal) // wide head
		}
	} else {
		held_box(proj, base, Vec3{0, 0, 0}, Vec3{0.34, 0.34, 0.34}, block_color(sel))
	}
	gl.BindVertexArray(0)
}

// Rotation whose local +Z points along `fwd`.
@(private = "file")
mat_from_forward :: proc(fwd: Vec3) -> Mat4 {
	f := linalg.normalize(fwd)
	up0 := math.abs(f.y) > 0.99 ? Vec3{1, 0, 0} : Vec3{0, 1, 0}
	r := linalg.normalize(linalg.cross(up0, f))
	u := linalg.cross(f, r)
	m := linalg.MATRIX4F32_IDENTITY
	m[0, 0] = r.x;m[1, 0] = r.y;m[2, 0] = r.z
	m[0, 1] = u.x;m[1, 1] = u.y;m[2, 1] = u.z
	m[0, 2] = f.x;m[1, 2] = f.y;m[2, 2] = f.z
	return m
}

arrows_render_frame :: proc(arrows: ^[dynamic]Arrow, vp: Mat4, ambient: f32) {
	if len(arrows^) == 0 do return
	gl.UseProgram(e_prog)
	gl.Uniform1f(e_ambient, ambient)
	gl.BindVertexArray(e_vao)
	for i in 0 ..< len(arrows^) {
		a := &arrows^[i]
		fwd := a.vel
		if linalg.length(fwd) < 0.001 do fwd = Vec3{0, 0, 1}
		scale := a.fire ? Vec3{0.4, 0.4, 0.4} : Vec3{0.06, 0.06, 0.45}
		model :=
			linalg.matrix4_translate_f32(a.pos) *
			mat_from_forward(fwd) *
			linalg.matrix4_scale_f32(scale)
		ent_set_mat4(e_mvp, vp * model)
		if a.fire {
			gl.Uniform3f(e_color, 0.98, 0.5, 0.12) // molten fireball
		} else {
			gl.Uniform3f(e_color, 0.82, 0.78, 0.70)
		}
		gl.DrawArrays(gl.TRIANGLES, 0, 36)
	}
	gl.BindVertexArray(0)
}

// Break-particle shards as tiny coloured cubes.
particles_render_frame :: proc(ps: ^[dynamic]Particle, vp: Mat4, ambient: f32) {
	if len(ps^) == 0 do return
	gl.UseProgram(e_prog)
	gl.Uniform1f(e_ambient, ambient)
	gl.BindVertexArray(e_vao)
	for i in 0 ..< len(ps^) {
		pt := &ps^[i]
		model :=
			linalg.matrix4_translate_f32(pt.pos) *
			linalg.matrix4_scale_f32(Vec3{pt.size, pt.size, pt.size})
		ent_set_mat4(e_mvp, vp * model)
		gl.Uniform3f(e_color, pt.color.r, pt.color.g, pt.color.b)
		gl.DrawArrays(gl.TRIANGLES, 0, 36)
	}
	gl.BindVertexArray(0)
}

// Dropped items as small bobbing, spinning cubes coloured by their block.
items_render_frame :: proc(items: ^[dynamic]Item, vp: Mat4, ambient: f32) {
	if len(items^) == 0 do return
	gl.UseProgram(e_prog)
	gl.Uniform1f(e_ambient, ambient)
	gl.BindVertexArray(e_vao)
	for i in 0 ..< len(items^) {
		it := &items^[i]
		bob := 0.25 + math.sin(it.age * 3) * 0.07
		model :=
			linalg.matrix4_translate_f32(it.pos + Vec3{0, bob, 0}) *
			linalg.matrix4_rotate_f32(it.spin, Vec3{0, 1, 0}) *
			linalg.matrix4_scale_f32(Vec3{0.3, 0.3, 0.3})
		ent_set_mat4(e_mvp, vp * model)
		col := it.food ? Vec3{0.72, 0.28, 0.22} : block_color(it.block)
		gl.Uniform3f(e_color, col.r, col.g, col.b)
		gl.DrawArrays(gl.TRIANGLES, 0, 36)
	}
	gl.BindVertexArray(0)
}
