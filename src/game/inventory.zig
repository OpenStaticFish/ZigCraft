//! Inventory system for block storage and selection.
//!
//! Provides a hotbar (9 slots) and main inventory (27 slots) for
//! storing and selecting blocks to place.

const std = @import("std");
const BlockType = @import("../world/block.zig").BlockType;

/// Player inventory with hotbar and main storage.
pub const Inventory = struct {
    /// All inventory slots (0-8: hotbar, 9-35: main inventory)
    slots: [TOTAL_SLOTS]?ItemStack,

    /// Currently selected hotbar slot (0-8)
    selected_slot: u8,

    /// Number of hotbar slots
    pub const HOTBAR_SIZE: u8 = 9;

    /// Number of main inventory slots
    pub const MAIN_SIZE: u8 = 27;

    /// Total number of slots
    pub const TOTAL_SLOTS: u8 = HOTBAR_SIZE + MAIN_SIZE;

    /// An item stack (block type and count)
    pub const ItemStack = struct {
        block_type: BlockType,
        count: u8,

        /// Maximum stack size
        pub const MAX_STACK: u8 = 64;
    };

    /// Initialize a new inventory with default creative mode blocks.
    pub fn init() Inventory {
        var inv = Inventory{
            .slots = [_]?ItemStack{null} ** TOTAL_SLOTS,
            .selected_slot = 0,
        };

        // Fill inventory with all available block types
        // Skip air (0)
        var slot_idx: u8 = 0;
        var block_id: u8 = 1;
        while (slot_idx < TOTAL_SLOTS and block_id < 255) : (block_id += 1) {
            // Check if block_id is a valid enum value
            const maybe_bt = std.meta.intToEnum(BlockType, block_id) catch null;
            if (maybe_bt) |bt| {
                inv.slots[slot_idx] = .{ .block_type = bt, .count = 64 };
                slot_idx += 1;
            } else {
                // Heuristic stop if we went past likely defined blocks to avoid iterating to 255 unnecessary
                if (block_id > 50) break;
            }
        }

        return inv;
    }

    /// Initialize an empty inventory.
    pub fn initEmpty() Inventory {
        return Inventory{
            .slots = [_]?ItemStack{null} ** TOTAL_SLOTS,
            .selected_slot = 0,
        };
    }

    /// Get the currently selected block type (from hotbar).
    pub fn getSelectedBlock(self: Inventory) ?BlockType {
        if (self.slots[self.selected_slot]) |stack| {
            return stack.block_type;
        }
        return null;
    }

    /// Get the item stack in the selected hotbar slot.
    pub fn getSelectedStack(self: Inventory) ?ItemStack {
        return self.slots[self.selected_slot];
    }

    /// Select a hotbar slot by index (0-8).
    pub fn selectSlot(self: *Inventory, slot: u8) void {
        if (slot < HOTBAR_SIZE) {
            self.selected_slot = slot;
        }
    }

    /// Scroll through hotbar selection.
    /// Positive delta scrolls right, negative scrolls left.
    pub fn scrollSelection(self: *Inventory, delta: i32) void {
        var new_slot = @as(i32, self.selected_slot) - delta;
        // Wrap around
        new_slot = @mod(new_slot, @as(i32, HOTBAR_SIZE));
        self.selected_slot = @intCast(new_slot);
    }

    /// Get the item stack at a specific slot.
    pub fn getSlot(self: Inventory, slot: u8) ?ItemStack {
        if (slot < TOTAL_SLOTS) {
            return self.slots[slot];
        }
        return null;
    }

    /// Set the item stack at a specific slot.
    pub fn setSlot(self: *Inventory, slot: u8, stack: ?ItemStack) void {
        if (slot < TOTAL_SLOTS) {
            self.slots[slot] = stack;
        }
    }

    /// Add an item to the inventory.
    /// First tries to stack with existing items, then finds an empty slot.
    /// Returns true if the item was added, false if inventory is full.
    pub fn addItem(self: *Inventory, block_type: BlockType, count: u8) bool {
        var remaining = count;

        // First pass: try to stack with existing items
        for (&self.slots) |*slot| {
            if (slot.*) |*stack| {
                if (stack.block_type == block_type) {
                    const space = ItemStack.MAX_STACK - stack.count;
                    const to_add = @min(remaining, space);
                    stack.count += to_add;
                    remaining -= to_add;
                    if (remaining == 0) return true;
                }
            }
        }

        // Second pass: find empty slots
        for (&self.slots) |*slot| {
            if (slot.* == null) {
                const to_add = @min(remaining, ItemStack.MAX_STACK);
                slot.* = .{ .block_type = block_type, .count = to_add };
                remaining -= to_add;
                if (remaining == 0) return true;
            }
        }

        return remaining == 0;
    }

    /// Remove items from the selected slot.
    /// Returns the number of items actually removed.
    pub fn removeFromSelected(self: *Inventory, count: u8) u8 {
        if (self.slots[self.selected_slot]) |*stack| {
            const to_remove = @min(count, stack.count);
            stack.count -= to_remove;
            if (stack.count == 0) {
                self.slots[self.selected_slot] = null;
            }
            return to_remove;
        }
        return 0;
    }

    /// Swap two inventory slots.
    pub fn swapSlots(self: *Inventory, slot_a: u8, slot_b: u8) void {
        if (slot_a < TOTAL_SLOTS and slot_b < TOTAL_SLOTS) {
            const temp = self.slots[slot_a];
            self.slots[slot_a] = self.slots[slot_b];
            self.slots[slot_b] = temp;
        }
    }

    /// Check if the inventory has any items of the given type.
    pub fn hasItem(self: Inventory, block_type: BlockType) bool {
        for (self.slots) |slot| {
            if (slot) |stack| {
                if (stack.block_type == block_type) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Count total items of a given type across all slots.
    pub fn countItem(self: Inventory, block_type: BlockType) u32 {
        var total: u32 = 0;
        for (self.slots) |slot| {
            if (slot) |stack| {
                if (stack.block_type == block_type) {
                    total += stack.count;
                }
            }
        }
        return total;
    }

    /// Check if inventory is completely full.
    pub fn isFull(self: Inventory) bool {
        for (self.slots) |slot| {
            if (slot == null) return false;
            if (slot.?.count < ItemStack.MAX_STACK) return false;
        }
        return true;
    }

    /// Clear all slots.
    pub fn clear(self: *Inventory) void {
        self.slots = [_]?ItemStack{null} ** TOTAL_SLOTS;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Inventory initialization" {
    const inv = Inventory.init();
    try std.testing.expectEqual(@as(u8, 0), inv.selected_slot);
    try std.testing.expect(inv.slots[0] != null);
    try std.testing.expectEqual(BlockType.stone, inv.slots[0].?.block_type);
}

test "Inventory selection" {
    var inv = Inventory.init();

    inv.selectSlot(5);
    try std.testing.expectEqual(@as(u8, 5), inv.selected_slot);

    // Invalid slot should be ignored
    inv.selectSlot(20);
    try std.testing.expectEqual(@as(u8, 5), inv.selected_slot);
}

test "Inventory scroll wrapping" {
    var inv = Inventory.init();

    inv.selectSlot(0);
    inv.scrollSelection(1); // Should wrap to 8
    try std.testing.expectEqual(@as(u8, 8), inv.selected_slot);

    inv.scrollSelection(-1); // Should go back to 0
    try std.testing.expectEqual(@as(u8, 0), inv.selected_slot);
}

test "Inventory add item stacking" {
    var inv = Inventory.initEmpty();

    // Add first stack
    try std.testing.expect(inv.addItem(.stone, 32));
    try std.testing.expectEqual(@as(u8, 32), inv.slots[0].?.count);

    // Add more to same stack
    try std.testing.expect(inv.addItem(.stone, 20));
    try std.testing.expectEqual(@as(u8, 52), inv.slots[0].?.count);
}
