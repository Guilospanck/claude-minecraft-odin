package main

// Shader sources embedded at compile time so the built binary is self-contained.
CHUNK_VERT :: #load("assets/shaders/chunk.vert", string)
CHUNK_FRAG :: #load("assets/shaders/chunk.frag", string)
LINE_VERT :: #load("assets/shaders/line.vert", string)
LINE_FRAG :: #load("assets/shaders/line.frag", string)
HUD_VERT :: #load("assets/shaders/hud.vert", string)
HUD_FRAG :: #load("assets/shaders/hud.frag", string)
