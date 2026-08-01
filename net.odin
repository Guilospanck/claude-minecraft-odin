package main

import "core:fmt"
import "core:net"
import "core:sync"
import "core:thread"

// Minimal LAN multiplayer over TCP. The server is authoritative for the world
// seed and relays block edits + player positions between everyone. World gen is
// deterministic from the shared seed, so only edits and positions cross the
// wire. Fixed-size little-endian messages.

MSG_HELLO :: u8(1) // server->client: [seed u64][id u32]
MSG_POS :: u8(2) // both:          [id u32][x y z yaw f32]
MSG_EDIT :: u8(3) // both:          [x y z i32][block u8][dim u8]
MSG_LEAVE :: u8(4) // server->client: [id u32]

NetMode :: enum {
	Off,
	Server,
	Client,
}

RemotePlayer :: struct {
	pos: Vec3,
	yaw: f32,
}

NetEdit :: struct {
	x, y, z: int,
	block:   BlockId,
	dim:     Dimension,
}

@(private = "file")
Conn :: struct {
	sock: net.TCP_Socket,
	id:   u32,
}

NetState :: struct {
	mode:        NetMode,
	mutex:       sync.Mutex,
	seed:        u64,
	my_id:       u32,
	listen_sock: net.TCP_Socket,
	server_sock: net.TCP_Socket, // client's link to the server
	clients:     [dynamic]Conn, // server: connected clients
	pending:     [dynamic]Conn, // server: accepted, awaiting a reader thread
	next_id:     u32,
	remotes:     map[u32]RemotePlayer,
	edits:       [dynamic]NetEdit, // inbound edits to apply on the main thread
}

g_net: NetState

net_active :: proc() -> bool {return g_net.mode != .Off}

// ---- encode / decode ----
@(private = "file")
put_u32 :: proc(b: []u8, v: u32) {
	b[0] = u8(v);b[1] = u8(v >> 8);b[2] = u8(v >> 16);b[3] = u8(v >> 24)
}
@(private = "file")
get_u32 :: proc(b: []u8) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}
@(private = "file")
put_u64 :: proc(b: []u8, v: u64) {put_u32(b[0:], u32(v));put_u32(b[4:], u32(v >> 32))}
@(private = "file")
get_u64 :: proc(b: []u8) -> u64 {return u64(get_u32(b[0:])) | u64(get_u32(b[4:])) << 32}
@(private = "file")
put_f32 :: proc(b: []u8, v: f32) {put_u32(b, transmute(u32)v)}
@(private = "file")
get_f32 :: proc(b: []u8) -> f32 {return transmute(f32)get_u32(b)}

@(private = "file")
msg_size :: proc(t: u8) -> int {
	switch t {
	case MSG_HELLO:
		return 12
	case MSG_POS:
		return 20
	case MSG_EDIT:
		return 14
	case MSG_LEAVE:
		return 4
	}
	return -1
}

@(private = "file")
recv_exact :: proc(sock: net.TCP_Socket, buf: []u8) -> bool {
	got := 0
	for got < len(buf) {
		n, err := net.recv_tcp(sock, buf[got:])
		if err != nil || n <= 0 do return false
		got += n
	}
	return true
}

@(private = "file")
send_all :: proc(sock: net.TCP_Socket, buf: []u8) -> bool {
	sent := 0
	for sent < len(buf) {
		n, err := net.send_tcp(sock, buf[sent:])
		if err != nil || n <= 0 do return false
		sent += n
	}
	return true
}

// ---- message builders (return type byte + payload in one buffer) ----
@(private = "file")
build_pos :: proc(buf: []u8, id: u32, p: Vec3, yaw: f32) {
	buf[0] = MSG_POS
	put_u32(buf[1:], id)
	put_f32(buf[5:], p.x);put_f32(buf[9:], p.y);put_f32(buf[13:], p.z);put_f32(buf[17:], yaw)
}
@(private = "file")
build_edit :: proc(buf: []u8, x, y, z: int, block: BlockId, dim: Dimension) {
	buf[0] = MSG_EDIT
	put_u32(buf[1:], u32(i32(x)));put_u32(buf[5:], u32(i32(y)));put_u32(buf[9:], u32(i32(z)))
	buf[13] = u8(block)
	buf[14] = u8(dim)
}

// ---- server ----
// Snapshot the target sockets under the mutex, then send OUTSIDE the lock so a
// slow/stalled peer can never freeze other threads (or deadlock the server).
// Callers must NOT hold g_net.mutex.
@(private = "file")
broadcast :: proc(buf: []u8, except: u32) {
	socks := make([dynamic]net.TCP_Socket, 0, 8)
	defer delete(socks)
	sync.mutex_lock(&g_net.mutex)
	for c in g_net.clients {
		if c.id != except do append(&socks, c.sock)
	}
	sync.mutex_unlock(&g_net.mutex)
	for s in socks {
		_ = send_all(s, buf)
	}
}

