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
	Eat,
}

// Looping background music, chosen by context (see audio_set_music).
MusicTrack :: enum {
	Calm, // overworld, peaceful
	Combat, // a hostile mob is near
	Nether, // the nether dimension
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
	device:       ma.device,
	ok:           bool,
	voices:       [MAX_VOICES]Voice,
	bank:         [Sound][]f32,
	music:        [MusicTrack][]f32,
	music_target: int, // MusicTrack the game wants (game thread -> callback, atomic)
	music_master: f32, // music volume from settings (benign cross-thread read)
	music_cur:    int, // MusicTrack currently sounding (callback-owned)
	music_pos:    int, // loop read position (callback-owned)
	music_gain:   f32, // current fade gain (callback-owned)
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

@(private = "file")
make_eat :: proc() -> []f32 {
	n := secs(0.42)
	buf := make([]f32, n)
	lp: f32 = 0
	step :: f32(0.14) // three quick "bites"
	for i in 0 ..< n {
		t := f32(i) / AUDIO_SR
		bt := t - f32(int(t / step)) * step
		env := math.exp(-bt * 26)
		lp = lp * 0.82 + noise() * 0.18 // lowpassed crunch
		buf[i] = lp * env * 0.55
	}
	return buf
}

// --- procedural music (seamless-ish loops; short edge fades hide the seam) ---

@(private = "file")
edge_fade :: proc(i, n: int) -> f32 {
	f := secs(0.06)
	if i < f do return f32(i) / f32(f)
	if i >= n - f do return f32(n - 1 - i) / f32(f)
	return 1
}

@(private = "file")
make_music_calm :: proc() -> []f32 {
	n := secs(12)
	buf := make([]f32, n)
	chord := [4]f32{110.0, 164.81, 220.0, 277.18} // A major pad
	arp := [6]f32{440.0, 554.37, 659.25, 880.0, 659.25, 554.37}
	step := f32(0.6)
	for i in 0 ..< n {
		t := f32(i) / AUDIO_SR
		trem := 0.55 + 0.45 * math.sin(2 * math.PI * 0.08 * t)
		s: f32 = 0
		for f in chord do s += math.sin(2 * math.PI * f * t)
		s *= 0.05 * trem
		ai := int(t / step) % len(arp)
		lt := t - f32(int(t / step)) * step
		s += math.sin(2 * math.PI * arp[ai] * t) * math.exp(-lt * 4.0) * 0.045
		buf[i] = s * edge_fade(i, n)
	}
	return buf
}

@(private = "file")
make_music_combat :: proc() -> []f32 {
	n := secs(6)
	buf := make([]f32, n)
	arp := [8]f32{220.0, 261.63, 329.63, 261.63, 220.0, 329.63, 392.0, 329.63} // A minor
	step := f32(0.25)
	beat := f32(0.5)
	for i in 0 ..< n {
		t := f32(i) / AUDIO_SR
		s: f32 = math.sin(2 * math.PI * 55.0 * t) * 0.05 // bass drone
		ai := int(t / step) % len(arp)
		lt := t - f32(int(t / step)) * step
		sq: f32 = math.sin(2 * math.PI * arp[ai] * t) >= 0 ? 1 : -1
		s += sq * math.exp(-lt * 8.0) * 0.05
		bt := t - f32(int(t / beat)) * beat // kick drum on every beat
		s += math.sin(2 * math.PI * 60.0 * bt) * math.exp(-bt * 26.0) * 0.2
		buf[i] = s * edge_fade(i, n)
	}
	return buf
}

@(private = "file")
make_music_nether :: proc() -> []f32 {
	n := secs(12)
	buf := make([]f32, n)
	ping := f32(3.0)
	for i in 0 ..< n {
		t := f32(i) / AUDIO_SR
		s: f32 = 0
		s += math.sin(2 * math.PI * 55.0 * t) * 0.06 // low root
		s += math.sin(2 * math.PI * 82.41 * t) * 0.04 // fifth
		s += math.sin(2 * math.PI * 58.27 * t) * 0.03 // dissonant shimmer
		swell := 0.6 + 0.4 * math.sin(2 * math.PI * 0.05 * t)
		s *= swell
		pt := t - f32(int(t / ping)) * ping // sparse metallic ping
		s += math.sin(2 * math.PI * 330.0 * t) * math.exp(-pt * 6.0) * 0.02
		buf[i] = s * edge_fade(i, n)
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

	// looping background music, gain-glided so track switches crossfade cleanly
	tgt := intrinsics.atomic_load(&g_audio.music_target)
	master := g_audio.music_master
	mt := g_audio.music[MusicTrack(g_audio.music_cur)]
	for i in 0 ..< n {
		want: f32 = g_audio.music_cur == tgt ? master * 0.35 : 0
		g_audio.music_gain += (want - g_audio.music_gain) * 0.00004
		if g_audio.music_cur != tgt && g_audio.music_gain < 0.002 {
			g_audio.music_cur = tgt // fully faded out: swap to the target track
			g_audio.music_pos = 0
			mt = g_audio.music[MusicTrack(g_audio.music_cur)]
		}
		if len(mt) > 0 {
			val := mt[g_audio.music_pos] * g_audio.music_gain
			buf[i * 2] += val
			buf[i * 2 + 1] += val
			g_audio.music_pos += 1
			if g_audio.music_pos >= len(mt) do g_audio.music_pos = 0
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
	g_audio.bank[.Eat] = make_eat()

	g_audio.music[.Calm] = make_music_calm()
	g_audio.music[.Combat] = make_music_combat()
	g_audio.music[.Nether] = make_music_nether()

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
	for m in MusicTrack {
		delete(g_audio.music[m])
	}
}

// Select the background music track (called each frame by the game). The gain
// glide in the mixer crossfades between tracks so switches are smooth.
audio_set_music :: proc(track: MusicTrack) {
	if !g_audio.ok do return
	intrinsics.atomic_store(&g_audio.music_target, int(track))
	g_audio.music_master = g_settings.volume
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
		v.gain = gain * g_settings.volume
		intrinsics.atomic_store(&v.active, true)
		return
	}
}
