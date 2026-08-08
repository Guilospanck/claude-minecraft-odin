package main

import "core:math"

Biome :: enum {
	Ocean,
	Beach,
	Plains,
	Forest,
	Desert,
	Badlands,
	Snow,
	Mountains,
	Savanna,
	Swamp,
	Taiga,
	Jungle, // hot + very wet: tall canopy, ferns, vines
	Meadow, // cool + dry highland: flower-carpeted grass, few trees
}

@(private = "file")
wg_smoothstep :: proc(e0, e1, x: f32) -> f32 {
	t := clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
}

// fbm noise is bell-shaped: its output clusters tightly around 0, so a raw
// temperature/humidity field spends almost all its time in the temperate
// middle and only rarely reaches the cold/hot extremes. That is exactly why
// the old map read as "more of the same" — snow and desert live in the tails
// the noise almost never visits. This pushes values outward toward ±1 (a
// signed power < 1 widens the tails while keeping 0 at 0 and the sign intact),
// turning the narrow bell into a spread that actually reaches every biome band
// at drive-through scale. Not file-private: tests exercise it directly.
climate_spread :: proc(x: f32) -> f32 {
	// fbm clusters near 0, so raw temperature/humidity rarely reaches the extremes
	// that snow and desert need. We still nudge the field outward, but only gently:
	// the OLD curve multiplied by ~2 and clamped, which flattened everything past
	// |x|≈0.5 into a plateau of pure desert/snow with a razor-thin transition band —
	// that is what made biomes "snap" from lush to sand. A mild expansion with no
	// early clamp keeps the whole field a smooth gradient, so a climate value drifts
	// slowly across the biome thresholds and neighbours grade into each other over a
	// long walk rather than flipping at a plateau edge.
	s: f32 = x < 0 ? -1 : 1
	return clamp(s * math.pow(abs(x), 0.78) * 1.18, -1, 1)
}

// Temperature + humidity for a column, as one shared function so the terrain
// generator and the grass tinter (mesher.odin) can never drift apart on what
// climate a column has. Domain-warped so the bands aren't axis-aligned blobs,
// then spread toward the extremes (see climate_spread).
world_climate :: proc(seed: u64, wx, wz: int) -> (temp: f32, moist: f32) {
	fx := f32(wx)
	fz := f32(wz)
	// Two-scale domain warp: a broad low-frequency meander (big, smooth bends in
	// the biome borders) plus a stronger high-frequency jitter (block-scale
	// raggedness). Without the high-frequency term the climate field is so smooth
	// that biome borders come out as clean, near-straight bands; the jitter breaks
	// them into the irregular, interlocking edges a real world has.
	warp_x :=
		fbm2(seed + 9001, fx * 0.005, fz * 0.005, 2) * 44.0 +
		fbm2(seed + 9003, fx * 0.020, fz * 0.020, 2) * 14.0
	warp_z :=
		fbm2(seed + 9002, fx * 0.005, fz * 0.005, 2) * 44.0 +
		fbm2(seed + 9004, fx * 0.020, fz * 0.020, 2) * 14.0
	// VERY low frequencies so a single biome region spans hundreds of blocks and
	// the climate drifts only slowly across it — you walk a long way through forest
	// before it grades through plains and savanna into desert, instead of "lush,
	// boom sand, boom badlands" in a few dozen blocks. Two octaves only (not three)
	// keeps the large-scale gradient smooth rather than breaking it into small
	// sub-regions. Humidity is lower-frequency still, so big arid and big humid
	// zones each span several temperature bands.
	t := fbm2(seed + 101, (fx + warp_x) * 0.00085, (fz + warp_z) * 0.00085, 2)
	m := fbm2(seed + 202, (fx + warp_x) * 0.00060, (fz + warp_z) * 0.00060, 2)
	return climate_spread(t), climate_spread(m)
}

// Picks a biome from the full noise field for a column. Continentalness
// separates ocean/beach from land (via the built height), erosion + peaks &
// valleys pick out mountains, and the rest is a temperature x humidity grid.
// The grid is laid out so temperature moves monotonically cold -> hot: the
// frigid biomes (Snow/Taiga) and the torrid ones (Desert/Savanna/Jungle) sit
// at opposite ends with the whole temperate band (Meadow/Plains/Forest/Swamp)
// between them, so a cold biome can never border a hot one — you always pass
// through the temperate middle, which is what makes transitions read as
// gradual instead of snow slammed against desert.
@(private = "file")
classify_biome :: proc(continentalness, erosion_amp, pv, temp, moist: f32, h: int) -> Biome {
	// Ocean/Beach come from the actual generated height, not a separate
	// continentalness check — h already reflects continentalness (via the
	// spline) plus every other contribution (peaks & valleys, detail,
	// rivers), so re-deriving "is this ocean" from continentalness alone
	// could disagree with what was actually built.
	if h <= SEA_LEVEL - 2 do return .Ocean
	if h <= SEA_LEVEL + 1 do return .Beach
	if (pv > 0.55 && erosion_amp > 0.55) || h > SEA_LEVEL + 30 do return .Mountains

	// Altitude cools the air: the higher a column sits above the coastal
	// lowlands, the colder its effective temperature. This makes climate bands
	// STACK with elevation — a temperate valley grades up through taiga into
	// snowy highland instead of the biome flipping abruptly at a noise edge —
	// and keeps snow off warm lowlands (near oceans/lagoons, which stay mild)
	// unless the underlying climate is genuinely frigid. The adjustment is a
	// smooth function of height, so neighbouring columns stay within a hair of
	// each other and the temp-monotonic ordering (cold never borders hot) holds.
	alt := max(0, h - (SEA_LEVEL + 8))
	t := temp - f32(alt) * 0.010 // altitude-cooled effective temperature

	// Proximity to water moderates climate: low-lying columns near the sea are
	// pulled toward mild temperate (a maritime effect), so a coastline or lagoon
	// grades gently into forest/plains instead of snapping straight to snow or
	// desert at the water's edge. Fades out as the land rises inland.
	maritime := clamp((f32(SEA_LEVEL + 8) - f32(h)) / 8.0, 0, 1) // 1 right at the shore .. 0 a few blocks inland
	t *= 1 - 0.22 * maritime

	// Low, very wet, and not cold: swamp (checked before the temp bands so it
	// can claim wet lowlands out of what would otherwise be forest).
	if t > -0.3 && t < 0.35 && moist > 0.5 && h < SEA_LEVEL + 6 do return .Swamp

	if t < -0.35 { 	// frigid: only the coldest columns, split dry/wet
		return moist < 0.05 ? .Snow : .Taiga
	}
	if t > 0.4 { 	// torrid
		// Desert/Badlands share the hot+dry corner and split on ruggedness —
		// a flatter (low-amplitude) area mesas into Badlands, rougher stays
		// open Desert dunes.
		if moist < -0.25 do return erosion_amp < 0.35 ? .Badlands : .Desert
		if moist < 0.15 do return .Savanna
		return .Jungle
	}
	if t < -0.1 { 	// cool temperate: flowery meadow when dry, else forest
		return moist < -0.1 ? .Meadow : .Forest
	}
	// warm temperate
	if moist < -0.25 do return .Savanna
	if moist < 0.3 do return .Plains
	return .Forest
}

