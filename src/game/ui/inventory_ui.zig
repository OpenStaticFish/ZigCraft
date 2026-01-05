//! Full inventory UI overlay with grid display and time controls.
//!
//! Toggleable overlay showing all 36 inventory slots and
//! time-of-day controls (moved from 1-4 keys in creative mode).

const std = @import("std");
const UISystem = @import("../../engine/ui/ui_system.zig").UISystem;
const Color = @import("../../engine/ui/ui_system.zig").Color;
const Rect = @import("../../engine/ui/ui_system.zig").Rect;
const Font = @import("../../engine/ui/font.zig");
const widgets = @import("../../engine/ui/widgets.zig");
const Inventory = @import("../inventory.zig").Inventory;
const BlockType = @import("../../world/block.zig").BlockType;

/// Inventory UI state
pub const InventoryUI = struct {
    /// Whether the inventory is currently visible
    visible: bool = false,

    /// Currently hovered slot (null if none)
    hovered_slot: ?u8 = null,

    /// Item being held by cursor (for drag and drop)
    held_item: ?Inventory.ItemStack = null,

    /// Source slot of held item (for returning on cancel)
    held_source: ?u8 = null,

    /// Configuration
    config: Config = .{},

    /// Time control buttons state
    time_button_hovered: ?u8 = null,

    pub const Config = struct {
        /// Size of each inventory slot
        slot_size: f32 = 40,
        /// Padding between slots
        slot_padding: f32 = 4,
        /// Background panel padding
        panel_padding: f32 = 20,
        /// Border thickness
        border_thickness: f32 = 2,
        /// Icon margin within slot
        icon_margin: f32 = 4,
    };

    /// Toggle inventory visibility
    pub fn toggle(self: *InventoryUI) void {
        self.visible = !self.visible;
        if (!self.visible) {
            // Drop held item back to source slot on close
            self.held_item = null;
            self.held_source = null;
        }
    }

    /// Open inventory
    pub fn open(self: *InventoryUI) void {
        self.visible = true;
    }

    /// Close inventory
    pub fn close(self: *InventoryUI) void {
        self.visible = false;
        self.held_item = null;
        self.held_source = null;
    }

    /// Update and draw the inventory UI.
    /// Returns the selected time-of-day if a time button was clicked (0-3), null otherwise.
    pub fn draw(
        self: *InventoryUI,
        ui: *UISystem,
        inventory: *Inventory,
        mouse_x: f32,
        mouse_y: f32,
        mouse_clicked: bool,
        screen_width: f32,
        screen_height: f32,
    ) ?u8 {
        if (!self.visible) return null;

        const cfg = self.config;

        // Calculate panel dimensions
        const cols: f32 = 9;
        const rows: f32 = 4; // 1 hotbar row + 3 main inventory rows
        const grid_width = cols * cfg.slot_size + (cols - 1) * cfg.slot_padding;
        const grid_height = rows * cfg.slot_size + (rows - 1) * cfg.slot_padding + 20; // Extra gap between hotbar and main
        const panel_width = grid_width + cfg.panel_padding * 2;
        const panel_height = grid_height + cfg.panel_padding * 2 + 60; // Extra space for time controls

        const panel_x = (screen_width - panel_width) / 2.0;
        const panel_y = (screen_height - panel_height) / 2.0;

        // Draw semi-transparent background overlay
        ui.drawRect(
            .{ .x = 0, .y = 0, .width = screen_width, .height = screen_height },
            Color.rgba(0, 0, 0, 0.6),
        );

        // Draw panel background
        ui.drawRect(
            .{ .x = panel_x, .y = panel_y, .width = panel_width, .height = panel_height },
            Color.rgba(0.24, 0.24, 0.24, 0.95),
        );

        // Draw panel border
        ui.drawRectOutline(
            .{ .x = panel_x, .y = panel_y, .width = panel_width, .height = panel_height },
            Color.rgba(0.4, 0.4, 0.4, 1.0),
            2,
        );

        // Title
        Font.drawTextCentered(ui, "INVENTORY", screen_width / 2.0, panel_y + 10, 2.5, Color.white);

        // Draw main inventory (3 rows of 9)
        const main_start_x = panel_x + cfg.panel_padding;
        const main_start_y = panel_y + cfg.panel_padding + 30;

        self.hovered_slot = null;

        // Main inventory slots (9-35)
        for (0..27) |i| {
            const row: u8 = @intCast(i / 9);
            const col: u8 = @intCast(i % 9);
            const slot_index: u8 = @intCast(i + 9); // Offset by hotbar size

            const x = main_start_x + @as(f32, @floatFromInt(col)) * (cfg.slot_size + cfg.slot_padding);
            const y = main_start_y + @as(f32, @floatFromInt(row)) * (cfg.slot_size + cfg.slot_padding);

            const hovered = isPointInRect(mouse_x, mouse_y, x, y, cfg.slot_size, cfg.slot_size);
            if (hovered) {
                self.hovered_slot = slot_index;
            }

            self.drawSlot(ui, x, y, cfg.slot_size, hovered, false, inventory.slots[slot_index], cfg);

            // Handle click
            if (hovered and mouse_clicked) {
                self.handleSlotClick(inventory, slot_index);
            }
        }

        // Gap between main and hotbar
        const hotbar_y = main_start_y + 3 * (cfg.slot_size + cfg.slot_padding) + 10;

        // Hotbar slots (0-8)
        for (0..9) |i| {
            const slot_index: u8 = @intCast(i);
            const x = main_start_x + @as(f32, @floatFromInt(i)) * (cfg.slot_size + cfg.slot_padding);
            const y = hotbar_y;

            const hovered = isPointInRect(mouse_x, mouse_y, x, y, cfg.slot_size, cfg.slot_size);
            const selected = slot_index == inventory.selected_slot;
            if (hovered) {
                self.hovered_slot = slot_index;
            }

            self.drawSlot(ui, x, y, cfg.slot_size, hovered, selected, inventory.slots[slot_index], cfg);

            // Handle click
            if (hovered and mouse_clicked) {
                self.handleSlotClick(inventory, slot_index);
            }
        }

        // Draw held item at cursor
        if (self.held_item) |item| {
            const rgb = item.block_type.getColor();
            const icon_color = Color.rgba(rgb[0], rgb[1], rgb[2], 0.8);
            const icon_size = cfg.slot_size - cfg.icon_margin * 2;
            ui.drawRect(
                .{
                    .x = mouse_x - icon_size / 2,
                    .y = mouse_y - icon_size / 2,
                    .width = icon_size,
                    .height = icon_size,
                },
                icon_color,
            );
        }

        // Time controls section
        const time_section_y = hotbar_y + cfg.slot_size + 20;
        Font.drawText(ui, "TIME OF DAY", panel_x + cfg.panel_padding, time_section_y, 2.0, Color.white);

        const time_labels = [_][]const u8{ "DAWN", "NOON", "DUSK", "NIGHT" };
        const button_width: f32 = 60;
        const button_height: f32 = 25;
        const button_spacing: f32 = 10;
        const buttons_start_x = panel_x + cfg.panel_padding;
        const buttons_y = time_section_y + 20;

        var clicked_time: ?u8 = null;
        self.time_button_hovered = null;

        for (0..4) |i| {
            const bx = buttons_start_x + @as(f32, @floatFromInt(i)) * (button_width + button_spacing);
            const hovered = isPointInRect(mouse_x, mouse_y, bx, buttons_y, button_width, button_height);

            if (hovered) {
                self.time_button_hovered = @intCast(i);
            }

            const btn_color = if (hovered)
                Color.rgba(0.4, 0.4, 0.47, 1.0)
            else
                Color.rgba(0.27, 0.27, 0.31, 1.0);

            ui.drawRect(.{ .x = bx, .y = buttons_y, .width = button_width, .height = button_height }, btn_color);
            ui.drawRectOutline(.{ .x = bx, .y = buttons_y, .width = button_width, .height = button_height }, Color.rgba(0.47, 0.47, 0.51, 1.0), 1);
            Font.drawTextCentered(ui, time_labels[i], bx + button_width / 2, buttons_y + 6, 1.5, Color.white);

            if (hovered and mouse_clicked) {
                clicked_time = @intCast(i);
            }
        }

        return clicked_time;
    }

    /// Handle slot click for item pickup/placement
    fn handleSlotClick(self: *InventoryUI, inventory: *Inventory, slot_index: u8) void {
        if (self.held_item) |held| {
            // Placing held item
            if (inventory.slots[slot_index]) |existing| {
                // Swap items
                inventory.slots[slot_index] = held;
                self.held_item = existing;
                self.held_source = slot_index;
            } else {
                // Place in empty slot
                inventory.slots[slot_index] = held;
                self.held_item = null;
                self.held_source = null;
            }
        } else {
            // Picking up item
            if (inventory.slots[slot_index]) |item| {
                self.held_item = item;
                self.held_source = slot_index;
                inventory.slots[slot_index] = null;
            }
        }
    }

    /// Draw a single inventory slot
    fn drawSlot(
        self: *InventoryUI,
        ui: *UISystem,
        x: f32,
        y: f32,
        size: f32,
        hovered: bool,
        selected: bool,
        item: ?Inventory.ItemStack,
        cfg: Config,
    ) void {
        _ = self;

        // Background
        const bg_color = if (selected)
            Color.rgba(0.47, 0.47, 0.55, 1.0)
        else if (hovered)
            Color.rgba(0.31, 0.31, 0.39, 1.0)
        else
            Color.rgba(0.2, 0.2, 0.24, 1.0);

        ui.drawRect(.{ .x = x, .y = y, .width = size, .height = size }, bg_color);

        // Border
        const border_color = if (selected)
            Color.rgba(0.78, 0.78, 0.86, 1.0)
        else
            Color.rgba(0.31, 0.31, 0.35, 1.0);

        ui.drawRectOutline(.{ .x = x, .y = y, .width = size, .height = size }, border_color, cfg.border_thickness);

        // Item icon
        if (item) |stack| {
            const rgb = stack.block_type.getColor();
            const icon_color = Color.rgba(rgb[0], rgb[1], rgb[2], 1.0);

            const icon_size = size - cfg.icon_margin * 2;
            ui.drawRect(
                .{
                    .x = x + cfg.icon_margin,
                    .y = y + cfg.icon_margin,
                    .width = icon_size,
                    .height = icon_size,
                },
                icon_color,
            );

            // Stack count
            if (stack.count > 1) {
                var count_buf: [4]u8 = undefined;
                const count_text = std.fmt.bufPrint(&count_buf, "{d}", .{stack.count}) catch "?";
                Font.drawText(ui, count_text, x + size - 12, y + size - 10, 1.2, Color.white);
            }
        }
    }
};

/// Helper to check if a point is inside a rectangle
fn isPointInRect(px: f32, py: f32, rx: f32, ry: f32, rw: f32, rh: f32) bool {
    return px >= rx and px <= rx + rw and py >= ry and py <= ry + rh;
}
