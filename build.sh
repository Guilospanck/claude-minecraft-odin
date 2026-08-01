#!/usr/bin/env bash
# Build the Odin Minecraft clone.
#   1. regenerate the texture atlas (pure-Odin tool)
#   2. compile the game (atlas.png is embedded via #load)
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-release}"

echo "[1/2] generating texture atlas..."
odin run tools -out:/tmp/mc_gen_atlas

echo "[2/2] building game..."
if [ "$MODE" = "debug" ]; then
	odin build . -out:mc -debug
else
	odin build . -out:mc -o:speed
fi

echo "done -> ./mc"