// A 2D-noise patch test: true where the low-frequency surface noise (offset by
// `salt` to decorrelate patch types) rises above `thresh`. Drives blobby,
// natural ground-cover patches instead of uniform biome fills.
@(private = "file")
surface_patch :: proc(seed: u64, salt: u64, wx, wz: int, thresh: f32) -> bool {
	return value_noise2(seed + salt, f32(wx) * 0.085, f32(wz) * 0.085) > thresh
}

// Horizontal terracotta strata for badlands mesas: repeating coloured bands by
// altitude, the boundaries jittered per-column so they wobble like real mesa
// walls instead of being dead-flat. Red sand fills the low ground.
@(private = "file")
badlands_stratum :: proc(seed: u64, wx, wz, y: int) -> BlockId {
	jit := int(fbm2(seed + 606, f32(wx) * 0.06, f32(wz) * 0.06, 2) * 3.0)
	switch (y + jit) %% 9 {
	case 0:
		return .TerracottaWhite
	case 1, 2:
		return .Terracotta
	case 3:
		return .TerracottaBrown
	case 4, 5:
		return .Terracotta
	case 6:
		return .TerracottaWhite
	}
	return .RedSand
}

// Top-of-column block for a biome, with biome-specific ground-cover patches:
// podzol/coarse-dirt in taiga, mud in swamps, coarse dirt in savanna, gravel on
// cold shores and rocky mountains. Not file-private: tests exercise it.
surface_block :: proc(seed: u64, biome: Biome, wx, wz, h: int) -> BlockId {
	if h <= SEA_LEVEL + 1 { 	// beach / seabed — varies with the local climate
		temp, _ := world_climate(seed, wx, wz)
		if temp < -0.3 { 	// snowy / frozen beach
			return surface_patch(seed, 4001, wx, wz, 0.72) ? .Gravel : .Snow
		}
		if (biome == .Taiga || biome == .Mountains) && surface_patch(seed, 4008, wx, wz, 0.5) {
			return .Gravel // stony shore below cold, rugged land
		}
		return .Sand
	}
	switch biome {
	case .Ocean, .Beach, .Desert:
		return .Sand
	case .Badlands:
		// wooded-badlands variant: grassy coarse-dirt cap on the high plateaus
		if biome_variant(seed, wx, wz) > 0.4 && h > SEA_LEVEL + 9 {
			return surface_patch(seed, 4007, wx, wz, 0.5) ? .CoarseDirt : .Grass
		}
		return .RedSand // exposed column is stratified in the fill loop
	case .Snow:
		return .Snow
	case .Mountains:
		if h > SEA_LEVEL + 34 do return .Snow
		return surface_patch(seed, 4002, wx, wz, 0.68) ? .Gravel : .Stone
	case .Taiga:
		// cold conifer floor: podzol blobs and the odd coarse-dirt scrape
		if surface_patch(seed, 4003, wx, wz, 0.52) do return .Podzol
		if surface_patch(seed, 4004, wx, wz, 0.72) do return .CoarseDirt
		return .Grass
	case .Swamp:
		if surface_patch(seed, 4005, wx, wz, 0.5) do return .Mud
		return .Grass
	case .Savanna:
		if surface_patch(seed, 4006, wx, wz, 0.7) do return .CoarseDirt
		return .Grass
	case .Plains, .Forest, .Jungle, .Meadow:
		return .Grass
	}
	return .Grass
}

@(private = "file")
subsurface_block :: proc(biome: Biome) -> BlockId {
	#partial switch biome {
	case .Ocean, .Beach, .Desert:
		return .Sand
	case .Badlands:
		return .RedSand
	case .Mountains:
		return .Stone
	}
	return .Dirt
}

// Continentalness -> base terrain height offset from SEA_LEVEL. Deep ocean
// far out, a smooth shelf up through the coastline, then rolling inland
// height — the spline shape is what gives natural-looking coasts instead of
// a single linear ramp.
// fbm noise concentrates near 0 (bell-curve, not uniform), so continentalness
// == 0 is the COMMON case, not a midpoint that rarely occurs. The peaks &
// valleys contribution (below) also nets negative most of the time even
// after shaping. So the 0-point here needs enough headroom above sea level
// to absorb that typical downward pull and still land on dry ground — this
// is tuned against a large scanned sample (see MC_SCAN), not just the shape
// in isolation.
@(private = "file")
CONTINENTAL_SPLINE := []SplinePoint {
	{-1.0, -32},
	{-0.6, -14},
	{-0.35, -4},
	{-0.15, 3},
	{0.0, 12},
	{0.25, 18},
	{0.5, 24},
	{1.0, 34},
}

// Erosion -> amplitude multiplier: high erosion means the land has been worn
// down flat, low erosion means peaks & valleys and small-scale detail get to
// express themselves at full strength.
@(private = "file")
EROSION_SPLINE := []SplinePoint{{-1.0, 1.0}, {-0.3, 0.7}, {0.2, 0.35}, {1.0, 0.15}}

// Raw peaks-and-valleys fold (see below) is negative far more often than
// positive: fbm-summed noise concentrates near 0, and the fold formula maps
// exactly "weirdness near 0" to its most negative output (-1, deep valley).
// Left unshaped, that systematically drags most of the map underwater. This
// spline compresses the (common) valley side and lets the (rare) peak side
// through at full strength, instead of a raw linear multiply.
@(private = "file")
PV_SPLINE := []SplinePoint{{-1.0, -0.3}, {-0.3, -0.15}, {0.0, 0.0}, {0.3, 0.3}, {0.6, 0.9}, {1.0, 1.0}}

