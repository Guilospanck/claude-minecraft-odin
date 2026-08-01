package main

import "base:intrinsics"
import "core:fmt"
import "core:math"
import ma "vendor:miniaudio"

AUDIO_SR :: 44100
MAX_VOICES :: 24

Sound :: enum {
	Break,
	Place,
	Step,
	Jump,
	Hurt,
}

@(private = "file")
Voice :: struct {
	samples: []f32, // points into a bank buffer (stable for the process lifetime)
	pos:     int,
	gain:    f32,
	active:  bool, // only the game thread sets true, only the callback sets false
}

@(private = "file")
Audio :: struct {
	device: ma.device,
	ok:     bool,
	voices: [MAX_VOICES]Voice,
	bank:   [Sound][]f32,
}

@(private = "file")
g_audio: Audio

// --- procedural sound effects (mono f32 @ AUDIO_SR) ---

@(private = "file")
sfx_rng: u32 = 0x1234_5678

@(private = "file")
noise :: proc() -> f32 {
	sfx_rng = sfx_rng * 1664525 + 1013904223
	return f32(sfx_rng >> 8) / f32(1 << 24) * 2 - 1
}

@(private = "file")
secs :: proc(s: f32) -> int {
	return int(f32(AUDIO_SR) * s)
}

@(private = "file")
make_break :: proc() -> []f32 {
	n := secs(0.20)
	buf := make([]f32, n)
	for i in 0 ..< n {
		t := f32(i) / AUDIO_SR
		buf[i] = noise() * math.exp(-t * 22) * 0.6
	}
	return buf
}

@(private = "file")
make_place :: proc() -> []f32 {
	n := secs(0.09)
	buf := make([]f32, n)
	for i in 0 ..< n {
		t := f32(i) / AUDIO_SR
		env := math.exp(-t * 40)
		buf[i] = (math.sin(t * 2 * math.PI * 440) * 0.5 + noise() * 0.3) * env * 0.5
	}
	return buf
}

@(private = "file")
make_step :: proc() -> []f32 {
	n := secs(0.12)
	buf := make([]f32, n)
	lp: f32 = 0
	for i in 0 ..< n {
		t := f32(i) / AUDIO_SR
		env := math.exp(-t * 30)
		lp = lp * 0.92 + noise() * 0.08 // lowpassed noise
		low := math.sin(t * 2 * math.PI * 95) * 0.5
		buf[i] = (lp * 1.5 + low) * env * 0.35
	}
	return buf
}

@(private = "file")
make_jump :: proc() -> []f32 {
	n := secs(0.18)
	buf := make([]f32, n)
	phase: f32 = 0
	for i in 0 ..< n {
		t := f32(i) / AUDIO_SR
		env := math.exp(-t * 10)
		freq := 300.0 + 300.0 * (t / 0.18) // sweep up
		phase += 2 * math.PI * freq / AUDIO_SR
		buf[i] = math.sin(phase) * env * 0.4
	}
	return buf
}

@(private = "file")
make_hurt :: proc() -> []f32 {
	n := secs(0.16)
	buf := make([]f32, n)
	phase: f32 = 0
	for i in 0 ..< n {
		t := f32(i) / AUDIO_SR
		env := math.exp(-t * 14)
		freq := 170.0 - 60.0 * (t / 0.16) // downward buzz
		phase += 2 * math.PI * freq / AUDIO_SR
		sq: f32 = math.sin(phase) >= 0 ? 1 : -1 // square wave
		buf[i] = sq * env * 0.35
	}
	return buf
}

// --- device + mixing ---

@(private = "file")
audio_callback :: proc "c" (dev: ^ma.device, out, inp: rawptr, frames: u32) {
	n := int(frames)
	buf := ([^]f32)(out) // interleaved stereo, pre-silenced by miniaudio
	for vi in 0 ..< MAX_VOICES {
		v := &g_audio.voices[vi]
		if !intrinsics.atomic_load(&v.active) do continue
		s := v.samples
		pos := v.pos
		g := v.gain
		i := 0
		for i < n && pos < len(s) {
			val := s[pos] * g
			buf[i * 2] += val
			buf[i * 2 + 1] += val
			pos += 1
			i += 1
		}
		v.pos = pos
		if pos >= len(s) {
			intrinsics.atomic_store(&v.active, false)
		}
	}
	// soft clip
	for i in 0 ..< n * 2 {
		if buf[i] > 1 do buf[i] = 1
		else if buf[i] < -1 do buf[i] = -1
	}
}

audio_init :: proc() {
	g_audio.bank[.Break] = make_break()
	g_audio.bank[.Place] = make_place()
	g_audio.bank[.Step] = make_step()
	g_audio.bank[.Jump] = make_jump()
	g_audio.bank[.Hurt] = make_hurt()

	cfg := ma.device_config_init(.playback)
	cfg.playback.format = .f32
	cfg.playback.channels = 2
	cfg.sampleRate = AUDIO_SR
	cfg.dataCallback = audio_callback

	if ma.device_init(nil, &cfg, &g_audio.device) != .SUCCESS {
		fmt.eprintln("audio: device init failed; running muted")
		return
	}
	if ma.device_start(&g_audio.device) != .SUCCESS {
		fmt.eprintln("audio: device start failed; running muted")
		ma.device_uninit(&g_audio.device)
		return
	}
	g_audio.ok = true
}

audio_shutdown :: proc() {
	if g_audio.ok {
		ma.device_uninit(&g_audio.device)
	}
	for s in Sound {
		delete(g_audio.bank[s])
	}
}

// Play a one-shot sound on the first free voice (dropped if all are busy).
audio_play :: proc(s: Sound, gain: f32 = 1.0) {
	if !g_audio.ok do return
	buf := g_audio.bank[s]
	if len(buf) == 0 do return
	for vi in 0 ..< MAX_VOICES {
		v := &g_audio.voices[vi]
		if intrinsics.atomic_load(&v.active) do continue
		v.samples = buf
		v.pos = 0
		v.gain = gain
		intrinsics.atomic_store(&v.active, true)
		return
	}
}