@(private = "file")
server_reader :: proc() {
	// claim one pending client
	sync.mutex_lock(&g_net.mutex)
	if len(g_net.pending) == 0 {
		sync.mutex_unlock(&g_net.mutex)
		return
	}
	conn := pop(&g_net.pending)
	sync.mutex_unlock(&g_net.mutex)

	for {
		t: [1]u8
		if !recv_exact(conn.sock, t[:]) do break
		size := msg_size(t[0])
		if size < 0 do break
		payload: [20]u8
		if size > 0 && !recv_exact(conn.sock, payload[:size]) do break

		switch t[0] {
		case MSG_POS:
			sync.mutex_lock(&g_net.mutex)
			g_net.remotes[conn.id] = RemotePlayer {
				pos = Vec3{get_f32(payload[4:]), get_f32(payload[8:]), get_f32(payload[12:])},
				yaw = get_f32(payload[16:]),
			}
			sync.mutex_unlock(&g_net.mutex)
			out: [21]u8
			out[0] = MSG_POS
			put_u32(out[1:], conn.id) // relay with the sender's id
			copy(out[5:], payload[4:20])
			broadcast(out[:], conn.id)
		case MSG_EDIT:
			sync.mutex_lock(&g_net.mutex)
			append(
				&g_net.edits,
				NetEdit {
					x = int(i32(get_u32(payload[0:]))),
					y = int(i32(get_u32(payload[4:]))),
					z = int(i32(get_u32(payload[8:]))),
					block = BlockId(payload[12]),
					dim = Dimension(payload[13]),
				},
			)
			sync.mutex_unlock(&g_net.mutex)
			relay: [15]u8
			relay[0] = MSG_EDIT
			copy(relay[1:], payload[:14])
			broadcast(relay[:], conn.id)
		}
	}

	// disconnect
	sync.mutex_lock(&g_net.mutex)
	for c, i in g_net.clients {
		if c.id == conn.id {
			ordered_remove(&g_net.clients, i)
			break
		}
	}
	delete_key(&g_net.remotes, conn.id)
	sync.mutex_unlock(&g_net.mutex)
	leave: [5]u8
	leave[0] = MSG_LEAVE
	put_u32(leave[1:], conn.id)
	broadcast(leave[:], conn.id)
	net.close(conn.sock)
}

@(private = "file")
server_accept :: proc() {
	for {
		client, _, err := net.accept_tcp(g_net.listen_sock)
		if err != nil do break

		sync.mutex_lock(&g_net.mutex)
		id := g_net.next_id
		g_net.next_id += 1
		seed := g_net.seed
		sync.mutex_unlock(&g_net.mutex)

		// Fully write HELLO BEFORE the socket becomes a broadcast target, so no
		// POS/EDIT can interleave ahead of the handshake bytes.
		hello: [13]u8
		hello[0] = MSG_HELLO
		put_u64(hello[1:], seed)
		put_u32(hello[9:], id)
		if !send_all(client, hello[:]) {
			net.close(client)
			continue
		}

		sync.mutex_lock(&g_net.mutex)
		append(&g_net.clients, Conn{sock = client, id = id})
		append(&g_net.pending, Conn{sock = client, id = id})
		sync.mutex_unlock(&g_net.mutex)
		thread.create_and_start(server_reader)
		fmt.println("[server] client", id, "connected")
	}
}

net_start_server :: proc(port: int, seed: u64) -> bool {
	ep := net.Endpoint {
		address = net.IP4_Address{0, 0, 0, 0},
		port    = port,
	}
	sock, err := net.listen_tcp(ep)
	if err != nil {
		fmt.eprintln("[server] listen failed:", err)
		return false
	}
	g_net.mode = .Server
	g_net.seed = seed
	g_net.my_id = 0
	g_net.next_id = 1
	g_net.listen_sock = sock
	g_net.remotes = make(map[u32]RemotePlayer)
	thread.create_and_start(server_accept)
	fmt.println("[server] listening on port", port, "seed", seed)
	return true
}