// A biome-correlated height delta (blocks) added on top of the base terrain, so
// biomes read in their SILHOUETTE, not just colour: warm-dry country ripples
// into dunes, hot-dry-flat country rises into flat-topped badlands mesas, cool
// humid country rolls into gentle hills, rugged peaks-and-valleys country turns
// jagged, and wet lowland flattens/sinks toward a marsh level. All factors are
// continuous functions of the climate/terrain noise, so the delta varies
// smoothly and never cliffs at a biome edge.
@(private = "file")
biome_shape :: proc(seed: u64, fx, fz, temp, moist, erosion_amp, pv: f32, h: int) -> f32 {
	dry := clamp(-moist, 0, 1)
	wet := clamp(moist, 0, 1)
	hot := clamp(temp, 0, 1)
	cool := clamp(1 - abs(temp) * 2, 0, 1) // peaks at temperate (temp≈0)
	flat := clamp((0.5 - erosion_amp) * 2.5, 0, 1) // 1 where erosion left the land flat
	delta := f32(0)

	// desert / savanna dunes: low ripples in warm dry country
	arid := dry * (0.35 + 0.65 * hot)
	if arid > 0.02 {
		dune := fbm2(seed + 717, fx * 0.05, fz * 0.05, 2)
		delta += dune * 3.5 * arid
	}
	// badlands mesas: raised, flat-topped plateaus in hot + dry + flat country
	mesa_f := hot * clamp((dry - 0.2) * 1.4, 0, 1) * flat
	if mesa_f > 0.02 {
		m := clamp(fbm2(seed + 818, fx * 0.022, fz * 0.022, 2), 0, 1)
		delta += m * m * 15.0 * mesa_f // squared -> flatter tops, steeper sides
	}
	// rolling hills in cool, humid temperate country (meadow/forest)
	hilly := cool * clamp(moist + 0.6, 0, 1)
	if hilly > 0.02 {
		hills := fbm2(seed + 919, fx * 0.016, fz * 0.016, 2)
		delta += hills * 4.0 * hilly
	}
	// jaggedness where peaks-and-valleys AND erosion are both high (mountains)
	mtn := clamp((pv - 0.35) * 1.6, 0, 1) * clamp((erosion_amp - 0.45) * 2.2, 0, 1)
	if mtn > 0.02 {
		jag := fbm2(seed + 1020, fx * 0.065, fz * 0.065, 3)
		delta += jag * 8.0 * mtn
	}
	// swamp: pull wet, mid-temperature lowland down toward a flat marsh level
	swampy := wet * clamp(1 - abs(temp) * 3, 0, 1) * clamp(f32(SEA_LEVEL + 8 - h) / 8.0, 0, 1)
	if swampy > 0.02 {
		cur := f32(h - SEA_LEVEL)
		delta += (1.0 - cur) * swampy * 0.6 // toward SEA_LEVEL+1
	}
	return delta
}

// The full noise -> height -> biome pipeline for one world column. Factored
// out of worldgen_fill so entity.odin's spawn logic can ask "what biome is
// this column" without recomputing (and risking drifting out of sync with)
// the five-noise formula that actually generated the terrain there.
world_height_and_biome :: proc(seed: u64, wx, wz: int) -> (h: int, biome: Biome, river_carve: f32) {
	fx := f32(wx)
	fz := f32(wz)

	// The five independent noise axes behind Minecraft's 1.18+ world
	// generator (see Henrik Kniberg's "Reinventing Minecraft World
	// Generation"): continentalness (ocean <-> inland), erosion
	// (rugged <-> flat), peaks & valleys (folded from a raw
	// "weirdness" field into sharp ridges/valleys), temperature and
	// humidity (biome only). They modulate each other below instead
	// of just summing, so e.g. mountains can't spike inside terrain
	// erosion has flattened.
	continentalness := fbm2(seed + 7, fx * 0.0011, fz * 0.0011, 4)
	erosion := fbm2(seed + 13, fx * 0.0028, fz * 0.0028, 3)
	weirdness := fbm2(seed + 31, fx * 0.005, fz * 0.005, 3)
	pv := 1.0 - abs(3.0 * abs(weirdness) - 2.0) // fold into ridges/valleys
	pv = clamp(pv, -1.0, 1.0)

	// Temperature/humidity come from the shared climate function (warped +
	// spread toward the extremes) so biome choice here and grass tint in the
	// mesher stay in lockstep.
	temp, moist := world_climate(seed, wx, wz)

	base_h := spline_eval(CONTINENTAL_SPLINE, continentalness)
	erosion_amp := spline_eval(EROSION_SPLINE, erosion)
	pv_h := spline_eval(PV_SPLINE, pv) * erosion_amp * 40.0
	detail := fbm2(seed, fx * 0.02, fz * 0.02, 4) * erosion_amp * 6.0

	fh := base_h + pv_h + detail // height above sea level, before biome shaping
	h_base := SEA_LEVEL + int(fh)

	// Classify from the PRE-shape height so raising a mesa or lowering a marsh
	// doesn't flip the biome (a tall badlands mesa stays badlands, not mountain).
	biome = classify_biome(continentalness, erosion_amp, pv, temp, moist, h_base)

	// Biome-correlated surface shaping, driven by the same continuous climate
	// fields the biome is (dryness/heat/erosion/pv), so shapes blend smoothly
	// across borders instead of cliffing. Land only.
	if h_base > SEA_LEVEL {
		fh += biome_shape(seed, fx, fz, temp, moist, erosion_amp, pv, h_base)
	}
	h = SEA_LEVEL + int(fh)
	if h < SEA_LEVEL + 1 && h_base > SEA_LEVEL + 1 do h = SEA_LEVEL + 1 // keep shaped land above water

	// Rivers: winding channels along a low-frequency zero-crossing, only in
	// lowlands (so they don't gouge canyons through mountains). Both factors
	// that make up the carve are smoothstepped rather than hard-gated: a
	// sharp `ra < 0.05` cutoff meant the *carved* height sat right next to
	// the *untouched* natural height the instant either factor crossed its
	// threshold, which on a hillside could be a 15-20+ block jump between
	// neighbouring columns — a vertical canyon wall, not a riverbank. With
	// both ramps continuous, neighbouring columns can only differ by a
	// bounded amount, so banks always slope instead of stepping off a cliff.
	river := fbm2(seed + 99, fx * 0.0035, fz * 0.0035, 2)
	ra := abs(river)
	river_band := wg_smoothstep(0.14, 0.0, ra) // 0 well outside the channel .. 1 at its centre
	lowland := wg_smoothstep(f32(SEA_LEVEL) + 30.0, f32(SEA_LEVEL) + 10.0, f32(h)) // 0 in the mountains .. 1 in true lowlands
	carve := river_band * lowland
	river_carve = carve // returned as-is; used unboosted by the ravine-suppression gate below
	if carve > 0 {
		target := SEA_LEVEL - 3
		if h > target {
			// Boosted (not the raw carve) for the height blend specifically:
			// a separate "give the river extra water above its own carved
			// floor" system was tried here twice and both times reinvented
			// the vertical-wall bug in a new place, because it let two
			// different fields (height vs. water level) disagree about
			// where the channel's edge was. Driving both from the *same*
			// single height value is the only way they can't disagree —
			// so instead, the carve is boosted before it blends h toward
			// target, so a moderately (not just maximally) carved column
			// still dips below SEA_LEVEL and gets water from the one plain
			// "y <= SEA_LEVEL" rule everywhere else already uses.
			height_carve := clamp(carve * 1.8, 0.0, 1.0)
			h = int(f32(h) * (1 - height_carve) + f32(target) * height_carve)
		}
	}

	if h < 4 do h = 4
	if h > CHUNK_H - 8 do h = CHUNK_H - 8
	return // biome was classified from the pre-shape height above
}

