package main

import "core:fmt"
import ad "assetdef"
import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

// The generated atlas embedded in the binary (built by `odin run tools`).
ATLAS_PNG :: #load("assets/atlas.png")

// UV rect for a tile, inset by half a texel to avoid bleeding between tiles.
tile_uv :: proc(t: ad.Tile) -> (u0, v0, u1, v1: f32) {
	inv := f32(1.0) / f32(ad.ATLAS_PX)
	inset := 0.5 * inv
	px := f32(t.x * ad.TILE_PX)
	py := f32(t.y * ad.TILE_PX)
	u0 = px * inv + inset
	v0 = py * inv + inset
	u1 = (px + f32(ad.TILE_PX)) * inv - inset
	v1 = (py + f32(ad.TILE_PX)) * inv - inset
	return
}

atlas_load :: proc() -> u32 {
	w, h, ch: i32
	data := stbi.load_from_memory(raw_data(ATLAS_PNG), i32(len(ATLAS_PNG)), &w, &h, &ch, 4)
	if data == nil {
		fmt.panicf("failed to decode embedded atlas.png")
	}
	defer stbi.image_free(data)

	tex: u32
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, data)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	return tex
}
