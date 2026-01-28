const std = @import("std");
const c = @import("../c.zig").c;
const Input = @import("../engine/input/input.zig").Input;
const IRawInputProvider = @import("../engine/input/interfaces.zig").IRawInputProvider;
const WorldMap = @import("../world/worldgen/world_map.zig").WorldMap;
const Camera = @import("../engine/graphics/camera.zig").Camera;
const Generator = @import("../world/worldgen/generator_interface.zig").Generator;
const UISystem = @import("../engine/ui/ui_system.zig").UISystem;
const Color = @import("../engine/ui/ui_system.zig").Color;
const Font = @import("../engine/ui/font.zig");
const log = @import("../engine/core/log.zig");
const Vec3 = @import("../engine/math/vec3.zig").Vec3;

const input_mapper_pkg = @import("input_mapper.zig");
const InputMapper = input_mapper_pkg.InputMapper;
const IInputMapper = input_mapper_pkg.IInputMapper;
const GameAction = input_mapper_pkg.GameAction;

pub const MapController = struct {
    show_map: bool = false,
    map_needs_update: bool = true,
    map_zoom: f32 = 4.0,
    map_target_zoom: f32 = 4.0,
    map_pos_x: f32 = 0.0,
    map_pos_z: f32 = 0.0,
    last_mouse_x: f32 = 0.0,
    last_mouse_y: f32 = 0.0,

    pub fn update(self: *MapController, input: IRawInputProvider, mapper: IInputMapper, camera: *const Camera, time_delta: f32, window: *c.SDL_Window, screen_w: f32, screen_h: f32, world_map_width: u32) void {
        if (mapper.isActionPressed(input, .toggle_map)) {
            self.show_map = !self.show_map;
            log.log.info("Toggle map: show={}", .{self.show_map});
            if (self.show_map) {
                self.map_pos_x = camera.position.x;
                self.map_pos_z = camera.position.z;
                self.map_target_zoom = self.map_zoom;
                self.map_needs_update = true;
                const any_window: ?*anyopaque = @ptrCast(@alignCast(window));
                input.setMouseCapture(any_window, false);
            } else {
                const any_window: ?*anyopaque = @ptrCast(@alignCast(window));
                input.setMouseCapture(any_window, true);
            }
        }

        if (!self.show_map) return;

        const dt = @min(time_delta, 0.033);
        if (mapper.isActionActive(input, .map_zoom_in)) {
            self.map_target_zoom /= @exp(1.2 * dt);
            self.map_needs_update = true;
        }
        if (mapper.isActionActive(input, .map_zoom_out)) {
            self.map_target_zoom *= @exp(1.2 * dt);
            self.map_needs_update = true;
        }
        if (input.getScrollDelta().y != 0) {
            const zoom_delta = input.getScrollDelta().y;
            self.map_target_zoom *= @exp(zoom_delta * 0.2);
            self.map_needs_update = true;
        }
        self.map_target_zoom = std.math.clamp(self.map_target_zoom, 0.05, 128.0);
        const old_zoom = self.map_zoom;
        self.map_zoom = std.math.lerp(self.map_zoom, self.map_target_zoom, 20.0 * dt);
        if (@abs(self.map_zoom - old_zoom) > 0.001 * self.map_zoom) self.map_needs_update = true;

        if (mapper.isActionPressed(input, .map_center)) {
            self.map_pos_x = camera.position.x;
            self.map_pos_z = camera.position.z;
            self.map_needs_update = true;
        }

        const mouse_pos = input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);

        const map_ui_size: f32 = @min(screen_w, screen_h) * 0.8;
        const world_to_screen_ratio = @as(f32, @floatFromInt(world_map_width)) / map_ui_size;

        if (input.isMouseButtonPressed(.left)) {
            self.last_mouse_x = mouse_x;
            self.last_mouse_y = mouse_y;
        }

        if (input.isMouseButtonDown(.left)) {
            const drag_dx = mouse_x - self.last_mouse_x;
            const drag_dz = mouse_y - self.last_mouse_y;
            if (@abs(drag_dx) > 0.1 or @abs(drag_dz) > 0.1) {
                self.map_pos_x -= drag_dx * self.map_zoom * world_to_screen_ratio;
                self.map_pos_z -= drag_dz * self.map_zoom * world_to_screen_ratio;
                self.map_needs_update = true;
            }
            self.last_mouse_x = mouse_x;
            self.last_mouse_y = mouse_y;
        } else {
            const pan_kb_speed = 800.0 * self.map_zoom;
            const move_vec = mapper.getMovementVector(input);
            if (move_vec.x != 0 or move_vec.z != 0) {
                self.map_pos_x += move_vec.x * pan_kb_speed * dt;
                self.map_pos_z -= move_vec.z * pan_kb_speed * dt; // Match coordinate system (W is z+)
                self.map_needs_update = true;
            }
        }
    }

    pub fn draw(self: *MapController, u: *UISystem, screen_w: f32, screen_h: f32, world_map: *WorldMap, generator: Generator, camera_pos: Vec3, allocator: std.mem.Allocator) !void {
        if (!self.show_map) return;

        if (self.map_needs_update) {
            try world_map.update(generator, self.map_pos_x, self.map_pos_z, self.map_zoom, allocator);
            self.map_needs_update = false;
        }

        const sz: f32 = @min(screen_w, screen_h) * 0.8;
        const mx = (screen_w - sz) * 0.5;
        const my = (screen_h - sz) * 0.5;
        u.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0, 0, 0, 0.5));
        u.drawTexture(@intCast(world_map.texture.handle), .{ .x = mx, .y = my, .width = sz, .height = sz });
        u.drawRectOutline(.{ .x = mx, .y = my, .width = sz, .height = sz }, Color.white, 2.0);
        Font.drawTextCentered(u, "WORLD MAP", screen_w * 0.5, my - 40.0, 3.0, Color.white);

        const rx = (camera_pos.x - self.map_pos_x) / (self.map_zoom * @as(f32, @floatFromInt(world_map.width)));
        const rz = (camera_pos.z - self.map_pos_z) / (self.map_zoom * @as(f32, @floatFromInt(world_map.height)));
        const px = mx + (rx + 0.5) * sz;
        const pz = my + (rz + 0.5) * sz;

        if (px >= mx and px <= mx + sz and pz >= my and pz <= my + sz) {
            u.drawRect(.{ .x = px - 5, .y = pz - 1, .width = 10, .height = 2 }, Color.red);
            u.drawRect(.{ .x = px - 1, .y = pz - 5, .width = 2, .height = 10 }, Color.red);
        }
    }
};