// A ravine never carves deeper than this below the surface — see the
// comment at its use site in worldgen_fill for why an unbounded depth was a
// bug, not a feature.
RAVINE_MAX_DEPTH :: 22
OVERWORLD_LAVA_LEVEL :: 9 // carved-out space at/below this y floods with lava

worldgen_fill :: proc(w: ^World, c: ^Chunk, seed: u64) {
	base_x := c.coord.x * CHUNK_W
	base_z := c.coord.y * CHUNK_D

	heights: [CHUNK_W * CHUNK_D]int
	biomes: [CHUNK_W * CHUNK_D]Biome

	for lz in 0 ..< CHUNK_D {
		for lx in 0 ..< CHUNK_W {
			wx := base_x + lx
			wz := base_z + lz
			fx := f32(wx)
			fz := f32(wz)

			h, biome, river_carve := world_height_and_biome(seed, wx, wz)

			heights[lx + lz * CHUNK_W] = h
			biomes[lx + lz * CHUNK_W] = biome

			// ravines (winding surface gorges) + rare cave-mouth spots
			ravine := fbm2(seed + 404, fx * 0.0032, fz * 0.0032, 2)
			rav_a := abs(ravine)
			cave_mouth := value_noise2(seed + 888, fx * 0.05, fz * 0.05) > 0.80

			surf := surface_block(seed, biome, wx, wz, h)
			sub := subsurface_block(biome)
			// badlands columns are stratified terracotta down to ~16 blocks,
			// so cliff faces show horizontal mesa bands, not a plain surface.
			mesa := biome == .Badlands && h > SEA_LEVEL + 2
			ctemp, _ := world_climate(seed, wx, wz)
			frozen := ctemp < -0.42 // frigid: cap open water with a skin of ice

			for y in 0 ..< CHUNK_H {
				b: BlockId = .Air
				if y == 0 {
					b = .Bedrock
				} else if y < h {
					if y == h - 1 {
						b = surf // top block (surface rule; grass on wooded badlands)
					} else if mesa && y >= h - 16 {
						b = badlands_stratum(seed, wx, wz, y)
					} else if y >= h - 4 {
						b = sub
					} else {
						b = .Stone
					}
				} else if y == SEA_LEVEL && frozen {
					b = .Ice // frozen surface of a cold lake / river / sea
				} else if y <= SEA_LEVEL {
					b = .Water
				}

				// Caves, ravines, and rare surface cave mouths.
				if b != .Air && b != .Bedrock && b != .Water && y > 1 && y < h {
					deep := y < h - 5
					// Ravines are a bounded gorge below the surface, not a
					// shaft to bedrock: uncapped, `y > 8` let a ravine carve
					// every block from y=9 up to h-1, so wherever a river
					// had already pulled h down near sea level, the two
					// combined into a deep rectangular pit plunging out of
					// the riverbed — the ravine noise has nothing to do
					// with the river noise, so this is pure coincidence
					// waiting to happen anywhere the two overlap. Capping
					// the depth and skipping ravines where the river has
					// meaningfully carved (river_carve >= 0.2) stops both:
					// a bounded gorge on dry land, no gorge at all in a
					// riverbed the water carve already shaped.
					ravine_floor := max(9, h - RAVINE_MAX_DEPTH)
					if rav_a < 0.016 && y > ravine_floor && river_carve < 0.2 {
						// Open to the surface (unlike the sealed caverns
						// below), so a ravine that dips below sea level near
						// a coastline floods instead of leaving a dry pit
						// right next to open water — the same "y <=
						// SEA_LEVEL" rule everywhere else already uses,
						// rather than a special-cased water table that could
						// disagree with it again.
						b = y <= SEA_LEVEL ? .Water : .Air
					} else if deep || cave_mouth {
						cave := fbm3(seed + 555, fx * 0.045, f32(y) * 0.055, fz * 0.045, 3)
						if cave > 0.72 {
							b = .Air
						} else if deep && y < 34 {
							cav := fbm3(seed + 321, fx * 0.02, f32(y) * 0.03, fz * 0.02, 2)
							if cav > 0.6 {
								b = .Air // deep cavern / overhang
							}
						}
					}
				}

				// Deep carved-out pockets flood with lava, so the bottom of the
				// cave system glows and is dangerous — the lava that pools near
				// bedrock in Minecraft. Placed after carving (so it fills the
				// air the caves/ravines just opened) but before ore.
				if b == .Air && y > 0 && y <= OVERWORLD_LAVA_LEVEL do b = .Lava

				// Ore in connected veins (shows in cave/ravine walls since
				// it's placed after carving), one shared noise field
				// bucketed into depth tiers instead of a single generic
				// type: coal is common and shallow, iron mid-depth
				// (unchanged from before), gold deeper and rarer, diamond
				// deepest and rarest. Checked deepest-tier-first so a block
				// that just misses the diamond threshold still gets a
				// chance at gold/iron/coal instead of nothing.
				if b == .Stone {
					ov := fbm3(seed + 777, fx * 0.08, f32(y) * 0.08, fz * 0.08, 2)
					if y < 16 && ov > 0.85 {
						b = .DiamondOre
					} else if y < 24 && ov > 0.80 {
						b = .GoldOre
					} else if y < 42 && ov > 0.74 {
						b = .Ore
					} else if y < 90 && ov > 0.68 {
						b = .CoalOre
					}
				}

				c.blocks[chunk_index(lx, y, lz)] = b
			}
		}
	}

	settle_water(c)
	generate_waterfalls(c, seed, base_x, base_z, heights[:])
	generate_trees(c, seed, base_x, base_z, heights[:], biomes[:])
	// Runs last so a house's walls/roof/door always win over whatever a
	// tree placed on the same columns, instead of depending on call order
	// luck for a clean building.
	generate_village(w, c, seed, base_x, base_z, heights[:], biomes[:])
	generate_structures(w, c, seed, base_x, base_z, heights[:], biomes[:])
	generate_dungeon(w, c, seed, base_x, base_z, heights[:])
}

// Make unsupported water fall. Rivers/oceans that were carved through by a
// ravine or cave used to leave a flat sheet of water hanging in the air over
// the gap (a "water bridge across the canyon"). Here any water with air
// directly below flows down to the first solid block, so it cascades into and
// fills the drop instead of floating.
settle_water :: proc(c: ^Chunk) {
	for lz in 0 ..< CHUNK_D {
		for lx in 0 ..< CHUNK_W {
			for y := CHUNK_H - 1; y >= 1; y -= 1 {
				if c.blocks[chunk_index(lx, y, lz)] == .Water &&
				   c.blocks[chunk_index(lx, y - 1, lz)] == .Air {
					c.blocks[chunk_index(lx, y - 1, lz)] = .Water
				}
			}
		}
	}
}

