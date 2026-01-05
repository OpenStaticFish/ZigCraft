//! Hotbar widget for displaying and selecting inventory items.
//!
//! Renders the bottom hotbar UI with 9 slots, showing selected blocks
//! and highlighting the currently selected slot.

const std = @import("std");
const UISystem = @import("../../engine/ui/ui_system.zig").UISystem;
const Color = @import("../../engine/ui/ui_system.zig").Color;
const Font = @import("../../engine/ui/font.zig");
const Inventory = @import("../inventory.zig").Inventory;
const BlockType = @import("../../world/block.zig").BlockType;

/// Hotbar rendering configuration
pub const HotbarConfig = struct {
    /// Size of each slot in pixels
    slot_size: f32 = 44,
    /// Padding between slots
    slot_padding: f32 = 4,
    /// Margin from bottom of screen
    bottom_margin: f32 = 10,
    /// Border thickness
    border_thickness: f32 = 2,
    /// Inner margin for block icon
    icon_margin: f32 = 6,
};

/// Draw the hotbar at the bottom center of the screen.
pub fn draw(
    ui: *UISystem,
    inventory: *const Inventory,
    screen_width: f32,
    screen_height: f32,
    config: HotbarConfig,
) void {
    const total_width = @as(f32, @floatFromInt(Inventory.HOTBAR_SIZE)) * config.slot_size +
        @as(f32, @floatFromInt(Inventory.HOTBAR_SIZE - 1)) * config.slot_padding;
    const start_x = (screen_width - total_width) / 2.0;
    const y = screen_height - config.slot_size - config.bottom_margin;

    // Draw each slot
    for (0..Inventory.HOTBAR_SIZE) |i| {
        const slot_index: u8 = @intCast(i);
        const x = start_x + @as(f32, @floatFromInt(i)) * (config.slot_size + config.slot_padding);
        const is_selected = slot_index == inventory.selected_slot;

        drawSlot(ui, x, y, config.slot_size, is_selected, inventory.slots[i], config);

        // Draw slot number
        var num_buf: [2]u8 = undefined;
        const num_text = std.fmt.bufPrint(&num_buf, "{d}", .{i + 1}) catch "?";
        Font.drawText(ui, num_text, x + 2, y + 2, 1.5, Color.rgba(200, 200, 200, 180));
    }
}

/// Draw a single inventory slot.
fn drawSlot(
    ui: *UISystem,
    x: f32,
    y: f32,
    size: f32,
    selected: bool,
    item: ?Inventory.ItemStack,
    config: HotbarConfig,
) void {
    // Background color
    const bg_color = if (selected)
        Color.rgba(180, 180, 180, 220)
    else
        Color.rgba(40, 40, 40, 200);

    // Draw slot background
    ui.drawRect(.{ .x = x, .y = y, .width = size, .height = size }, bg_color);

    // Draw border
    const border_color = if (selected)
        Color.rgba(255, 255, 255, 255)
    else
        Color.rgba(80, 80, 80, 255);

    ui.drawRectOutline(
        .{ .x = x, .y = y, .width = size, .height = size },
        border_color,
        config.border_thickness,
    );

    // Draw block icon if slot has an item
    if (item) |stack| {
        const rgb = stack.block_type.getColor();
        const icon_color = Color.rgba(rgb[0], rgb[1], rgb[2], 1.0);

        const icon_size = size - config.icon_margin * 2;
        ui.drawRect(
            .{
                .x = x + config.icon_margin,
                .y = y + config.icon_margin,
                .width = icon_size,
                .height = icon_size,
            },
            icon_color,
        );

        // Draw stack count if > 1
        if (stack.count > 1) {
            var count_buf: [4]u8 = undefined;
            const count_text = std.fmt.bufPrint(&count_buf, "{d}", .{stack.count}) catch "?";
            Font.drawText(
                ui,
                count_text,
                x + size - 14,
                y + size - 12,
                1.5,
                Color.white,
            );
        }
    }
}

/// Draw the hotbar with default configuration.
pub fn drawDefault(
    ui: *UISystem,
    inventory: *const Inventory,
    screen_width: f32,
    screen_height: f32,
) void {
    draw(ui, inventory, screen_width, screen_height, .{});
}
