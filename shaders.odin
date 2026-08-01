package main

// Shader sources embedded at compile time so the built binary is self-contained.
CHUNK_VERT :: #load("assets/shaders/chunk.vert", string)
CHUNK_FRAG :: #load("assets/shaders/chunk.frag", string)
LINE_VERT :: #load("assets/shaders/line.vert", string)
LINE_FRAG :: #load("assets/shaders/line.frag", string)
HUD_VERT :: #load("assets/shaders/hud.vert", string)
HUD_FRAG :: #load("assets/shaders/hud.frag", string)
ENTITY_VERT :: #load("assets/shaders/entity.vert", string)
ENTITY_FRAG :: #load("assets/shaders/entity.frag", string)
SKY_VERT :: #load("assets/shaders/sky.vert", string)
SKY_FRAG :: #load("assets/shaders/sky.frag", string)
TEXT_VERT :: #load("assets/shaders/text.vert", string)
TEXT_FRAG :: #load("assets/shaders/text.frag", string)
MINIMAP_VERT :: #load("assets/shaders/minimap.vert", string)
MINIMAP_FRAG :: #load("assets/shaders/minimap.frag", string)
ICON_VERT :: #load("assets/shaders/icon.vert", string)
ICON_FRAG :: #load("assets/shaders/icon.frag", string)