// Water strands down cliff faces: at the foot of a tall in-chunk cliff, fill
// the air column with water so it reads as a waterfall. Rare + interior-only.
//
// Must be an ISOLATED cliff-base point, not part of a long run: checking
// only "is my tallest neighbor 8+ higher" made every column along a whole
// cliff base qualify together (they mostly share the same tall neighbor),
// and a coarse ~12-block-period noise gate didn't break that up, so a whole
// straight wall of columns all got flood-filled to the same height — a flat
// sheet of water pasted across the cliff instead of a waterfall. Requiring
// exactly one of the four neighbors to be tall (a corner/point on the base,
// not a uniform wall) plus a much finer per-column noise gate makes falls
// sparse and narrow instead.
@(private = "file")
generate_waterfalls :: proc(c: ^Chunk, seed: u64, base_x, base_z: int, heights: []int) {
	for lz in 1 ..< CHUNK_D - 1 {
		for lx in 1 ..< CHUNK_W - 1 {
			h := heights[lx + lz * CHUNK_W]
			if h <= SEA_LEVEL + 1 do continue
			neighbor_h := [4]int {
				heights[(lx - 1) + lz * CHUNK_W],
				heights[(lx + 1) + lz * CHUNK_W],
				heights[lx + (lz - 1) * CHUNK_W],
				heights[lx + (lz + 1) * CHUNK_W],
			}
			tall_count := 0
			nh := h
			for v in neighbor_h {
				if v >= h + 8 {
					tall_count += 1
					nh = max(nh, v)
				}
			}
			if tall_count != 1 do continue // an isolated point, not a whole cliff wall
			wx := base_x + lx
			wz := base_z + lz
			if value_noise2(seed + 999, f32(wx) * 0.35, f32(wz) * 0.35) <= 0.55 do continue

			top := min(nh - 1, h + 6) // a short trickle, not a towering sheet
			for y in h ..= top {
				if chunk_get(c, lx, y, lz) == .Air {
					chunk_set(c, lx, y, lz, .Water)
				}
			}
		}
	}
}

// The Nether: netherrack landscape riddled with caves over a lava sea, with
// bedrock floor and ceiling. Dark and hostile.
worldgen_nether :: proc(c: ^Chunk, seed: u64) {
	base_x := c.coord.x * CHUNK_W
	base_z := c.coord.y * CHUNK_D
	LAVA_LEVEL :: 30
	for lz in 0 ..< CHUNK_D {
		for lx in 0 ..< CHUNK_W {
			fx := f32(base_x + lx)
			fz := f32(base_z + lz)
			h := 46 + int(fbm2(seed + 50, fx * 0.02, fz * 0.02, 3) * 16.0) // netherrack top
			for y in 0 ..< CHUNK_H {
				b: BlockId = .Air
				if y == 0 || y >= CHUNK_H - 4 {
					b = .Bedrock
				} else if y < h {
					b = .Netherrack
					cave := fbm3(seed + 60, fx * 0.05, f32(y) * 0.05, fz * 0.05, 3)
					if cave > 0.52 && y > 1 do b = .Air // cavey nether
				}
				if b == .Air && y > 0 && y <= LAVA_LEVEL do b = .Lava // lava sea
				// glowstone specks clinging to the ceiling
				if b == .Netherrack && y > h - 2 {
					if value_noise3(seed + 70, fx * 0.15, f32(y) * 0.15, fz * 0.15) > 0.86 {
						b = .Glowstone
					}
				}
				c.blocks[chunk_index(lx, y, lz)] = b
			}
		}
	}
}

TreeKind :: enum {
	Oak,
	Spruce,
	Birch,
	Acacia, // flat, wide savanna umbrella
	Pine, // tall narrow conifer spire
	BigOak, // thick trunk, broad two-tier canopy
	Palm, // tall bare trunk with a spray of drooping fronds (beaches)
	Willow, // rounded crown with leaf strands hanging down (swamps)
	Bush, // a low round leaf ball on a stub trunk
}

