package main

// A fixed-slot inventory: the player owns INV_SLOTS positioned stacks instead
// of a single count per block type, so two stacks of the same block can sit in
// different slots and stacks can be dragged/split/merged freely (see the Items
// tab in ui.odin). Slots 0..8 are the hotbar row; 9..35 are storage.

STACK_MAX :: 99
HOTBAR_SLOTS :: 9
STORAGE_ROWS :: 3
INV_SLOTS :: HOTBAR_SLOTS + STORAGE_ROWS * 9 // 36

// One inventory slot. id == .Air means the slot is empty (count is then 0).
ItemStack :: struct {
	id:    BlockId,
	count: int,
}

// The block the player currently has equipped (the selected hotbar slot).
inv_selected :: proc(p: ^Player) -> BlockId {
	return p.slots[p.selected_slot].id
}

// Total amount of `id` the player holds across every slot.
inv_count :: proc(p: ^Player, id: BlockId) -> int {
	if id == .Air do return 0
	n := 0
	for s in p.slots do if s.id == id do n += s.count
	return n
}

inv_has :: proc(p: ^Player, id: BlockId, n: int) -> bool {
	return inv_count(p, id) >= n
}

// Add n of `id`: top up existing stacks of that type first, then fill empty
// slots. Returns the leftover that didn't fit (0 when it all fit).
inv_add :: proc(p: ^Player, id: BlockId, n: int) -> int {
	if id == .Air || n <= 0 do return max(n, 0)
	rem := n
	for i in 0 ..< INV_SLOTS {
		if p.slots[i].id == id && p.slots[i].count < STACK_MAX {
			add := min(rem, STACK_MAX - p.slots[i].count)
			p.slots[i].count += add
			rem -= add
			if rem == 0 do return 0
		}
	}
	for i in 0 ..< INV_SLOTS {
		if p.slots[i].id == .Air {
			add := min(rem, STACK_MAX)
			p.slots[i] = {id, add}
			rem -= add
			if rem == 0 do return 0
		}
	}
	return rem // no room left
}

// Remove n of `id` across slots. Returns false and changes nothing if the
// player doesn't have that many.
inv_take :: proc(p: ^Player, id: BlockId, n: int) -> bool {
	if !inv_has(p, id, n) do return false
	rem := n
	for i in 0 ..< INV_SLOTS {
		if p.slots[i].id == id {
			take := min(rem, p.slots[i].count)
			p.slots[i].count -= take
			rem -= take
			if p.slots[i].count == 0 do p.slots[i] = {}
			if rem == 0 do break
		}
	}
	return true
}

// Remove and report every unit of `id` (used by chest deposit-all).
inv_remove_all :: proc(p: ^Player, id: BlockId) -> int {
	n := inv_count(p, id)
	inv_take(p, id, n)
	return n
}