// ---- client ----
@(private = "file")
client_reader :: proc() {
	for {
		t: [1]u8
		if !recv_exact(g_net.server_sock, t[:]) do break
		size := msg_size(t[0])
		if size < 0 do break
		payload: [20]u8
		if size > 0 && !recv_exact(g_net.server_sock, payload[:size]) do break

		sync.mutex_lock(&g_net.mutex)
		switch t[0] {
		case MSG_POS:
			id := get_u32(payload[0:])
			if id != g_net.my_id {
				g_net.remotes[id] = RemotePlayer {
					pos = Vec3 {
						get_f32(payload[4:]),
						get_f32(payload[8:]),
						get_f32(payload[12:]),
					},
					yaw = get_f32(payload[16:]),
				}
			}
		case MSG_EDIT:
			append(
				&g_net.edits,
				NetEdit {
					x = int(i32(get_u32(payload[0:]))),
					y = int(i32(get_u32(payload[4:]))),
					z = int(i32(get_u32(payload[8:]))),
					block = BlockId(payload[12]),
					dim = Dimension(payload[13]),
				},
			)
		case MSG_LEAVE:
			delete_key(&g_net.remotes, get_u32(payload[0:]))
		}
		sync.mutex_unlock(&g_net.mutex)
	}
}

// Connect; blocks until the HELLO arrives. Returns the shared seed.
net_connect :: proc(addr: string) -> (seed: u64, ok: bool) {
	sock, err := net.dial_tcp(addr)
	if err != nil {
		fmt.eprintln("[client] connect failed:", err)
		return 0, false
	}
	hello: [13]u8
	if !recv_exact(sock, hello[:1]) || hello[0] != MSG_HELLO || !recv_exact(sock, hello[1:13]) {
		fmt.eprintln("[client] handshake failed")
		net.close(sock)
		return 0, false
	}
	g_net.mode = .Client
	g_net.server_sock = sock
	g_net.seed = get_u64(hello[1:])
	g_net.my_id = get_u32(hello[9:])
	g_net.remotes = make(map[u32]RemotePlayer)
	thread.create_and_start(client_reader)
	fmt.println("[client] connected as id", g_net.my_id, "seed", g_net.seed)
	return g_net.seed, true
}

// ---- per-frame hooks ----
net_send_pos :: proc(p: ^Player) {
	if g_net.mode == .Off do return
	buf: [21]u8
	build_pos(buf[:], g_net.my_id, p.pos, p.yaw)
	if g_net.mode == .Server {
		broadcast(buf[:], g_net.my_id) // self-locks
	} else {
		_ = send_all(g_net.server_sock, buf[:]) // only the main thread sends here
	}
}

net_send_edit :: proc(x, y, z: int, block: BlockId, dim: Dimension) {
	if g_net.mode == .Off do return
	buf: [15]u8
	build_edit(buf[:], x, y, z, block, dim)
	if g_net.mode == .Server {
		broadcast(buf[:], g_net.my_id)
	} else {
		_ = send_all(g_net.server_sock, buf[:])
	}
}

net_is_client :: proc() -> bool {return g_net.mode == .Client}

// Apply queued inbound edits to the world they belong to (main thread). Each
// edit carries its source dimension so a peer's overworld edit never lands in
// the nether (or vice-versa), whatever dimension the local player is in.
net_apply_edits :: proc(overworld, nether: ^World) {
	if g_net.mode == .Off do return
	sync.mutex_lock(&g_net.mutex)
	for e in g_net.edits {
		w := e.dim == .Nether ? nether : overworld
		world_set_block(w, e.x, e.y, e.z, e.block)
	}
	clear(&g_net.edits)
	sync.mutex_unlock(&g_net.mutex)
}

// Encode/decode roundtrip check (unit-testable without sockets).
net_test_roundtrip :: proc() -> bool {
	buf: [21]u8
	build_pos(buf[:], 7, Vec3{1.5, -2.25, 300.125}, 0.75)
	if buf[0] != MSG_POS do return false
	if get_u32(buf[1:]) != 7 do return false
	if get_f32(buf[5:]) != 1.5 do return false
	if get_f32(buf[9:]) != -2.25 do return false
	if get_f32(buf[13:]) != 300.125 do return false
	if get_f32(buf[17:]) != 0.75 do return false

	eb: [15]u8
	build_edit(eb[:], -5, 70, 12345, .Glowstone, .Nether)
	if eb[0] != MSG_EDIT do return false
	if int(i32(get_u32(eb[1:]))) != -5 do return false
	if int(i32(get_u32(eb[5:]))) != 70 do return false
	if int(i32(get_u32(eb[9:]))) != 12345 do return false
	if BlockId(eb[13]) != .Glowstone do return false
	if Dimension(eb[14]) != .Nether do return false
	return true
}

// Snapshot remote players for rendering (main thread).
net_remotes_snapshot :: proc(out: ^[dynamic]RemotePlayer) {
	clear(out)
	if g_net.mode == .Off do return
	sync.mutex_lock(&g_net.mutex)
	for _, rp in g_net.remotes {
		append(out, rp)
	}
	sync.mutex_unlock(&g_net.mutex)
}