// Build a tree (round oak, conical spruce, slim birch, or a flat-topped
// acacia). chunk_set clips any leaves that spill past the chunk edge.
@(private = "file")
place_tree :: proc(c: ^Chunk, lx, surf_y, lz, trunk_h: int, kind: TreeKind) {
	base := surf_y + 1
	for i in 0 ..< trunk_h {
		chunk_set(c, lx, base + i, lz, .Wood)
	}
	crown := base + trunk_h - 1
	switch kind {
	case .Spruce:
		for dy := -3; dy <= 1; dy += 1 {
			r := dy <= -2 ? 2 : (dy <= 0 ? 1 : 0)
			for dz in -r ..= r {
				for dx in -r ..= r {
					if r > 0 && abs(dx) == r && abs(dz) == r do continue // clip corners
					if chunk_get(c, lx + dx, crown + dy, lz + dz) == .Air {
						chunk_set(c, lx + dx, crown + dy, lz + dz, .Leaves)
					}
				}
			}
		}
	case .Birch:
		// a smaller, denser round crown (fixed r=1) than oak's — reads as a
		// visibly slimmer tree instead of just a recolour.
		for dy in -1 ..= 1 {
			r := 1
			for dz in -r ..= r {
				for dx in -r ..= r {
					if dx == 0 && dz == 0 && dy < 1 do continue
					if chunk_get(c, lx + dx, crown + dy, lz + dz) == .Air {
						chunk_set(c, lx + dx, crown + dy, lz + dz, .Leaves)
					}
				}
			}
		}
	case .Oak:
		for dy in -1 ..= 1 {
			r := dy == 1 ? 1 : 2
			for dz in -r ..= r {
				for dx in -r ..= r {
					if dx == 0 && dz == 0 && dy < 1 do continue
					if chunk_get(c, lx + dx, crown + dy, lz + dz) == .Air {
						chunk_set(c, lx + dx, crown + dy, lz + dz, .Leaves)
					}
				}
			}
		}
	case .Acacia:
		// A flat, wide umbrella: a broad single-layer disc at the crown with a
		// smaller cap just above it — the signature savanna silhouette.
		for dz in -2 ..= 2 {
			for dx in -2 ..= 2 {
				if abs(dx) == 2 && abs(dz) == 2 do continue // round the corners
				if chunk_get(c, lx + dx, crown, lz + dz) == .Air {
					chunk_set(c, lx + dx, crown, lz + dz, .Leaves)
				}
			}
		}
		for dz in -1 ..= 1 {
			for dx in -1 ..= 1 {
				if chunk_get(c, lx + dx, crown + 1, lz + dz) == .Air {
					chunk_set(c, lx + dx, crown + 1, lz + dz, .Leaves)
				}
			}
		}
	case .Pine:
		// A tall, narrow spire: many short rings tapering steeply to a point,
		// slimmer and pointier than the spruce.
		for dy := -5; dy <= 1; dy += 1 {
			layer := dy + 5 // 0 (bottom) .. 6 (top)
			r := layer < 2 ? 2 : (layer < 5 ? 1 : 0)
			for dz in -r ..= r {
				for dx in -r ..= r {
					if r > 0 && abs(dx) == r && abs(dz) == r do continue
					if chunk_get(c, lx + dx, crown + dy, lz + dz) == .Air {
						chunk_set(c, lx + dx, crown + dy, lz + dz, .Leaves)
					}
				}
			}
		}
	case .BigOak:
		// a thick tree: a second trunk column and a broad two-tier canopy.
		for i in 0 ..< trunk_h do chunk_set(c, lx + 1, base + i, lz, .Wood)
		for dy in -2 ..= 0 {
			r := dy == 0 ? 2 : 3
			for dz in -r ..= r {
				for dx in -r ..= r {
					if abs(dx) == r && abs(dz) == r do continue
					if chunk_get(c, lx + dx, crown + dy, lz + dz) == .Air {
						chunk_set(c, lx + dx, crown + dy, lz + dz, .Leaves)
					}
				}
			}
		}
	case .Palm:
		// a bare trunk crowned with four drooping fronds and a top tuft.
		chunk_set(c, lx, crown + 1, lz, .Leaves)
		for d in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
			if chunk_get(c, lx + d[0], crown + 1, lz + d[1]) == .Air do chunk_set(c, lx + d[0], crown + 1, lz + d[1], .Leaves)
			if chunk_get(c, lx + 2 * d[0], crown, lz + 2 * d[1]) == .Air do chunk_set(c, lx + 2 * d[0], crown, lz + 2 * d[1], .Leaves) // frond tip droops
		}
	case .Willow:
		// a rounded crown with leaf strands trailing down from the rim.
		for dy in -1 ..= 1 {
			r := dy == 1 ? 1 : 2
			for dz in -r ..= r {
				for dx in -r ..= r {
					if dx == 0 && dz == 0 && dy < 1 do continue
					if chunk_get(c, lx + dx, crown + dy, lz + dz) == .Air {
						chunk_set(c, lx + dx, crown + dy, lz + dz, .Leaves)
					}
				}
			}
		}
		chunk_set(c, lx, crown + 2, lz, .Leaves)
		for d in ([4][2]int{{2, 0}, {-2, 0}, {0, 2}, {0, -2}}) {
			for hang in 1 ..= 2 {
				if chunk_get(c, lx + d[0], crown - hang, lz + d[1]) == .Air {
					chunk_set(c, lx + d[0], crown - hang, lz + d[1], .Leaves)
				}
			}
		}
	case .Bush:
		// a squat round leaf ball (trunk_h is small for these).
		for dy in 0 ..= 1 {
			for dz in -1 ..= 1 {
				for dx in -1 ..= 1 {
					if dy == 1 && abs(dx) == 1 && abs(dz) == 1 do continue
					if chunk_get(c, lx + dx, crown + dy, lz + dz) == .Air {
						chunk_set(c, lx + dx, crown + dy, lz + dz, .Leaves)
					}
				}
			}
		}
	}
	rounded := kind != .Acacia && kind != .Palm && kind != .Bush && kind != .BigOak
	if rounded do chunk_set(c, lx, crown + 2, lz, .Leaves) // rounded/pointed top
}

// Place a conifer and dust its canopy with snow: for every column the crown
// covers, cap the topmost leaf with a Snow block. Gives cold-biome trees the
// snow-laden look without needing a whole separate snowy-leaf block.
// Not file-private: tests exercise it directly.
place_snowy_tree :: proc(c: ^Chunk, lx, surf_y, lz, trunk_h: int, kind: TreeKind) {
	place_tree(c, lx, surf_y, lz, trunk_h, kind)
	top := surf_y + 1 + trunk_h + 2 // a little above the highest possible leaf
	for dz in -2 ..= 2 {
		for dx in -2 ..= 2 {
			for y := top; y > surf_y; y -= 1 {
				if chunk_get(c, lx + dx, y, lz + dz) == .Leaves {
					if chunk_get(c, lx + dx, y + 1, lz + dz) == .Air {
						chunk_set(c, lx + dx, y + 1, lz + dz, .Snow)
					}
					break
				}
			}
		}
	}
}

// ~1 in 4 trees in mixed-forest biomes come out as a birch instead of an
// oak, for visual variety instead of every tree in a forest being identical.
@(private = "file")
oak_or_birch :: proc(hsh: u64) -> TreeKind {
	return (hsh >> 20) % 4 == 0 ? TreeKind.Birch : TreeKind.Oak
}

// Pick a tree kind from a weighted list (repeat entries to weight them).
@(private = "file")
pick_tree :: proc(hsh: u64, kinds: []TreeKind) -> TreeKind {
	return kinds[(hsh >> 20) % u64(len(kinds))]
}

// Bushes/palms want a stubby or bare trunk; everything else a normal one.
@(private = "file")
tree_trunk_h :: proc(kind: TreeKind, base: int) -> int {
	#partial switch kind {
	case .Bush:
		return 1
	case .Palm:
		return base + 2 // taller bare stem
	case .BigOak:
		return base + 1
	}
	return base
}

@(private = "file")
flower_kind :: proc(hsh: u64) -> BlockId {
	return (hsh >> 15) % 2 == 0 ? BlockId.FlowerRed : BlockId.FlowerYellow
}

// Pick one entry from a biome's flora palette by a column's hash, so a biome's
// ground cover is a varied mix (several flower colours, grass, ferns) instead
// of one repeated sprite.
@(private = "file")
pick_plant :: proc(hsh: u64, palette: []BlockId) -> BlockId {
	return palette[(hsh >> 28) % u64(len(palette))]
}

// Place a surface sprite plant on a column if the cell above the surface is
// clear. Dead bushes tolerate barren ground (sand/red sand/snow); the leafy
// plants want grass.
@(private = "file")
put_plant :: proc(c: ^Chunk, lx, surf_y, lz: int, b: BlockId) {
	if chunk_get(c, lx, surf_y + 1, lz) == .Air {
		chunk_set(c, lx, surf_y + 1, lz, b)
	}
}

// A tree's canopy spreads up to 2 blocks past its trunk (see place_tree),
// but that spread is computed purely from the trunk's own height — it never
// checks what's actually at those neighbouring columns. Planting a tree
// right at a shoreline or cliff edge let the canopy hang out over open
// water/air with no visible support, reading as a floating box of leaves
// rather than a tree. Requiring every column within the canopy's radius to
// be reasonably close to the trunk's own height (not a sharp drop-off)
// keeps trees away from edges where that would happen.
@(private = "file")
TREE_SITE_RADIUS :: 2
@(private = "file")
tree_site_clear :: proc(heights: []int, lx, lz, surf_y: int) -> bool {
	for dz in -TREE_SITE_RADIUS ..= TREE_SITE_RADIUS {
		for dx in -TREE_SITE_RADIUS ..= TREE_SITE_RADIUS {
			nh := heights[(lx + dx) + (lz + dz) * CHUNK_W]
			if surf_y - nh > 2 do return false
		}
	}
	return true
}

