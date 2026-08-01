# Odin Minecraft Clone

A small voxel sandbox written in **pure Odin** with OpenGL 4.1 + GLFW.

![screenshot](docs/screenshot.png)

## Features

- Chunked world (16×16×128 columns), streamed in/out around the player.
- Procedural terrain: fbm heightmap, biomes (plains / forest / desert / snow /
  mountains), sea-level water, 3-D-noise caves, sparse ore, and trees.
- Greedy-free face-culled meshing with per-vertex ambient occlusion and fake
  directional sky-shading.
- First-person controller: gravity, AABB collision, walking, jumping, and a
  noclip fly mode (`F`).
- Raycast (Amanatides–Woo) block **break** / **place** with a targeting outline.
- Translucent water pass, distance fog, textured atlas, crosshair HUD.
- World **save/load** (per-chunk RLE files) with a persistent seed.
- **Mobs** — passive pigs, sheep, cows, chickens, and rabbits, plus hostile
  zombies and skeletons; blocky multi-box models with leg animation,
  wandering/chase AI, gravity/collision, step auto-jump, spawn/despawn.
- **Day-night cycle** — a 5-minute clock drives sky colour and ambient
  brightness (night → dawn/dusk glow → day), with a **sun, moon, and stars**.
- **Block lighting** — place **glowstone** (hotbar slot 9) for flood-filled
  point light (0–15, blocked by solids) that lights the night.
- **Sound** — procedurally synthesised SFX (break, place, footsteps, jump,
  mob hurt) via miniaudio; no audio files.
- **Combat & health** — 20-HP player with a heart HUD, knockback, fall
  damage, invulnerability frames, slow regen, and death → respawn.
- **Drops & inventory** — breaking a block drops a bobbing item you collect
  into a per-block inventory; placing consumes it (bedrock is unbreakable).
  Press `E` for a full **inventory screen** (custom bitmap-font text UI).
- **Crafting** — press `C` to craft (4 Sand + 1 Ore → 1 Glowstone).
- **Furnace & smelting** — place a Furnace and press `V` nearby to smelt
  Ore + Wood → Iron or Sand + Wood → Glass (translucent).

![animals](docs/mobs.png)
![night](docs/night.png)

## Requirements

- The [Odin](https://odin-lang.org) compiler (tested on `dev-2026-06`).
- macOS/Linux. GLFW and stb ship with Odin's `vendor` collection; on macOS the
  stb static libs may need building once:
  `make -C "$(dirname $(dirname $(readlink -f $(which odin))))/vendor/stb/src"`.

## Build & run

```sh
./build.sh            # generates the atlas, then builds ./mc
./mc                  # play
```

`build.sh debug` builds an unoptimised debug binary.

## Controls

| Input            | Action                    |
|------------------|---------------------------|
| `W A S D`        | Move                      |
| Mouse            | Look                      |
| `Space`          | Jump / fly up             |
| `Left Shift`     | Fly down                  |
| `F`              | Toggle fly (noclip)       |
| `1`–`9`          | Select hotbar block       |
| Left click       | Break block / hit mob     |
| Right click      | Place selected block      |
| `C`              | Craft (4 Sand + 1 Ore → Glowstone) |
| `V`              | Smelt near a furnace      |
| `E`              | Toggle inventory screen   |
| `Esc`            | Quit (saves the world)    |

## Tests

```sh
odin test .           # noise, chunk indexing, raycast, collision, meshing, save round-trip
```

## Environment knobs (testing / screenshots)

- `MC_FRAMES=N` – render N frames then exit cleanly (headless smoke test).
- `MC_SHOT=path.png` – write a screenshot of the final frame.
- `MC_CAM="x,y,z,yaw,pitch"` – override the camera (enables fly).
- `MC_TIME=t` – pin the time of day (0=midnight, 0.5=noon).
- `MC_MOBS=N` – force-spawn N animals in front of the camera.
- `MC_GLOW=1` – drop a few glowstone blocks ahead (to see block lighting).
- `MC_ZOMBIES=N` / `MC_ITEMS=N` – spawn zombies / dropped items ahead.
- `MC_SCAN=1` – generate a region, print nearby biome coordinates, and exit.

## Layout

Game code lives in the root `package main`. `assetdef/` holds the shared atlas
layout; `tools/gen_atlas.odin` is a standalone Odin program that paints
`assets/atlas.png`; shaders live in `assets/shaders/` and are embedded at
compile time via `#load`. See `docs/superpowers/specs/` for the design.
