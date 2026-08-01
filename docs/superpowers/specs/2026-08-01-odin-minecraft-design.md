# Odin Minecraft Clone — Design

Date: 2026-08-01
Status: approved

## Goal
A voxel sandbox in pure Odin: chunked world, textured blocks, first-person
walking with physics, procedural terrain (heightmap + biomes + trees + 3D
caves), raycast place/break, per-vertex ambient occlusion, and world save/load.

## Stack
- Render: `vendor:OpenGL` (3.3/4.1 core, glad loader).
- Window/input: `vendor:glfw` (static `libglfw3.a` + Cocoa/IOKit/OpenGL frameworks).
- Image: `vendor:stb/image` (load atlas.png) and stb_image_write (in the atlas tool).
- Math: `core:math/linalg`.
- Noise: hand-written value/perlin + fbm (no stdlib noise), seeded.
- Build: `odin build . -out:mc -o:speed`. No external deps beyond the Odin
  toolchain (system GLFW static lib ships in the Odin vendor dir).

## Constants
- Chunk column: `CHUNK_W=16` (x), `CHUNK_D=16` (z), `CHUNK_H=128` (y).
- Block index: `x + z*W + y*W*D`.
- Atlas: 16x16 tiles, 16px each => 256x256 png.

## Modules (root `package main` unless noted)
- `constants.odin` — dims, tunables, shared aliases (Vec3/IVec3/Mat4).
- `assetdef/` (subpackage) — atlas tile coordinates + dims, shared by game and tool.
- `block.odin` — `BlockId` enum, solidity/transparency, per-face atlas tile.
- `noise.odin` — hashed value noise 2D/3D + fbm, seeded.
- `chunk.odin` — flat block store, get/set/index, dirty flags, GL mesh handles.
- `world.odin` — `map[IVec2]^Chunk`, streaming load/unload by radius, block access.
- `worldgen.odin` — height + biome + surface layering + water + 3D caves + ores + trees.
- `mesher.odin` — chunk -> vertices with face-culling + per-vertex AO; opaque + water passes.
- `camera.odin` — view/projection matrices, yaw/pitch.
- `player.odin` — state, WASD/jump/fly input, hotbar select, place/break dispatch.
- `physics.odin` — player AABB, gravity, axis-separated collision vs solid blocks.
- `raycast.odin` — Amanatides–Woo voxel DDA -> hit voxel + face normal + place cell.
- `glutil.odin` — shader compile/link, VAO/VBO helpers, uniform setters.
- `atlas.odin` — load atlas.png -> GL texture; tile -> UV rect.
- `render.odin` — upload dirty meshes, draw opaque then translucent water, fog, block outline.
- `hud.odin` — crosshair + selected-block swatch (screen-space quads).
- `save.odin` — per-chunk RLE files, world meta (seed), load-or-generate.
- `window.odin` — GLFW window + GL context + input callbacks.
- `main.odin` — init, main loop (input -> update -> stream -> render), shutdown save.
- `tools/gen_atlas.odin` (`package main`) — writes `assets/atlas.png` via stb_image_write.
- `assets/shaders/*.vert|frag` — chunk, line (outline), hud shaders.

## Data flow (per frame)
1. Poll input -> player velocity (WASD rel yaw, space, shift, fly toggle F).
2. Physics: gravity, axis-separated move + collision resolve, ground check.
3. Stream: ensure chunks in radius R are loaded (bounded gen/mesh per frame);
   unload+save chunks beyond R+1; newly generated chunks mark self + 4 neighbors dirty.
4. Raycast (reach 6): L-click break -> Air; R-click place at adjacent cell if empty
   and not intersecting player. Mark affected chunk(s) dirty.
5. Render: remesh dirty (bounded), draw opaque, then water (blend, depth-write off),
   block outline, HUD; fog toward sky color.

## Meshing / AO
- Emit a face only when the neighbor is transparent (culling). Water renders only
  against air (surface/edges).
- 6 vertices per face (two triangles), vertex = pos(3f) + uv(2f) + light(1f).
- Per-face directional shade (top 1.0, bottom .5, ±z .8, ±x .6) times AO factor
  (classic 3-neighbor occlusion 0..3 -> brightness).

## Worldgen
- 2D fbm -> base height. Temperature/moisture noise -> biome (plains/forest/desert/
  mountains/snow). Surface block by biome; dirt band; stone below; water to sea level.
- 3D fbm threshold below surface -> carve caves/overhangs.
- Rare 3D noise in stone -> ore. Deterministic per-column hash -> trees in
  plains/forest. Bedrock at y=0. Fully seed-deterministic.

## Save
- `saves/world/<cx>_<cz>.chunk`: RLE of the 32768 block array (u8 id + u16 run).
- `saves/world/meta`: world seed (u64). Load if present else generate; on unload
  and on quit, dirty/loaded chunks are written.

## Tests (`odin test`)
- noise determinism (same seed+coord -> same value).
- chunk index/get/set bounds.
- raycast DDA on a known grid (hit coord + face).
- AABB collision resolution stops at a wall.
- save/load RLE roundtrip (random chunk -> bytes -> chunk equal).
- mesher face-cull counts on a trivial chunk (single block => 6 faces).

## YAGNI (explicitly out)
Greedy meshing, mobs, inventory beyond hotbar, multiplayer, lighting propagation
(AO + directional shade only), threading (bounded per-frame work instead).

## Risks / mitigations
- GLFW/stb link on macOS: verified — vendor ships static libs; stb darwin libs
  built via `vendor/stb/src` Makefile. Smoke test compiles+links+runs.
- Startup hitch from mass chunk gen: bounded gen/mesh per frame + progressive load.
- Running a window is headless-unfriendly in CI; correctness covered by `odin test`
  and compile/link; interactive run happens on the user's machine.