// A low-frequency field carving each biome into large sub-region VARIANTS
// (birch vs flower forest, sunflower plains, snowy vs old-growth taiga, wooded
// badlands). Big wavelength so a variant is a whole tract you walk across.
// Not file-private: tests exercise it.
biome_variant :: proc(seed: u64, wx, wz: int) -> f32 {
	return fbm2(seed + 2718, f32(wx) * 0.005, f32(wz) * 0.005, 2)
}

// A squat mound of cobblestone, mossy on a quarter of its blocks, sitting on the
// surface — the mossy boulders strewn across taiga, mountains and meadows in MC.
@(private = "file")
place_boulder :: proc(c: ^Chunk, lx, surf_y, lz: int, hsh: u64) {
	bt :: proc(hsh: u64, k: uint) -> BlockId {
		return ((hsh >> k) & 3) == 0 ? .MossyCobble : .Cobblestone
	}
	for dx in -1 ..= 1 do for dz in -1 ..= 1 {
		chunk_set(c, lx + dx, surf_y + 1, lz + dz, bt(hsh, uint((dx + 1) * 3 + (dz + 1))))
	}
	chunk_set(c, lx, surf_y + 2, lz, bt(hsh, 9))
	if (hsh >> 20) & 1 == 0 do chunk_set(c, lx + 1, surf_y + 2, lz, bt(hsh, 10))
	if (hsh >> 21) & 1 == 0 do chunk_set(c, lx - 1, surf_y + 2, lz, bt(hsh, 11))
	if (hsh >> 22) & 1 == 0 do chunk_set(c, lx, surf_y + 2, lz + 1, bt(hsh, 12))
}

// Per-biome surface decoration: trees (density/type varies) and desert cacti.
generate_trees :: proc(c: ^Chunk, seed: u64, base_x, base_z: int, heights: []int, biomes: []Biome) {
	for lz in 2 ..< CHUNK_D - 2 {
		for lx in 2 ..< CHUNK_W - 2 {
			biome := biomes[lx + lz * CHUNK_W]
			surf_y := heights[lx + lz * CHUNK_W] - 1
			wx := base_x + lx
			wz := base_z + lz
			hsh := hash_u64(seed ~ (u64(i64(wx)) * 0x9E3779B1) ~ (u64(i64(wz)) * 0x85EBCA77))
			r := hsh % 1000
			th := int((hsh >> 10) % 3)

			// Underwater: grow kelp strands up from soft, deep-enough seabed so the
			// ocean floor isn't a barren plain. The depth gate keeps it out of shallow
			// river/pond water.
			if surf_y < SEA_LEVEL {
				sb := chunk_get(c, lx, surf_y, lz)
				soft := sb == .Sand || sb == .Gravel || sb == .Dirt || sb == .CoarseDirt
				water_above := chunk_get(c, lx, surf_y + 1, lz) == .Water
				if soft && water_above && SEA_LEVEL - surf_y >= 2 {
					temp, _ := world_climate(seed, wx, wz)
					if temp > 0.25 {
						// Warm water: a colourful reef of coral heads + seagrass
						// tufts instead of cold kelp forests.
						pick := (hsh >> 38) % 100
						if pick < 24 {
							col := (hsh >> 41) % 3
							cb := col == 0 ? BlockId.CoralPink : (col == 1 ? BlockId.CoralBlue : BlockId.CoralPurple)
							chunk_set(c, lx, surf_y + 1, lz, cb)
							if SEA_LEVEL - surf_y >= 3 && (hsh >> 44) % 2 == 0 && chunk_get(c, lx, surf_y + 2, lz) == .Water {
								chunk_set(c, lx, surf_y + 2, lz, .Seagrass)
							}
						} else if pick < 60 {
							chunk_set(c, lx, surf_y + 1, lz, .Seagrass)
						}
					} else if SEA_LEVEL - surf_y >= 3 && r < 95 {
						// Cool/temperate deep water: kelp forest.
						top := min(SEA_LEVEL - 1, surf_y + 2 + int((hsh >> 40) % 6))
						for y in surf_y + 1 ..= top {
							if chunk_get(c, lx, y, lz) == .Water do chunk_set(c, lx, y, lz, .Kelp)
						}
					} else if r < 40 {
						// otherwise the odd seagrass tuft so no seabed is wholly bare
						chunk_set(c, lx, surf_y + 1, lz, .Seagrass)
					}
				}
				continue
			}
			surf := chunk_get(c, lx, surf_y, lz)
			site_ok := tree_site_clear(heights, lx, lz, surf_y)

			// Each vegetated biome gets its own tree(s) plus a distinct palette
			// of ground cover (4+ flora types apiece), so biomes read as
			// genuinely different places rather than the same trees everywhere.
			grass := surf == .Grass || surf == .Podzol || surf == .CoarseDirt
			variant := biome_variant(seed, wx, wz)

			// Sugar cane: on grass or sand right at the water's edge, a clump of
			// 1-3 reeds - the waterside reeds Minecraft grows along rivers, lakes
			// and coasts. Checked for every biome before its own flora so any
			// riverbank gets them.
			if (surf == .Grass || surf == .Sand) && surf_y <= SEA_LEVEL + 1 && r < 190 {
				near_water := false
				for d in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
					if chunk_get(c, lx + d[0], surf_y, lz + d[1]) == .Water {
						near_water = true
						break
					}
				}
				if near_water {
					n := 1 + int((hsh >> 30) % 3) // 1..3 tall
					for i in 0 ..< n do chunk_set(c, lx, surf_y + 1 + i, lz, .SugarCane)
					continue
				}
			}

			// Boulders: mossy cobble mounds strewn across the cold, rocky biomes.
			if (biome == .Taiga || biome == .Mountains || biome == .Meadow || biome == .Snow) &&
			   site_ok &&
			   (surf == .Grass || surf == .Podzol || surf == .CoarseDirt || surf == .Snow || surf == .Stone || surf == .Gravel) &&
			   (hsh >> 46) % 340 == 0 {
				place_boulder(c, lx, surf_y, lz, hsh)
				continue
			}

			switch biome {
			case .Desert:
				// Cacti + dead bushes on the sand — sparse by nature.
				if surf == .Sand && r < 8 {
					for i in 0 ..< 1 + th do chunk_set(c, lx, surf_y + 1 + i, lz, .Cactus)
				} else if surf == .Sand && r < 22 {
					put_plant(c, lx, surf_y, lz, .DeadBush)
				}
			case .Badlands:
				// wooded-badlands variant: scattered oaks on the grassy plateau
				if grass && site_ok && r < 20 {
					place_tree(c, lx, surf_y, lz, 4 + th % 2, .Oak)
				} else if grass && r < 55 {
					put_plant(c, lx, surf_y, lz, pick_plant(hsh, {.TallGrass, .DeadBush, .FlowerYellow}))
				} else if surf == .RedSand && r < 6 {
					for i in 0 ..< 1 + th % 2 do chunk_set(c, lx, surf_y + 1 + i, lz, .Cactus)
				} else if surf == .RedSand && r < 24 {
					put_plant(c, lx, surf_y, lz, .DeadBush)
				}
			case .Forest:
				// variants: a birch grove (variant high) or a flower forest
				// (variant low: sparser trees, a carpet of mixed blooms).
				birch := variant > 0.32
				flower := variant < -0.32
				if grass && site_ok && r < (flower ? 20 : 42) {
					k := birch ? TreeKind.Birch : pick_tree(hsh, {.Oak, .Oak, .Birch, .BigOak})
					place_tree(c, lx, surf_y, lz, tree_trunk_h(k, 4 + th), k)
				} else if grass && site_ok && (hsh >> 44) % 220 == 0 {
					chunk_set(c, lx, surf_y + 1, lz, .Pumpkin) // rare pumpkin
				} else if grass && r < (flower ? 94 : 78) {
					pal :=
						flower \
						? []BlockId {
							.FlowerRed,
							.FlowerYellow,
							.FlowerBlue,
							.FlowerPink,
							.FlowerWhite,
							.TallGrass,
						} \
						: []BlockId{.TallGrass, .Fern, .TallGrass, .FlowerRed, .FlowerBlue, .BrownMushroom, .RedMushroom}
					put_plant(c, lx, surf_y, lz, pick_plant(hsh, pal))
				}
			case .Swamp:
				// humid ground pools with standing marsh water + the odd lily pad
				if grass && site_ok && (hsh >> 26) % 100 < 26 {
					chunk_set(c, lx, surf_y, lz, .Water)
					if (hsh >> 8) % 3 == 0 do chunk_set(c, lx, surf_y + 1, lz, .LilyPad)
				} else if grass && site_ok && r < 16 {
					k := pick_tree(hsh, {.Willow, .Willow, .Oak})
					place_tree(c, lx, surf_y, lz, tree_trunk_h(k, 4 + th % 2), k)
				} else if grass && r < 70 {
					put_plant(c, lx, surf_y, lz, pick_plant(hsh, {.TallGrass, .Fern, .FlowerBlue, .DeadBush, .RedMushroom, .BrownMushroom}))
				}
			case .Plains:
				sunflower := variant > 0.34 // a sea of yellow blooms
				if grass && site_ok && r < 8 {
					k := pick_tree(hsh, {.Oak, .Birch, .Bush, .BigOak})
					place_tree(c, lx, surf_y, lz, tree_trunk_h(k, 4 + th), k)
				} else if grass && site_ok && (hsh >> 44) % 220 == 0 {
					chunk_set(c, lx, surf_y + 1, lz, .Pumpkin) // rare pumpkin
				} else if grass && r < (sunflower ? 78 : 60) {
					pal :=
						sunflower \
						? []BlockId{.FlowerYellow, .FlowerYellow, .FlowerYellow, .TallGrass} \
						: []BlockId{.TallGrass, .TallGrass, .FlowerRed, .FlowerYellow, .FlowerBlue}
					put_plant(c, lx, surf_y, lz, pick_plant(hsh, pal))
				}
			case .Savanna:
				if grass && site_ok && r < 6 {
					place_tree(c, lx, surf_y, lz, 5 + th % 2, .Acacia)
				} else if grass && r < 55 {
					put_plant(
						c,
						lx,
						surf_y,
						lz,
						pick_plant(hsh, {.TallGrass, .TallGrass, .DeadBush, .FlowerYellow}),
					)
				}
			case .Taiga:
				// old-growth variant: taller, denser conifers
				old_growth := variant > 0.32
				if grass && site_ok && r < (old_growth ? 46 : 34) {
					kind := (hsh >> 18) % 3 == 0 ? TreeKind.Pine : TreeKind.Spruce
					place_snowy_tree(c, lx, surf_y, lz, (old_growth ? 8 : 6) + th, kind)
				} else if grass && r < 66 {
					put_plant(
						c,
						lx,
						surf_y,
						lz,
						pick_plant(hsh, {.Fern, .TallGrass, .Fern, .FlowerWhite, .BrownMushroom}),
					)
				}
			case .Jungle:
				// Dense, tall canopy over a lush understorey, with pools + bamboo.
				if grass && site_ok && (hsh >> 26) % 100 < 8 {
					chunk_set(c, lx, surf_y, lz, .Water)
				} else if grass && site_ok && r < 58 {
					k := pick_tree(hsh, {.BigOak, .Oak, .BigOak})
					place_tree(c, lx, surf_y, lz, tree_trunk_h(k, 7 + th), k)
				} else if grass && r < 74 {
					for i in 0 ..< 2 + th do chunk_set(c, lx, surf_y + 1 + i, lz, .Bamboo) // bamboo stalk
				} else if grass && r < 96 {
					put_plant(
						c,
						lx,
						surf_y,
						lz,
						pick_plant(hsh, {.Fern, .TallGrass, .Fern, .FlowerPink, .TallGrass, .RedMushroom}),
					)
				}
			case .Meadow:
				// Flower-carpeted grass, only the occasional tree.
				if grass && site_ok && r < 5 {
					k := pick_tree(hsh, {.Oak, .Birch, .Bush})
					place_tree(c, lx, surf_y, lz, tree_trunk_h(k, 4 + th), k)
				} else if grass && r < 72 {
					put_plant(
						c,
						lx,
						surf_y,
						lz,
						pick_plant(
							hsh,
							{.FlowerRed, .FlowerYellow, .FlowerBlue, .FlowerPink, .FlowerWhite, .TallGrass},
						),
					)
				}
			case .Snow:
				// Sparse snow-laden conifers (spruce + pine) and the odd bush.
				if surf == .Snow && site_ok && r < 9 {
					kind := (hsh >> 18) % 3 == 0 ? TreeKind.Pine : TreeKind.Spruce
					place_snowy_tree(c, lx, surf_y, lz, 5 + th, kind)
				} else if surf == .Snow && r < 16 {
					put_plant(c, lx, surf_y, lz, r < 12 ? .DeadBush : .FlowerWhite)
				}
			case .Beach:
				// the odd palm leaning over the sand
				if surf == .Sand && site_ok && r < 5 {
					place_tree(c, lx, surf_y, lz, tree_trunk_h(.Palm, 5 + th), .Palm)
				}
			case .Mountains, .Ocean:
			// bare
			}
		}
	}
}
